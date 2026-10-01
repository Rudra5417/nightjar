#!/usr/bin/env python3
"""Generate node-session.sample.jsonl from the real Fieldwatch catalog pack.

Every OUI / company id / service UUID in the sample is pulled out of the pack, so the
replay exercises genuine catalog rules rather than made-up numbers.

usage: make_sample_session.py <fieldwatch-signatures-v2.json> <out.jsonl>
"""
import json
import sys

WIFI_KINDS = {"OUI", "MAC_PREFIX", "VENDOR_IE_OUI"}
BLE_KINDS = {"SERVICE_UUID", "MANUFACTURER_ID", "MANUFACTURER_DATA", "SERVICE_DATA"}


def rules_of(fleet, kinds):
    return [r for r in fleet["rules"] if r["kind"] in kinds and r.get("enabled", True)]


def main():
    pack, out_path = sys.argv[1], sys.argv[2]
    data = json.load(open(pack))
    fleets = {f["name"]: f for f in data["fleets"]}

    def oui(fleet_name):
        for r in rules_of(fleets[fleet_name], {"OUI"}):
            return r["text"]
        return None

    def mfg(fleet_name):
        for r in rules_of(fleets[fleet_name], {"MANUFACTURER_ID"}):
            return r["companyId"]
        return None

    def uuid(fleet_name):
        for r in rules_of(fleets[fleet_name], {"SERVICE_UUID"}):
            return r["text"]
        return None

    frames = []
    frames.append({"t": "node", "id": "NODE-01", "fw": "0.1.0", "chip": "esp32-c5",
                   "batt": 84, "lat": 34.0195, "lon": -118.4912, "uptime_ms": 41200})

    # --- Wi-Fi access points the iPhone can never see -------------------------
    # OUI straight out of the pack, so these hit real catalog rules.
    ap_plan = [
        ("Flock Safety Cameras", "Flock-4C21AB", -61, 6, "2.4", ["0050F2", "000FAC"]),
        ("Axon", "Axon-Fleet-01", -74, 11, "2.4", ["0050F2"]),
        ("Dahua", "", -69, 149, "5", ["0050F2"]),          # hidden SSID
        ("Axis", "AXIS-4C21AB", -77, 44, "5", ["0050F2"]),
        ("Aruba", "Aruba-AP-cafe", -66, 36, "5", ["000B86"]),
        ("Cisco", "", -58, 1, "2.4", ["00000C", "0050F2"]),  # hidden, Cisco CCX vendor IE
    ]
    for i, (fleet_name, ssid, rssi, ch, band, ie_ouis) in enumerate(ap_plan):
        bssid = oui(fleet_name)
        if not bssid:
            continue
        frames.append({
            "t": "ap", "node": "NODE-01",
            "bssid": bssid + ":%02X:%02X:%02X" % (0x11 + i, 0x22 + i, 0x33 + i),
            "ssid": ssid, "rssi": rssi, "ch": ch, "band": band,
            "auth": "WPA2", "hidden": ssid == "",
            "ie_ouis": ie_ouis, "first_ms": 1200 + i * 90, "last_ms": 40200, "count": 3 + i,
        })

    # A drone broadcasting Wi-Fi Remote ID: no catalog OUI, no matching name. The only
    # signal is the OpenDroneID vendor IE (FA:0B:BC) in the beacon — the exact case that
    # stock Android misses and that iOS cannot see at all without a node.
    frames.append({
        "t": "ap", "node": "NODE-01", "bssid": "9C:5C:8E:AA:BB:01", "ssid": "Drone-RID",
        "rssi": -71, "ch": 6, "band": "2.4", "auth": "OPEN", "hidden": False,
        "ie_ouis": ["FA0BBC"], "first_ms": 1800, "last_ms": 40600, "count": 9,
    })

    # --- BLE advertisements --------------------------------------------------
    ble_plan = [
        ("Ray-Ban / Meta glasses", "public", "Ray-Ban Meta 7A2C", None, -72, None),
        ("DJI", "public", "", None, -79, None),
        ("Axon", "public", "Axon Body 4", None, -68, None),
        ("Apple AirTags", "random", "AirTag", None, -83, None),   # randomized: OUI useless, name + UUID carry it
    ]
    for i, (fleet_name, addr_type, name, _, rssi, _) in enumerate(ble_plan):
        fleet = fleets.get(fleet_name)
        if not fleet:
            continue
        mfg_id = mfg(fleet_name)
        uuids = [u for u in [uuid(fleet_name)] if u]
        # public addresses get a real OUI; randomized ones get a locally-administered one
        base = oui(fleet_name) if addr_type == "public" else "DA:A1:19"
        if not base:
            base = "DA:A1:19"
        frame = {
            "t": "ble", "node": "NODE-01",
            "addr": base + ":%02X:%02X:%02X" % (0x40 + i, 0x51 + i, 0x62 + i),
            "addr_type": addr_type, "rssi": rssi, "name": name,
            "uuids": uuids, "first_ms": 2100 + i * 120, "last_ms": 41800, "count": 5 + i,
        }
        if mfg_id is not None:
            frame["mfg_id"] = mfg_id
            frame["mfg_hex"] = "0B01" if fleet_name.startswith("Ray") else "0A00"
        frames.append(frame)

    # --- Remote ID frame (service data, same layout as the Android app sees) --
    rid = "0D00" + "00" + "12" + "1596F3A1B2C3D4E5F607"
    frames.append({
        "t": "ble", "node": "NODE-01", "addr": "60:60:1F:22:33:44", "addr_type": "random",
        "rssi": -81, "name": "", "uuids": [],
        "svc_data": [{"u": "FFFA", "h": rid}],
        "first_ms": 2600, "last_ms": 41000, "count": 12,
    })

    frames.append({"t": "scan", "phase": "wifi", "ms": 812, "aps": len(ap_plan),
                   "radios": ["2.4", "5"], "chan_mask": "1,6,11,36,44,149"})
    frames.append({"t": "scan", "phase": "ble", "ms": 640, "radios": ["ble"]})

    with open(out_path, "w") as fh:
        for fr in frames:
            fh.write(json.dumps(fr) + "\n")
    print(f"wrote {len(frames)} frames to {out_path}")


if __name__ == "__main__":
    main()
