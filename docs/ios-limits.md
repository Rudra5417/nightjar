# What iOS will and will not let Earshot see

Everything here was checked against Apple's own documentation or a shipping app, not inferred.
It is the reason the node exists.

## Hard walls

| Want | Reality on iOS |
|---|---|
| Peer BLE MAC address / OUI | **Never exposed.** CoreBluetooth yields a per-app `UUID` for a `CBPeripheral`, and Apple states it is not guaranteed stable. OUI vendor lookup is impossible. |
| Enumerate neighbouring Wi-Fi APs | **Not possible.** TN3111: no general-purpose Wi-Fi scanning API. `NEHotspotHelper` is entitlement-gated for hotspot operators, cannot initiate a scan, and in iOS 26 its evaluation provider is sandboxed so it cannot export what it sees. |
| Own hardware MAC | Blocked; queries return a placeholder such as `02:00:00:00:00:00`. |
| ARP / neighbour table for LAN MACs | `sysctl` is sandboxed on iOS. No ARP table. Use mDNS/Bonjour, UPnP or connect probes. |
| Connected AP details | Only `NEHotspotNetwork.fetchCurrent()`, which needs the Access Wi-Fi Information entitlement **and** a qualifying condition (precise location, app-configured network, VPN, DNS config). SSID/BSSID/security only — no RSSI, channel or frequency. |
| AirTag ranging | `NearbyInteraction` (UWB) ranges a peer app or a paired accessory only. AirTag / Find My hardware is unreachable from third-party apps. |

What *is* available in a foreground scan: local name, service UUIDs, manufacturer data
(company id + bytes), service data, Tx power, RSSI. That is enough for payload signature
matching and co-travel heuristics — not for MAC-based identity.

## Background scanning, and the iOS 26 unlock

Default background rules are hostile: only connectable advertisements, only service UUIDs
declared in `Info.plist` under `bluetooth-central`, duplicates forced on, results throttled.
An unfiltered background scan silently returns nothing.

Apple's Core Bluetooth overview documents the escape hatch: **in iOS 26+, if the app has an
instantiated `CBManager` and starts a Live Activity before backgrounding, it keeps foreground
scanning privileges — unfiltered scans (`withServices: nil`) and duplicate reporting
(`CBCentralManagerScanOptionAllowDuplicatesKey`) keep working in the background.**

Until that lands in Earshot, `RadioScanner.setForeground(false)` narrows the scan to the node's
service UUID, so the phone holds the link and the *node* does the listening. That is the
architecture the code is written around.

Reported caveat: on iPhone 17 / N1 silicon some developers see unfiltered background scans stop
entirely. Verify on the actual device before promising background behaviour.

## Consequence

- No MAC/OUI rule may be load-bearing. Of Fieldwatch's 6,962 rules, 6,088 are OUI rules and
  6,323 are unreachable on iOS. Coverage drops to **639 rules / 161 fleets**.
- Identity must be payload-derived: name globs, service UUIDs (normalise 16-bit ↔ Bluetooth
  base form), manufacturer company id + data prefix, service data prefixes.
- A node restores all of it — see `firmware/README.md`. A Flock pole is then identified by
  `B4:1E:52` instead of only by its SSID, and a drone's Wi-Fi Remote ID beacon becomes visible
  at all (stock Android misses that case too).
- Randomized BLE addresses stay unmatched by OUI. `Observation.hasUsableHardwareAddress` keeps
  that honest rather than producing a wrong vendor.
