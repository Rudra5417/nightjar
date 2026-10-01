# Sensor node firmware (ESP32)

Receive-only radio node that hands the iPhone what iOS refuses to expose: real MAC
addresses, neighbouring access points, 5 GHz, and beacon vendor IEs.

```
firmware/fieldwatch_node/fieldwatch_node.ino    Arduino core 3.x (ESP-IDF underneath)
```

## Build

```bash
arduino-cli core install esp32:esp32 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli lib install NimBLE-Arduino
arduino-cli compile --fqbn esp32:esp32:esp32c5:PartitionScheme=huge_app firmware/fieldwatch_node
arduino-cli upload  --fqbn esp32:esp32:esp32c5:PartitionScheme=huge_app -p /dev/cu.usbmodem* firmware/fieldwatch_node
```

Verified with arduino-cli 1.5.1 + esp32 core 3.3.12 + NimBLE-Arduino 2.5.1:

| Target | Result |
|---|---|
| `esp32:esp32:esp32c5` | 1,385,069 B flash (44% of 3 MB), 63,868 B RAM |
| `esp32:esp32:esp32c6` | 1,335,578 B (42%) |
| `esp32:esp32:esp32s3` | 1,050,644 B (33%) |
| `esp32:esp32:esp32`  | 1,138,352 B (36%) |

`PartitionScheme=huge_app` is required — the default 1.2 MB app partition is too small once
NimBLE + Wi-Fi are both linked in (build fails with "text section exceeds available space").

### Two build-environment gotchas on Apple Silicon

1. **ctags shim.** arduino-cli ships `builtin:ctags` for `x86_64-apple-darwin` only, so sketch
   preprocessing dies with `bad CPU type in executable` unless Rosetta 2 is installed. The
   workaround used here replaces that binary with a no-op shim and declares the sketch's
   forward declarations explicitly. Restore the original (`ctags.x86_64.orig`) and install
   Rosetta if you ever need real preprocessing.
2. Always pass `PartitionScheme=huge_app`; a bare `--fqbn` builds and then fails on size.

## Which part

| Part | Radios | Why you'd pick it |
|---|---|---|
| **ESP32-C5** | dual-band 2.4 + **5 GHz** Wi-Fi 6, BLE 5, 802.15.4 | Only ESP32 with 5 GHz. Most modern surveillance/ALPR gear sits on 5 GHz — this is the default choice |
| ESP32-C6 | 2.4 GHz Wi-Fi 6, BLE 5.3, 802.15.4 | Cheaper; adds Thread/Zigbee sniffing (a radio layer Fieldwatch never had) |
| ESP32-S3 | 2.4 GHz Wi-Fi, BLE 5 | Best USB/serial + PSRAM for local logging to microSD |
| ESP32 / ESP32-S2 | 2.4 GHz Wi-Fi, BLE (S2: **no Bluetooth**) | Bench only; S2 cannot hold the phone link |

Avoid AGPL firmware (Bruce) if this ships as a product; Marauder is MIT but is an
offensive toolkit — this node deliberately has no transmit features beyond its own link.

## What it sends

Newline-delimited JSON; the contract is `Sources/RFCore/NodeLink.swift`.

```json
{"t":"node","id":"A1B2C3","fw":"0.1.0","chip":"ESP32-C5","batt":null,"uptime_ms":41200}
{"t":"ap","node":"A1B2C3","bssid":"B4:1E:52:11:22:33","ssid":"Flock-4C21AB","rssi":-61,"ch":6,"band":"2.4","hidden":false,"ie_ouis":["0050F2","000FAC"],"first_ms":1200,"last_ms":40200}
{"t":"ble","node":"A1B2C3","addr":"00:25:DF:42:53:64","addr_type":"public","rssi":-68,"name":"Axon Body 4","uuids":["FE6B"],"mfg_id":845,"mfg_hex":"0A00"}
{"t":"scan","phase":"wifi","ms":812,"aps":7,"radios":["2.4","5"],"chan_mask":"passive"}
```

Phone → node: `{"t":"cmd","op":"start"}`, `{"t":"cmd","op":"stop"}`.

## Receive-only, on purpose

- Wi-Fi uses **passive** scan (`WIFI_SCAN_TYPE_PASSIVE`) — no probe requests leave the antenna.
- The promiscuous hook filters to management frames (beacon / probe response) and only reads
  the IE chain; nothing is transmitted.
- BLE scan is passive (`setActiveScan(false)`) — no scan requests, so no scan-response data,
  but also no emissions.
- The only thing the node transmits is its own BLE link to the phone.

## Known constraints (measure on hardware, don't assume)

1. **One 2.4 GHz radio.** Wi-Fi sniffing and BLE scanning are time-sliced, and the BLE link
   to the phone shares the same front end. If field testing shows dropped frames during the
   Wi-Fi phase, the fix is a two-radio node (one part holds the link, one part scans) —
   not a firmware trick. This is why other ESP32 projects suspend Wi-Fi while bridging.
2. **No true monitor mode.** Promiscuous mode gives management frames, not full 802.11
   capture with radiotap; there is no 6 GHz and no 802.11ax frame decoding.
3. **Randomized addresses.** OUI matching only means something for *public* BLE addresses
   (the firmware reports `addr_type` so the app can tell). Random addresses fall back to
   name / service-UUID / manufacturer-data matching, same as on Android.
4. **RSSI is coarse** (±5–6 dB). Useful for "closer/farther", not for cm ranging. UWB
   (`NearbyInteraction`) covers the precise case, but only to a paired accessory.
