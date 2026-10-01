import Foundation
import CoreLocation

/// One line of a session log, as the app writes it.
///
/// The decoder lives in the core rather than in the probe so that the phone, the Mac and any
/// report tool read a session identically, and so the reading can be tested.
public struct LoggedFrame: Sendable {
    public var isWifi: Bool
    public var node: String
    public var address: String
    public var name: String
    public var band: String?
    public var channel: Int?
    public var rssi: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var signatures: [String]
    public var classes: [String]
    public var mode: String?

    public init?(json: [String: Any]) {
        guard let t = json["t"] as? String, t == "ap" || t == "ble" else { return nil }
        isWifi = t == "ap"
        node = (json["node"] as? String) ?? "phone"
        address = (json["addr"] as? String) ?? ""
        name = (json["name"] as? String) ?? ""
        band = json["band"] as? String
        channel = json["ch"] as? Int
        rssi = json["rssi"] as? Int
        latitude = json["lat"] as? Double
        longitude = json["lon"] as? Double
        signatures = (json["signatures"] as? [String]) ?? []
        classes = (json["classes"] as? [String]) ?? []
        mode = json["mode"] as? String
    }

    public var kindLabel: String { isWifi ? "WIFI" : "BLE" }

    /// Identity for counting. On iOS a BLE peer has no MAC, so a name is the only thing that can
    /// line up across two sources — and it is only sometimes there.
    public var key: String {
        address.isEmpty ? "\(kindLabel):name:\(name.lowercased())" : "\(kindLabel):\(address)"
    }

    public var nameKey: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What one source — the phone, or one sensor node — contributed.
public struct SourceTally: Sendable {
    public var frames = 0
    public var radios: Set<String> = []
    public var named: Set<String> = []
    public var names: Set<String> = []
    public var fleets: Set<String> = []
    public var classes: Set<String> = []
    public var bands: Set<String> = []
    public var wifi = 0
    public var ble = 0

    public var label: String { radios.isEmpty ? "nothing" : "\(radios.count) radios · \(named.count) named" }
}

/// The summary of a session log.
public struct SessionTally: Sendable {
    public var frames = 0
    public var geotagged = 0
    public var radios: Set<String> = []
    public var named: Set<String> = []
    public var names: Set<String> = []
    public var fleets: Set<String> = []
    public var classes: Set<String> = []
    public var bands: Set<String> = []
    public var wifi = 0
    public var ble = 0
    public var modes: Set<String> = []
    public var sources: [String: SourceTally] = [:]
    /// Distinct places you stood, clustered the same way the map clusters pins.
    public var places = 0

    public init(frames list: [LoggedFrame], placeRadiusMeters: Double = 60) {
        var coordinates: [CLLocationCoordinate2D] = []
        for frame in list {
            frames += 1
            if let mode = frame.mode { modes.insert(mode) }
            radios.insert(frame.key)
            frame.isWifi ? (wifi += 1) : (ble += 1)
            if let band = frame.band { bands.insert(band) }
            if let name = frame.nameKey { names.insert(name) }
            if !frame.signatures.isEmpty {
                named.insert(frame.key)
                fleets.formUnion(frame.signatures)
                classes.formUnion(frame.classes)
            }
            if let latitude = frame.latitude, let longitude = frame.longitude {
                geotagged += 1
                coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }

            var source = sources[frame.node] ?? SourceTally()
            source.frames += 1
            source.radios.insert(frame.key)
            frame.isWifi ? (source.wifi += 1) : (source.ble += 1)
            if let band = frame.band { source.bands.insert(band) }
            if let name = frame.nameKey { source.names.insert(name) }
            if !frame.signatures.isEmpty {
                source.named.insert(frame.key)
                source.fleets.formUnion(frame.signatures)
                source.classes.formUnion(frame.classes)
            }
            sources[frame.node] = source
        }
        places = coordinates.isEmpty ? 0 : PinSpread.groups(coordinates, minSeparationMeters: placeRadiusMeters).count
    }

    public var namedRatio: Double {
        radios.isEmpty ? 0 : Double(named.count) / Double(radios.count)
    }

    public var modeLabel: String {
        modes.isEmpty ? "untagged" : modes.sorted().joined(separator: "+")
    }
}

/// Compares two session logs: the same route, phone alone versus phone with a sensor node.
///
/// The comparison cannot attribute a node detection to a phone detection. iOS gives the app a
/// per-app UUID and the node a real MAC, so one physical device has two identities and BLE
/// results cannot be matched across sources. Overlap is measured on names, counts and fleets.
public struct SessionComparison: Sendable {
    public let before: SessionTally
    public let after: SessionTally

    public init(before: SessionTally, after: SessionTally) {
        self.before = before
        self.after = after
    }

    public var radioDelta: Int { after.radios.count - before.radios.count }
    public var namedDelta: Int { after.named.count - before.named.count }

    public var newNames: [String] { Array(after.names.subtracting(before.names)).sorted() }
    public var lostNames: [String] { Array(before.names.subtracting(after.names)).sorted() }
    public var newFleets: [String] { Array(after.fleets.subtracting(before.fleets)).sorted() }
    public var newClasses: [String] { Array(after.classes.subtracting(before.classes)).sorted() }
    public var newBands: [String] { Array(after.bands.subtracting(before.bands)).sorted() }

    public var namedMultiple: String {
        guard before.named.count > 0 else { return after.named.isEmpty ? "—" : "no baseline" }
        let ratio = Double(after.named.count) / Double(before.named.count)
        return String(format: "%.1f×", ratio)
    }

    /// The headline: did adding the node change what you could name?
    public var verdict: String {
        guard before.frames > 0 else { return "no baseline session" }
        guard after.frames > 0 else { return "no comparison session" }
        if after.named.count > before.named.count {
            return "the node added \(namedDelta) named radios (\(namedMultiple) the baseline)"
        }
        if after.named.count == before.named.count {
            return "no change in named radios — the node added nothing you could name"
        }
        return "the node named fewer radios than the phone alone — investigate before trusting it"
    }
}

public enum SessionLogReader {
    /// Reads newline JSON. Bad lines are skipped rather than fatal: a log pulled mid-write has a
    /// truncated final line, and losing the session over it would be silly.
    public static func frames(atPath path: String) -> [LoggedFrame] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return frames(inText: text)
    }

    public static func frames(inText text: String) -> [LoggedFrame] {
        var out: [LoggedFrame] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frame = LoggedFrame(json: object) else { continue }
            out.append(frame)
        }
        return out
    }
}
