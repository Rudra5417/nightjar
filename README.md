# Earshot

An iPhone app that listens to the radio air around you and says what's there — trackers,
body cameras, smart glasses, cameras, drones — plus an optional matchbox-sized sensor node
that fills in the two things iOS refuses to give any app.

Passive and local. No account, no server, no ads. Nothing leaves the phone.

## What works today

| | Status |
|---|---|
| BLE observation with payload signature matching | **working** — name / service UUID / manufacturer data / service data rules |
| Live list, class chips, RSSI strength, session log | **working** |
| Catalog engine ported to Swift, runs on iOS | **working** — 13 tests, all green |
| Sensor node link over BLE GATT (Wi-Fi APs, real MACs, 5 GHz) | **working code, unflashed** — firmware compiles for C5/C6/S3/classic |
| iOS app builds for simulator and device | **working** |
| Background scanning via Live Activity (iOS 26) | **not yet** — see `docs/ios-limits.md` |
| Direction finding, session reports, exports, TAK/CoT | **not yet** |

## The honest coverage story

The catalog that ships in the app is Fieldwatch's stock pack: 244 fleets, 6,962 rules. On an
iPhone alone, **639 of those rules (9.2%) can ever fire** — the rest need a hardware address
or a neighbouring access point, neither of which iOS exposes. Add the node and it goes to
**6,962 / 6,962**.

```
phone alone     639 / 6962 rules usable  (9.2%)    161/244 fleets reachable
phone + node   6962 / 6962 rules usable  (100.0%)  244/244 fleets reachable
```

That number is computed from the pack, not asserted: `Sources/earshot-probe` prints it.

## Layout

```
Sources/EarshotCore/     the engine: models, rule matching, payload decoder, node protocol
Sources/earshot-probe/   CLI: replay a node session, print coverage, run on macOS
App/                     the iOS app (SwiftUI + CoreBluetooth)
firmware/                ESP32 sensor node (see firmware/README.md)
docs/                    what iOS will and will not let an app see
project.yml              XcodeGen spec — the source of truth for the Xcode project
```

## Build

```bash
# engine + tests (no Xcode project needed)
swift test
swift run earshot-probe <path/to/fieldwatch-signatures-v2.json> node-session.sample.jsonl

# app
xcodegen generate                  # regenerates Earshot.xcodeproj from project.yml
open Earshot.xcodeproj             # then set your team and run on the phone
```

`Earshot.xcodeproj` is committed so the repo opens without XcodeGen, but `project.yml` wins if
they disagree — edit the spec, regenerate, commit both.

## Try the engine without a phone

```bash
python3 scripts/make_sample_session.py <pack.json> node-session.sample.jsonl
swift run earshot-probe <pack.json> node-session.sample.jsonl
```

The sample session is generated *from* the pack, so every OUI and company id in it is a real
catalog rule. It replays a Flock pole, an Axon body camera, a Cisco AP by its vendor IE, a
5 GHz Aruba AP, a drone broadcasting Wi-Fi Remote ID, and an AirTag with a randomized address
that must **not** be OUI-matched.

## License and attribution

Earshot is MIT (see `LICENSE`). The rule semantics, catalog format and stock signature pack
come from [OffGridPete/Fieldwatch](https://github.com/OffGridPete/Fieldwatch) — MIT,
© Off Grid Pete LLC; see `NOTICE`. IEEE and Bluetooth SIG assigned-number tables inside the
pack carry their own terms.

Earshot is a separate tool. It is receive-only by design: it never transmits on the air beyond
its own link to your node, never connects to anything it hears, and has no offensive features.
