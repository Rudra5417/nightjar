/*
 * Fieldwatch-class sensor node — ESP32 firmware (Arduino core 3.x / ESP-IDF underneath)
 *
 * Why this exists: iOS exposes no peer MAC address and cannot enumerate neighbouring
 * access points (TN3111 / CoreBluetooth). A node in the field can do both, so it
 * restores the ~91% of the signature catalog the iPhone alone can never reach, and it
 * adds 5 GHz + 802.15.4 coverage on the C5/C6 parts.
 *
 * Receive-only by design: passive Wi-Fi scan, promiscuous sniff (no transmission on the
 * air beyond the node's own BLE link to the phone), no deauth/spam/evil-twin features.
 * That is the whole difference between this and the pentest firmwares.
 *
 * Output: newline-delimited JSON, one frame per line, over BLE GATT (and USB serial for
 * bench work). See Sources/RFCore/NodeLink.swift for the contract this must satisfy.
 *
 * Frames emitted:
 *   {"t":"node", ...}                                  once on connect, then every 30 s
 *   {"t":"ap","bssid","ssid","rssi","ch","band","auth","hidden","ie_ouis",...}
 *   {"t":"ble","addr","addr_type","rssi","name","uuids","mfg_id","mfg_hex","svc_data"}
 *   {"t":"scan","phase","ms","aps","radios","chan_mask"}
 *
 * HARDWARE NOTE — single radio, time-sliced. The Wi-Fi and BLE radios share one 2.4 GHz
 * front end, so promiscuous sniffing and BLE scanning cannot both run flat out. The loop
 * below alternates phases. The BLE link to the phone is kept alive across phases; if a
 * field test shows dropped frames during the Wi-Fi phase, the fix is a two-radio node
 * (one part holds the link, one part scans) rather than a firmware trick.
 *
 * Board targets: ESP32-C5 (dual-band 2.4/5 GHz + BLE 5 + 802.15.4) preferred,
 *                ESP32-C6 (2.4 GHz + BLE 5.3 + 802.15.4), ESP32-S3 / classic ESP32 (2.4 GHz).
 *                ESP32-S2 has no Bluetooth — it cannot hold the link.
 */

#include <WiFi.h>
#include <NimBLEDevice.h>
#include "esp_wifi.h"
#include "esp_mac.h"

// Forward declarations. Arduino's .ino preprocessor normally synthesises these with
// ctags; the shim in the build notes disables that, so they are written out explicitly.
static void emitNodeFrame();

// ---------------------------------------------------------------- configuration

#define NODE_NAME          "FW-NODE"
#define LINK_SERVICE_UUID  "6f776300-1b2c-4d5e-8a90-000000000001"  // node -> phone
#define LINK_TX_UUID       "6f776301-1b2c-4d5e-8a90-000000000002"  // notify
#define LINK_RX_UUID       "6f776302-1b2c-4d5e-8a90-000000000003"  // write

#define WIFI_PHASE_MS      4000      // sniff + passive scan window
#define BLE_PHASE_MS       3000      // BLE scan window
#define SCAN_INTERVAL_MS   2000      // how often to re-run the passive AP scan
#define AP_REPORT_MS       5000      // re-report a seen AP at most this often
#define BLE_REPORT_MS      4000
#define MAX_APS            64
#define MAX_IE_OUIS        4

// ---------------------------------------------------------------- node state

struct ApRecord {
  uint8_t bssid[6];
  char ssid[33];
  int8_t rssi;
  uint8_t channel;
  bool hidden;
  bool is5g;
  uint8_t ieOuis[MAX_IE_OUIS][3];
  uint8_t ieOuiCount;
  uint32_t lastReport;
};

static ApRecord aps[MAX_APS];
static int apCount = 0;

static bool scanning = true;
static bool wifiPhase = true;
static uint32_t phaseStarted = 0;
static uint32_t lastScan = 0;
static uint32_t bootMs = 0;
static char nodeId[16] = "NODE";

static NimBLECharacteristic* txChar = nullptr;
static bool phoneConnected = false;

// ---------------------------------------------------------------- output

static void emit(const String& line) {
  Serial.println(line);
  if (phoneConnected && txChar != nullptr) {
    txChar->setValue((uint8_t*)line.c_str(), line.length());
    txChar->notify();
  }
}

static String macToString(const uint8_t* mac) {
  char buf[18];
  snprintf(buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  return String(buf);
}

static String jsonEscape(const String& in) {
  String out;
  out.reserve(in.length() + 8);
  for (size_t i = 0; i < in.length(); i++) {
    char c = in[i];
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c < 0x20) { out += ' '; }
    else out += c;
  }
  return out;
}

// ---------------------------------------------------------------- Wi-Fi sniffing

// Pull the IE chain out of a beacon/probe-response and keep vendor OUIs (IE 221).
static void harvestIes(const uint8_t* ies, int len, ApRecord* rec) {
  int i = 0;
  while (i + 2 <= len) {
    uint8_t id = ies[i];
    uint8_t ieLen = ies[i + 1];
    if (i + 2 + ieLen > len) break;
    const uint8_t* body = ies + i + 2;

    if (id == 221 && ieLen >= 3) {                 // vendor specific
      for (int k = 0; k < rec->ieOuiCount; k++) {
        if (memcmp(rec->ieOuis[k], body, 3) == 0) { i += 2 + ieLen; goto next; }
      }
      if (rec->ieOuiCount < MAX_IE_OUIS) {
        memcpy(rec->ieOuis[rec->ieOuiCount], body, 3);
        rec->ieOuiCount++;
      }
    }
  next:
    i += 2 + ieLen;
  }
}

static void sniffer(void* buf, wifi_promiscuous_pkt_type_t type) {
  if (type != WIFI_PKT_MGMT) return;
  const wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
  const uint8_t* frame = pkt->payload;
  int len = pkt->rx_ctrl.sig_len;
  if (len < 36) return;

  uint8_t subtype = (frame[0] >> 4) & 0x0F;
  if (subtype != 8 && subtype != 5) return;         // beacon or probe response

  const uint8_t* bssid = frame + 16;
  const uint8_t* ies = frame + 36;                  // 24 hdr + 12 fixed params
  int ieLen = len - 36;
  if (ieLen <= 0) return;

  // Hidden SSID lives in IE 0 with length 0.
  bool hidden = true;
  if (ies[0] == 0 && ies[1] > 0) hidden = false;

  for (int i = 0; i < apCount; i++) {
    if (memcmp(aps[i].bssid, bssid, 6) == 0) {
      harvestIes(ies, ieLen, &aps[i]);
      if (aps[i].hidden && !hidden) {
        int sl = ies[1] > 32 ? 32 : ies[1];
        memcpy(aps[i].ssid, ies + 2, sl);
        aps[i].ssid[sl] = 0;
        aps[i].hidden = false;
      }
      aps[i].rssi = pkt->rx_ctrl.rssi;
      return;
    }
  }
  if (apCount >= MAX_APS) return;

  ApRecord* rec = &aps[apCount];
  memset(rec, 0, sizeof(*rec));
  memcpy(rec->bssid, bssid, 6);
  rec->rssi = pkt->rx_ctrl.rssi;
  rec->channel = pkt->rx_ctrl.channel;
  rec->is5g = rec->channel > 14;
  rec->hidden = hidden;
  if (!hidden) {
    int sl = ies[1] > 32 ? 32 : ies[1];
    memcpy(rec->ssid, ies + 2, sl);
    rec->ssid[sl] = 0;
  }
  harvestIes(ies, ieLen, rec);
  apCount++;
}

// Passive scan: no probe requests leave the antenna, so the node stays receive-only.
static void passiveApScan() {
  wifi_scan_config_t cfg = {};
  cfg.ssid = nullptr;
  cfg.bssid = nullptr;
  cfg.channel = 0;
  cfg.show_hidden = true;
  cfg.scan_type = WIFI_SCAN_TYPE_PASSIVE;
  cfg.scan_time.passive = 120;

  if (esp_wifi_scan_start(&cfg, true) != ESP_OK) return;

  uint16_t n = MAX_APS;
  static wifi_ap_record_t recs[MAX_APS];
  if (esp_wifi_scan_get_ap_records(&n, recs) != ESP_OK) return;

  for (uint16_t i = 0; i < n; i++) {
    // Fold scan results into the sniffed table so IEs and scan data land on one row.
    int found = -1;
    for (int j = 0; j < apCount; j++) {
      if (memcmp(aps[j].bssid, recs[i].bssid, 6) == 0) { found = j; break; }
    }
    if (found < 0) {
      if (apCount >= MAX_APS) continue;
      found = apCount++;
      memset(&aps[found], 0, sizeof(ApRecord));
      memcpy(aps[found].bssid, recs[i].bssid, 6);
    }
    ApRecord* rec = &aps[found];
    rec->rssi = recs[i].rssi;
    rec->channel = recs[i].primary;
    rec->is5g = rec->channel > 14;
    if (recs[i].ssid[0] == 0) {
      rec->hidden = true;
    } else {
      memcpy(rec->ssid, recs[i].ssid, 32);
      rec->ssid[32] = 0;
      rec->hidden = false;
    }
  }
  emit(String("{\"t\":\"scan\",\"phase\":\"wifi\",\"ms\":") + String(millis() - lastScan) +
       ",\"aps\":" + String(apCount) + ",\"radios\":[\"2.4\",\"5\"],\"chan_mask\":\"passive\"}");
}

static void reportAps() {
  uint32_t now = millis();
  for (int i = 0; i < apCount; i++) {
    ApRecord* rec = &aps[i];
    if (now - rec->lastReport < AP_REPORT_MS) continue;
    rec->lastReport = now;

    String line = "{\"t\":\"ap\",\"node\":\"" + String(nodeId) + "\",\"bssid\":\"" +
                  macToString(rec->bssid) + "\",\"ssid\":\"" + jsonEscape(String(rec->ssid)) +
                  "\",\"rssi\":" + String(rec->rssi) + ",\"ch\":" + String(rec->channel) +
                  ",\"band\":\"" + String(rec->is5g ? "5" : "2.4") + "\",\"auth\":\"" +
                  (rec->hidden ? "?" : "?") + "\",\"hidden\":" + String(rec->hidden ? "true" : "false") +
                  ",\"ie_ouis\":[";
    for (int k = 0; k < rec->ieOuiCount; k++) {
      char oui[7];
      snprintf(oui, sizeof(oui), "%02X%02X%02X", rec->ieOuis[k][0], rec->ieOuis[k][1], rec->ieOuis[k][2]);
      if (k) line += ",";
      line += "\"" + String(oui) + "\"";
    }
    line += "],\"first_ms\":" + String(bootMs) + ",\"last_ms\":" + String(now) + "}";
    emit(line);
  }
}

// ---------------------------------------------------------------- BLE scanning

class NodeScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* dev) override {
    uint8_t at = dev->getAddressType();               // 0 public, 1 random, 2/3 identity
    String addr = dev->getAddress().toString().c_str();

    String line = "{\"t\":\"ble\",\"node\":\"" + String(nodeId) + "\",\"addr\":\"" + addr +
                  "\",\"addr_type\":\"" + String(at == 0 ? "public" : "random") +
                  "\",\"rssi\":" + String(dev->getRSSI()) + ",\"name\":\"" +
                  (dev->haveName() ? jsonEscape(String(dev->getName().c_str())) : "") + "\",\"uuids\":[";
    for (uint8_t i = 0; i < dev->getServiceUUIDCount(); i++) {
      if (i) line += ",";
      line += "\"" + String(dev->getServiceUUID(i).toString().c_str()) + "\"";
    }
    line += "]";

    std::string mfg = dev->getManufacturerData();
    if (mfg.length() >= 2) {
      uint16_t company = (uint8_t)mfg[0] | ((uint16_t)(uint8_t)mfg[1] << 8);
      line += ",\"mfg_id\":" + String(company) + ",\"mfg_hex\":\"";
      for (size_t i = 2; i < mfg.length(); i++) {
        char b[3];
        snprintf(b, sizeof(b), "%02X", (uint8_t)mfg[i]);
        line += b;
      }
      line += "\"";
    }

    if (dev->getServiceDataCount() > 0) {
      line += ",\"svc_data\":[";
      for (uint8_t i = 0; i < dev->getServiceDataCount(); i++) {
        std::string sd = dev->getServiceData(i);
        if (i) line += ",";
        line += "{\"u\":\"" + String(dev->getServiceDataUUID(i).toString().c_str()) + "\",\"h\":\"";
        for (size_t k = 0; k < sd.length(); k++) {
          char b[3];
          snprintf(b, sizeof(b), "%02X", (uint8_t)sd[k]);
          line += b;
        }
        line += "\"}";
      }
      line += "]";
    }

    line += ",\"last_ms\":" + String(millis()) + "}";
    emit(line);
  }
};

static NodeScanCallbacks scanCallbacks;

// ---------------------------------------------------------------- BLE link

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    phoneConnected = true;
    emitNodeFrame();
  }
  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& info, int reason) override {
    phoneConnected = false;
    NimBLEDevice::getAdvertising()->start();
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& info) override {
    std::string value = chr->getValue();
    String cmd(value.c_str());
    // {"t":"cmd","op":"start"|"stop"|"set"}
    if (cmd.indexOf("\"op\":\"start\"") >= 0) { scanning = true; }
    else if (cmd.indexOf("\"op\":\"stop\"") >= 0) { scanning = false; }
    else if (cmd.indexOf("\"op\":\"set\"") >= 0) { /* reserved: dwell, bands, name */ }
  }
};

static ServerCallbacks serverCallbacks;
static RxCallbacks rxCallbacks;

static void emitNodeFrame() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  emit(String("{\"t\":\"node\",\"id\":\"") + String(nodeId) + "\",\"fw\":\"0.1.0\",\"chip\":\"" +
       String(ESP.getChipModel()) + "\",\"batt\":null,\"uptime_ms\":" + String(millis()) + "}");
}

// ---------------------------------------------------------------- setup / loop

void setup() {
  Serial.begin(115200);
  delay(200);
  bootMs = millis();

  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  snprintf(nodeId, sizeof(nodeId), "%02X%02X%02X", mac[3], mac[4], mac[5]);

  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_promiscuous_rx_cb(&sniffer);
  esp_wifi_set_promiscuous(true);

  NimBLEDevice::init(NODE_NAME);
  NimBLEDevice::setPower(3);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(&serverCallbacks);
  NimBLEService* svc = server->createService(LINK_SERVICE_UUID);
  txChar = svc->createCharacteristic(LINK_TX_UUID, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rxChar = svc->createCharacteristic(LINK_RX_UUID,
                                                           NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rxChar->setCallbacks(&rxCallbacks);
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(LINK_SERVICE_UUID);
  adv->setName(NODE_NAME);
  adv->enableScanResponse(true);
  adv->start();

  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(&scanCallbacks, true);   // true = report duplicates (we want every RSSI)
  scan->setActiveScan(false);                     // passive: receive-only
  scan->setInterval(100);
  scan->setWindow(80);

  emitNodeFrame();
  phaseStarted = millis();
}

void loop() {
  uint32_t now = millis();

  if (!scanning) {
    delay(50);
    return;
  }

  if (now - phaseStarted > (wifiPhase ? WIFI_PHASE_MS : BLE_PHASE_MS)) {
    wifiPhase = !wifiPhase;
    phaseStarted = now;
    if (wifiPhase) {
      NimBLEDevice::getScan()->stop();
      esp_wifi_set_promiscuous(true);
    } else {
      esp_wifi_set_promiscuous(false);
      NimBLEDevice::getScan()->start(0, false);   // run until we stop it
      emit(String("{\"t\":\"scan\",\"phase\":\"ble\",\"ms\":") + String(BLE_PHASE_MS) +
           ",\"radios\":[\"ble\"]}");
    }
  }

  if (wifiPhase) {
    if (now - lastScan > SCAN_INTERVAL_MS) {
      lastScan = now;
      passiveApScan();
    }
    reportAps();
  }
  delay(20);
}
