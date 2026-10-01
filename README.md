# Nightjar

An iPhone app that listens to the radio air around you and says what's there — trackers,
body cameras, smart glasses, cameras, drones — plus an optional matchbox-sized sensor node
that fills in the two things iOS refuses to give any app.

Passive and local. No account, no server, no ads. Nothing leaves the phone.

## What works today

| | Status |
|---|---|
| BLE observation with payload signature matching | **working** — name / service UUID / manufacturer data / service data rules |
| Live list, class chips, RSSI strength, session log | **working** |
| Catalog engine ported to Swift, runs on iOS | **working** — 46 tests, all green |
| Live / Map split with a screener map and geotagged detections | **working** — pins are places *you* stood, never a computed device position |
| Follower alert (co-travel detection) | **working** — 3+ places over 5+ minutes, still nearby, opt-in local notification |
| Muting your own devices | **working** — muted radios leave the list, the map and the follower engine |
| A/B harness: phone alone versus phone + node | **working** — session tagging, live split, `nightjar-probe --ab` |
| Sensor node link over BLE GATT (Wi-Fi APs, real MACs, 5 GHz) | **working code, unflashed** — firmware compiles for C5/C6/S3/classic |
| iOS app builds for simulator and device | **working** |
| Background scanning via Live Activity (iOS 26) | **built** — activity starts and the system accepts it; whether it grants background scan privileges is unverified until it runs on a real phone |
| Session reports, exports, TAK/CoT, multi-node triangulation | **not yet** |

### About the map

A single phone cannot triangulate a BLE device: RSSI gives a range, never a bearing. So the pins
on the map are the positions **you** occupied when a device was heard, not a guessed location for
the device. Tapping a radio shows every place you heard it plus a warm/cold trend from the recent
readings. Standing still produces one cluster — that is the honest answer, not a bug. Real
position fixing needs the two or three nodes in `firmware/`.

### About the follower alert

A device heard at three or more distinct places (clustered at 60 m, so pacing around one building
is one place), spread over at least five minutes, and still being heard now, is travelling with
you. Everything else — a neighbour's television, a router, a camera on a pole — is heard in one
place and is never flagged. Most of the tests for this are about devices that must **not** be
flagged, because a false "something is following you" is worse than a missed one.

One limit worth knowing: iOS's per-app UUID can change if a device rotates its address, so a
follower can appear as two identities. That under-counts. It does not invent followers.

## The honest coverage story

The catalog that ships in the app is Fieldwatch's stock pack: 244 fleets, 6,962 rules. On an
iPhone alone, **639 of those rules (9.2%) can ever fire** — the rest need a hardware address
or a neighbouring access point, neither of which iOS exposes. Add the node and it goes to
**6,962 / 6,962**.

```
phone alone     639 / 6962 rules usable  (9.2%)    161/244 fleets reachable
phone + node   6962 / 6962 rules usable  (100.0%)  244/244 fleets reachable
```

That number is computed from the pack, not asserted: `Sources/nightjar-probe` prints it.

## Does the node earn its place? Walk it twice

The coverage number above is what the *pack* allows. Whether the node actually finds anything on
your street is a different question, and the only honest way to answer it is to walk the same
route twice.

1. In the app's ⓘ sheet, tag the walk **Phone only** and walk the route.
2. Tag the next walk **Phone + node**, power the node up, walk the same route again.

Session files are named `sit-<timestamp>-phone.jsonl` and `sit-<timestamp>-node.jsonl`, and every
line carries its mode, so the two halves stay labelled months later. Then, on the Mac:

```bash
swift run nightjar-probe --ab sit-...-phone.jsonl sit-...-node.jsonl
```

It reports what the node added — radios, named radios, fleets, classes, bands — and says plainly
when the answer is "nothing you could name".

**What it will not claim.** iOS gives the app a per-app UUID and the node a real MAC, so one
physical device has two identities and BLE results **cannot** be matched across the two sources.
Overlap is measured on names, counts and fleets. The union of the two radio counts is not a device
count — it is an upper bound.

## Layout

```
Sources/NightjarCore/     the engine: models, rule matching, payload decoder, node protocol
Sources/nightjar-probe/   CLI: replay a node session, print coverage, run on macOS
App/                     the iOS app (SwiftUI + CoreBluetooth)
firmware/                ESP32 sensor node (see firmware/README.md)
docs/                    what iOS will and will not let an app see
project.yml              XcodeGen spec — the source of truth for the Xcode project
```

## Build

```bash
# engine + tests (no Xcode project needed)
swift test
swift run nightjar-probe <path/to/fieldwatch-signatures-v2.json> node-session.sample.jsonl
swift run nightjar-probe --pins <session.jsonl>                  # how a session will be drawn on the map
swift run nightjar-probe --ab <baseline.jsonl> <with-node.jsonl> # the same walk, twice
swift run nightjar-probe --profile <SomeApp.app>                 # sideload expiry, no Xcode needed

# app
xcodegen generate                  # regenerates Nightjar.xcodeproj from project.yml
open Nightjar.xcodeproj             # then set your team and run on the phone
```

`Nightjar.xcodeproj` is committed so the repo opens without XcodeGen, but `project.yml` wins if
they disagree — edit the spec, regenerate, commit both.

## Keeping it alive without paying Apple

A free Apple ID signs a build for **7 days**; after that the app stops opening until it's
re-signed. Nightjar reads its own `embedded.mobileprovision`, shows the countdown on screen, and
schedules local notifications 48h and 12h before expiry — local notifications need no paid
account, and the app is the only thing in the system that knows the real deadline.

You can check any sideloaded build's clock from the command line, without Xcode:

```bash
swift run nightjar-probe --profile /path/to/SomeApp.app
```

```
profile      iOS Team Provisioning Profile: com.example.thing
team         TEAMID
app id       TEAMID.com.example.thing
expires      2026-09-27T22:31:25Z
remaining    expired   <-- will not launch
```

### Signing needs an Apple ID in Xcode

`-allowProvisioningUpdates` mints the profile from the account Xcode holds. If Xcode's account
list is empty the build fails with `No Accounts: Add a new account in Accounts settings` — no
amount of retrying fixes it, and no script can supply the credentials. Add the account once in
**Xcode > Settings > Accounts > +**, then:

```bash
scripts/run-on-device.sh            # build, install, stream the console
scripts/run-on-device.sh --build-only
```

Re-signing needs the phone plugged into your Mac (or on the same Wi-Fi) once a week. Nothing
else about the app cares: it runs offline, anywhere, in airplane mode, in any country.

| Route | Laptop needed | Notes |
|---|---|---|
| Xcode, plug in | ~30s/week by hand | simplest, nothing to break |
| SideStep / AltServer on a Mac | ~10 min/week, scheduled | `sudo pmset repeat wakeorpoweron SU 03:00:00` gives the Mac a weekly wake window instead of running it 24/7 |
| SideStore on the phone | never | refreshes on-device; breaks on iOS point releases |

**Missing the deadline costs no data.** A lapsed signature means the app won't open; the session
log in Documents survives and is there again after re-signing. If the node is running standalone
it never notices at all.

The app declares no paid-only capability — no push, no iCloud, no App Groups, no Access Wi-Fi
Information — so nothing in it stops working on a free account.

## Try the engine without a phone

```bash
python3 scripts/make_sample_session.py <pack.json> node-session.sample.jsonl
swift run nightjar-probe <pack.json> node-session.sample.jsonl
```

The sample session is generated *from* the pack, so every OUI and company id in it is a real
catalog rule. It replays a Flock pole, an Axon body camera, a Cisco AP by its vendor IE, a
5 GHz Aruba AP, a drone broadcasting Wi-Fi Remote ID, and an AirTag with a randomized address
that must **not** be OUI-matched.

## License and attribution

Nightjar is MIT (see `LICENSE`). The rule semantics, catalog format and stock signature pack
come from [OffGridPete/Fieldwatch](https://github.com/OffGridPete/Fieldwatch) — MIT,
© Off Grid Pete LLC; see `NOTICE`. IEEE and Bluetooth SIG assigned-number tables inside the
pack carry their own terms.

Nightjar is a separate tool. It is receive-only by design: it never transmits on the air beyond
its own link to your node, never connects to anything it hears, and has no offensive features.
