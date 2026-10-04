import Foundation
import CoreLocation
import NightjarCore

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}

// nightjar-probe — loads the Fieldwatch catalog pack and classifies synthetic radio
// observations as iOS presents them, then reports what survives the port from Android.
//
// usage: nightjar-probe [path/to/fieldwatch-signatures-v2.json]

let args = CommandLine.arguments

// Diagnose the 7-day clock on any sideloaded build, without Xcode:
//   nightjar-probe --profile /path/to/App.app    (or a .mobileprovision)
if args.count > 2 && args[1] == "--profile" {
    let target = URL(fileURLWithPath: args[2])
    let embedded = target.pathExtension == "app"
        ? target.appendingPathComponent("embedded.mobileprovision")
        : target
    guard let data = try? Data(contentsOf: embedded),
          let profile = ProvisioningProfile.parse(cmsData: data) else {
        FileHandle.standardError.write(Data("no provisioning profile at \(embedded.path)\n".utf8))
        exit(2)
    }
    let iso = ISO8601DateFormatter()
    line("source       \(embedded.path)")
    line("profile      \(profile.name ?? "-")")
    line("team         \(profile.teamIdentifier ?? "-")")
    line("app id       \(profile.applicationIdentifier ?? "-")")
    line("created      \(profile.creationDate.map { iso.string(from: $0) } ?? "-")")
    line("expires      \(iso.string(from: profile.expirationDate))")
    line("remaining    \(profile.remainingLabel())\(profile.isExpired() ? "   <-- will not launch" : "")")
    exit(0)
}

// Show how a session's detections will actually be drawn on the map:
//   nightjar-probe --pins path/to/sit-....jsonl
if args.count > 2 && args[1] == "--pins" {
    let url = URL(fileURLWithPath: args[2])
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
        exit(2)
    }
    var lastPoint: [String: (Double, Double)] = [:]
    var frameCount = 0
    var geotagged = 0
    for line in text.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        frameCount += 1
        guard let lat = object["lat"] as? Double, let lon = object["lon"] as? Double else { continue }
        geotagged += 1
        let key = (object["addr"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (object["name"] as? String) ?? "?"
        lastPoint[key] = (lat, lon)
    }
    let coords = lastPoint.values.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
    let spread = PinSpread.spread(coords)
    let before = Set(coords.map { "\($0.latitude.rounded(toPlaces: 5))|\($0.longitude.rounded(toPlaces: 5))" }).count
    let after = Set(spread.map { "\($0.latitude.rounded(toPlaces: 6))|\($0.longitude.rounded(toPlaces: 6))" }).count

    line("frames            \(frameCount)")
    line("geotagged         \(geotagged)")
    line("devices located   \(coords.count)")
    line("distinct places   \(before)   (before spreading)")
    line("visible pins      \(after)   (after spreading)")
    line("spread needed     \(PinSpread.needsSpreading(coords) ? "yes" : "no")")
    exit(0)
}

// The same walk twice — phone alone, then phone plus a sensor node:
//   nightjar-probe --ab baseline.jsonl with-node.jsonl
if args.count > 3 && args[1] == "--ab" {
    let beforePath = args[2], afterPath = args[3]
    let before = SessionTally(frames: SessionLogReader.frames(atPath: beforePath))
    let after = SessionTally(frames: SessionLogReader.frames(atPath: afterPath))
    guard before.frames > 0, after.frames > 0 else {
        FileHandle.standardError.write(Data("one of the logs is empty or unreadable\n".utf8))
        exit(2)
    }
    let diff = SessionComparison(before: before, after: after)

    func headline(_ tag: String, _ path: String, _ tally: SessionTally) {
        line("\(tag)  \((path as NSString).lastPathComponent)")
        line("   mode \(tally.modeLabel) · \(tally.frames) frames · \(tally.radios.count) radios · \(tally.named.count) named · \(tally.places) places")
    }
    headline("A", beforePath, before)
    headline("B", afterPath, after)
    line("")
    line("what the node added")
    line("   radios     \(diff.radioDelta >= 0 ? "+" : "")\(diff.radioDelta)")
    line("   named      \(diff.namedDelta >= 0 ? "+" : "")\(diff.namedDelta)   (\(diff.namedMultiple) baseline)")
    if !diff.newFleets.isEmpty {
        line("   fleets     +\(diff.newFleets.count)")
        for fleet in diff.newFleets.prefix(12) { line("                \(fleet)") }
    }
    if !diff.newClasses.isEmpty { line("   classes    \(diff.newClasses.joined(separator: ", "))") }
    if !diff.newBands.isEmpty { line("   bands      \(diff.newBands.joined(separator: ", ")) GHz") }
    if !diff.newNames.isEmpty {
        line("")
        line("named in B, never heard by A")
        for name in diff.newNames.prefix(20) { line("   \(name)") }
        if diff.newNames.count > 20 { line("   … and \(diff.newNames.count - 20) more") }
    }
    line("")
    line("per source in B")
    for (source, tally) in after.sources.sorted(by: { $0.value.radios.count > $1.value.radios.count }) {
        let pad = source.padding(toLength: 10, withPad: " ", startingAt: 0)
        line("   \(pad) \(tally.radios.count) radios · \(tally.named.count) named · \(tally.frames) frames")
    }
    line("")
    line("verdict: \(diff.verdict)")
    line("")
    line("note: BLE identities cannot be matched across sources — iOS gives this app a per-app UUID")
    line("      and the node a real MAC. Overlap is measured on names, counts and fleets, not identity.")
    exit(0)
}

let catalogPath = args.count > 1
    ? args[1]
    : "\(NSHomeDirectory())/.hermes/cache/scratch/fw/Fieldwatch/dist/fieldwatch-signatures-v2.json"

func line(_ s: String = "") { print(s) }
func header(_ s: String) { print("\n=== \(s) ===") }

guard FileManager.default.fileExists(atPath: catalogPath) else {
    FileHandle.standardError.write(Data("catalog not found: \(catalogPath)\n".utf8))
    exit(2)
}

let engine: SignatureEngine
do {
    engine = try SignatureEngine.load(url: URL(fileURLWithPath: catalogPath))
} catch {
    FileHandle.standardError.write(Data("failed to load catalog: \(error)\n".utf8))
    exit(1)
}

header("catalog")
line("pack        \(engine.catalog.format ?? "?") v\(engine.catalog.formatVersion ?? 0)  appVersion \(engine.catalog.appVersion ?? "?")")
line("catalogVer  \(engine.catalog.catalogVersion)")
line("fleets      \(engine.catalog.fleets.count) (\(engine.catalog.fleets.filter { $0.enabled }.count) enabled)")
line("rules       \(engine.catalog.fleets.reduce(0) { $0 + $1.rules.count })")

// A Remote ID Basic ID frame as it arrives in BLE service data FFFA:
// [0x0D app code][counter][msg_type|proto][id_type|ua_type][20-byte UAS ID]
let remoteIdSerial = "1596F3A1B2C3D4E5F607"
var remoteIdBytes: [UInt8] = [0x0D, 0x00, 0x00, 0x12]
remoteIdBytes += Array(remoteIdSerial.utf8)
let remoteIdHex = remoteIdBytes.map { String(format: "%02X", $0) }.joined()

// DULT (IETF Detecting Unwanted Location Trackers) on service data FCB2:
// [network id][mode: 1 bit, 0 = separated, 1 = near owner]
let dultHex = "4A00"

// Google Find Hub on FEAA: [mode 0x41 = separated][20-byte ephemeral id]
let findHubHex = "41" + String(repeating: "AB", count: 20)

header("observations iOS can actually build")

let cases: [(String, Observation)] = [
    ("AirTag / Find My accessory (name + FD44 + Apple mfg 0x12)",
     Observation(kind: .ble, name: "AirTag", serviceUuids: ["FD44"], manufacturerId: 0x004C,
                 manufacturerDataHex: "121A00", rssi: -55)),

    ("Axon body camera (advertised name only — no OUI available)",
     Observation(kind: .ble, name: "Axon Body 4", rssi: -70)),

    ("Axon dock (service UUID FE6B)",
     Observation(kind: .ble, name: "", serviceUuids: ["FE6B"], rssi: -66)),

    ("Remote ID drone (service data FFFA, Basic ID message)",
     Observation(kind: .ble, name: "", serviceData: [ServiceDataRecord(uuid: "FFFA", hex: remoteIdHex)], rssi: -78)),

    ("DULT tracker (service data FCB2, separated mode)",
     Observation(kind: .ble, name: "", serviceData: [ServiceDataRecord(uuid: "FCB2", hex: dultHex)], rssi: -80)),

    ("Google Find Hub tag (service data FEAA prefix 41 = separated)",
     Observation(kind: .ble, name: "", serviceData: [ServiceDataRecord(uuid: "FEAA", hex: findHubHex)], rssi: -84)),

    ("Meta / Ray-Ban glasses (Bluetooth SIG company id 427)",
     Observation(kind: .ble, name: "", manufacturerId: 427, manufacturerDataHex: "0B01", rssi: -72)),

    ("Flock Safety pole, BLE name only (the OUI rule cannot fire on iOS)",
     Observation(kind: .ble, name: "Flock-4C21AB", rssi: -88)),

    ("DJI aircraft (company id 2218 = 0x08AA)",
     Observation(kind: .ble, name: "", manufacturerId: 2218, manufacturerDataHex: "0A00", rssi: -75)),

    ("unremarkable peripheral (negative control)",
     Observation(kind: .ble, name: "MyPrinter-3f2a", rssi: -60)),
]

var positiveCount = 0
for (title, obs) in cases {
    let hits = engine.match(obs)
    if !hits.isEmpty { positiveCount += 1 }
    line("")
    line("• \(title)")
    line("  seen as: kind=\(obs.kind.rawValue) name=\"\(obs.name)\" mac=\(obs.mac ?? "nil (iOS)") uuids=\(obs.serviceUuids) mfg=\(obs.manufacturerId.map { String($0) } ?? "-")")
    if hits.isEmpty {
        line("  -> no signature")
    } else {
        for hit in hits {
            let cls = hit.fleet.kind?.label ?? "-"
            let via = hit.matchedRules.map { "\($0.kind.rawValue)=\($0.pattern)" }.joined(separator: ", ")
            line("  -> \(hit.fleet.name)  [\(cls)]  \(hit.confidence.label)  via \(via)")
            for d in hit.decoded {
                line("       decode \(d.label) = \(d.value)\(d.note.map { " (\($0))" } ?? "")")
            }
        }
    }
}

// The capability Android has and iOS cannot: OUI matching against a real BSSID.
header("the Wi-Fi half (Android only — shown for contrast)")
let apObservation = Observation(kind: .wifi, mac: "B4:1E:52:11:22:33", name: "Flock-4C21AB", rssi: -61)
for hit in engine.match(apObservation) {
    line("• BSSID \(apObservation.mac ?? "") -> \(hit.fleet.name) via \(hit.matchedRules.map { $0.kind.rawValue }.joined(separator: ", "))")
}
line("• same BLE frame with mac=nil -> Flock OUI rule cannot fire; only the name rule survives")

header("what survives the port")
let report = engine.portabilityReport()
line(String(format: "rules usable on iOS   %d / %d  (%.1f%%)", report.iosUsableRules, report.totalRules, report.usablePercent))
line("rules structurally dead \(report.deadRules)  (need a MAC or a neighbouring AP)")
line("fleets still reachable  \(report.fleetsWithUsableRule) / \(report.fleetsTotal)")
line("")
line("by rule kind (total / usable):")
for row in report.ruleKindCounts {
    line("  " + row.kind.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "%5d / %5d", row.total, row.usable))
}
line("")
line("fleets that vanish entirely on iOS (\(report.fleetsLostEntirely.count)):")
line("  " + report.fleetsLostEntirely.prefix(40).joined(separator: ", ") + (report.fleetsLostEntirely.count > 40 ? " …" : ""))

// MARK: - sensor node replay

header("with a sensor node in the field")

let nodePath = args.count > 2 ? args[2] : "node-session.sample.jsonl"
let nodeURL = URL(fileURLWithPath: nodePath)
if FileManager.default.fileExists(atPath: nodeURL.path),
   let sessionText = try? String(contentsOf: nodeURL, encoding: .utf8) {
    let session = NodeSession()
    // Feed it in awkward chunks to prove the line decoder survives split BLE writes.
    var idx = sessionText.startIndex
    while idx < sessionText.endIndex {
        let end = sessionText.index(idx, offsetBy: 97, limitedBy: sessionText.endIndex) ?? sessionText.endIndex
        session.feed(String(sessionText[idx..<end]))
        idx = end
    }
    if let node = session.node {
        line("node \(node.id)  fw \(node.fw ?? "?")  chip \(node.chip ?? "?")  battery \(node.battery.map { "\($0)%" } ?? "-")")
    }
    let counts = session.counts
    line("radios reported: \(counts.wifi) access points, \(counts.ble) BLE advertisers")
    line("scan phases: " + session.scans.map { "\($0.phase) \($0.ms)ms" }.joined(separator: ", "))
    line("")

    var nodeHits = 0
    for obs in session.observations {
        let hits = engine.match(obs)
        if !hits.isEmpty { nodeHits += 1 }
        let where_ = obs.sourceNodeId.map { "node \($0)" } ?? "phone"
        let addr = obs.mac ?? "nil"
        let extra = [obs.band.map { "\($0)GHz" }, obs.channel.map { "ch\($0)" }, obs.addressType].compactMap { $0 }.joined(separator: " ")
        line("• [\(where_)] \(obs.kind.rawValue) \(addr) \(extra) rssi \(obs.rssi) \"\(obs.name)\"")
        for hit in hits {
            let via = hit.matchedRules.map { "\($0.kind.rawValue)=\($0.pattern)" }.joined(separator: ", ")
            line("    -> \(hit.fleet.name)  [\(hit.fleet.kind?.label ?? "-")]  \(hit.confidence.label)  via \(via)")
        }
        if hits.isEmpty { line("    -> no signature") }
    }
    line("")
    line("\(nodeHits) of \(session.observations.count) node radios matched a signature")
} else {
    line("no node session at \(nodePath) — run scripts/make_sample_session.py")
}

header("coverage: phone alone vs phone + node")
let cov = engine.coverageComparison()
line(String(format: "phone alone   %5d / %d rules usable  (%.1f%%)   %d/%d fleets reachable",
             cov.phoneOnly.iosUsableRules, cov.phoneOnly.totalRules, cov.phoneOnly.usablePercent,
             cov.phoneOnly.fleetsWithUsableRule, cov.phoneOnly.fleetsTotal))
line(String(format: "phone + node  %5d / %d rules usable  (%.1f%%)   %d/%d fleets reachable",
             cov.withNode.iosUsableRules, cov.withNode.totalRules,
             Double(cov.withNode.iosUsableRules) / Double(cov.withNode.totalRules) * 100,
             cov.withNode.fleetsWithUsableRule, cov.withNode.fleetsTotal))
line("")
line("node restores \(cov.nodeRestoredRules) rules and \(cov.nodeRestoredFleets.count) fleets:")
line("  " + cov.nodeRestoredFleets.prefix(30).joined(separator: ", ") + (cov.nodeRestoredFleets.count > 30 ? " …" : ""))

header("result")
line("\(positiveCount) of \(cases.count) observations matched at least one signature")
exit(0)
