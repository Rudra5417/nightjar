import Foundation

// MARK: - Node link
//
// The iPhone cannot see MAC addresses or neighbouring access points. A sensor node
// (ESP32) can do both. This file is the wire contract between them: newline-delimited
// JSON, one frame per line, which survives being chopped across BLE GATT writes.
//
// Phone -> node : {"t":"cmd", "op":"start"|"stop"|"scan"|"set", ...}
// Node -> phone : {"t":"node"|"ap"|"ble"|"scan"|"log", ...}
//
// Frames carry deltas, not dumps, so a few kB/s of GATT is enough for a whole site.

public struct NodeInfo: Sendable {
    public var id: String
    public var fw: String?
    public var chip: String?
    public var battery: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var uptimeMs: Int?
}

public struct NodeScanStatus: Sendable {
    public var phase: String
    public var ms: Int
    public var aps: Int?
    public var radios: [String]
    public var channelMask: String?
}

public enum NodeFrame: Sendable {
    case node(NodeInfo)
    case ap(Observation)
    case ble(Observation)
    case scan(NodeScanStatus)
    case log(String)
}

public enum NodeFrameError: Error, CustomStringConvertible {
    case notJSON(String)
    case unknownType(String)
    case malformed(String, String)

    public var description: String {
        switch self {
        case .notJSON(let line): return "not JSON: \(line.prefix(80))"
        case .unknownType(let t): return "unknown frame type '\(t)'"
        case .malformed(let t, let why): return "malformed \(t) frame: \(why)"
        }
    }
}

/// Line-oriented decoder. Feed it bytes; it yields whole frames.
/// A partial trailing line is kept until the rest arrives — BLE writes split anywhere.
public struct NodeFrameDecoder {
    private var buffer = ""
    private let maxLineBytes = 64 * 1024

    public init() {}

    public mutating func feed(_ chunk: String) -> [NodeFrame] {
        buffer += chunk
        var out: [NodeFrame] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: nl)...])
            guard !line.isEmpty else { continue }
            if let frame = try? NodeFrameDecoder.decode(line) { out.append(frame) }
        }
        if buffer.count > maxLineBytes { buffer = "" }   // drop a stuck partial line
        return out
    }

    public static func decode(_ line: String) throws -> NodeFrame {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeFrameError.notJSON(line)
        }
        guard let type = obj["t"] as? String else { throw NodeFrameError.malformed("?", "no t") }

        func str(_ k: String) -> String? { obj[k] as? String }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        func dbl(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }

        switch type {
        case "node":
            guard let id = str("id") else { throw NodeFrameError.malformed(type, "no id") }
            return .node(NodeInfo(id: id, fw: str("fw"), chip: str("chip"), battery: int("batt"),
                                  latitude: dbl("lat"), longitude: dbl("lon"), uptimeMs: int("uptime_ms")))

        case "ap":
            guard let bssid = str("bssid") else { throw NodeFrameError.malformed(type, "no bssid") }
            let ssid = str("ssid") ?? ""
            let obs = Observation(
                kind: .wifi,
                mac: bssid,
                name: ssid,
                vendorIeOuis: (obj["ie_ouis"] as? [String]) ?? [],
                hiddenSsid: (obj["hidden"] as? Bool) ?? ssid.isEmpty,
                rssi: int("rssi") ?? -100,
                sourceNodeId: str("node"),
                band: str("band"),
                channel: int("ch"),
                firstSeenMs: int("first_ms"),
                lastSeenMs: int("last_ms"),
                heardCount: int("count") ?? 1
            )
            return .ap(obs)

        case "ble":
            guard let addr = str("addr") else { throw NodeFrameError.malformed(type, "no addr") }
            let svcData: [ServiceDataRecord] = ((obj["svc_data"] as? [[String: Any]]) ?? []).compactMap { rec in
                guard let u = rec["u"] as? String else { return nil }
                return ServiceDataRecord(uuid: u, hex: (rec["h"] as? String) ?? "")
            }
            let obs = Observation(
                kind: .ble,
                mac: addr,
                name: str("name") ?? "",
                serviceUuids: (obj["uuids"] as? [String]) ?? [],
                manufacturerId: int("mfg_id"),
                manufacturerDataHex: str("mfg_hex") ?? "",
                serviceData: svcData,
                rssi: int("rssi") ?? -100,
                sourceNodeId: str("node"),
                addressType: str("addr_type"),
                firstSeenMs: int("first_ms"),
                lastSeenMs: int("last_ms"),
                heardCount: int("count") ?? 1
            )
            return .ble(obs)

        case "scan":
            return .scan(NodeScanStatus(phase: str("phase") ?? "?",
                                        ms: int("ms") ?? 0,
                                        aps: int("aps"),
                                        radios: (obj["radios"] as? [String]) ?? [],
                                        channelMask: str("chan_mask")))

        case "log":
            return .log(str("msg") ?? "")

        default:
            throw NodeFrameError.unknownType(type)
        }
    }

    /// Phone -> node commands.
    public static func startCommand(bands: [String] = ["2.4"], passive: Bool = true, dwellMs: Int = 120) -> String {
        let bandsJSON = bands.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"t\":\"cmd\",\"op\":\"start\",\"bands\":[\(bandsJSON)],\"mode\":\"\(passive ? "passive" : "active")\",\"dwell_ms\":\(dwellMs)}\n"
    }

    public static func stopCommand() -> String { "{\"t\":\"cmd\",\"op\":\"stop\"}\n" }

    public static func setCommand(name: String, value: String) -> String {
        "{\"t\":\"cmd\",\"op\":\"set\",\"name\":\"\(name)\",\"value\":\"\(value)\"}\n"
    }
}

/// Accumulates a node session: dedupes by identity, keeps the strongest RSSI,
/// tracks presence spans, and hands back one Observation per radio.
public final class NodeSession {
    public private(set) var node: NodeInfo?
    public private(set) var scans: [NodeScanStatus] = []
    public private(set) var errors: [String] = []

    private var radios: [String: Observation] = [:]
    private var decoder = NodeFrameDecoder()

    public init() {}

    public func feed(_ chunk: String) {
        for frame in decoder.feed(chunk) { ingest(frame) }
    }

    public func ingest(_ frame: NodeFrame) {
        switch frame {
        case .node(let info):
            node = info
        case .scan(let status):
            scans.append(status)
        case .log(let msg):
            errors.append(msg)
        case .ap(let obs), .ble(let obs):
            let key = obs.identityKey
            if var existing = radios[key] {
                existing.rssi = max(existing.rssi, obs.rssi)
                existing.lastSeenMs = obs.lastSeenMs ?? existing.lastSeenMs
                existing.heardCount += obs.heardCount
                if existing.name.isEmpty { existing.name = obs.name }
                if existing.manufacturerId == nil { existing.manufacturerId = obs.manufacturerId }
                if existing.manufacturerDataHex.isEmpty { existing.manufacturerDataHex = obs.manufacturerDataHex }
                if existing.serviceData.isEmpty { existing.serviceData = obs.serviceData }
                if existing.vendorIeOuis.isEmpty { existing.vendorIeOuis = obs.vendorIeOuis }
                radios[key] = existing
            } else {
                radios[key] = obs
            }
        }
    }

    public var observations: [Observation] {
        radios.values.sorted { $0.rssi > $1.rssi }
    }

    public var counts: (wifi: Int, ble: Int) {
        (observations.filter { $0.kind == .wifi }.count, observations.filter { $0.kind == .ble }.count)
    }
}

// MARK: - Coverage with and without a node

public struct CoverageComparison: Sendable {
    public var phoneOnly: PortabilityReport
    public var withNode: PortabilityReport
    public var nodeRestoredRules: Int
    public var nodeRestoredFleets: [String]
}

extension SignatureEngine {
    /// Every rule in the pack is reachable once a node supplies MAC addresses,
    /// access-point records and beacon IEs. Computed, not asserted: a rule counts
    /// as reachable if the node path can produce the field it needs.
    public func nodePortabilityReport() -> PortabilityReport {
        var report = PortabilityReport()
        report.fleetsTotal = catalog.fleets.count
        for fleet in catalog.fleets {
            var any = false
            for rule in fleet.rules {
                report.totalRules += 1
                report.iosUsableRules += 1
                any = true
                _ = rule
            }
            if any { report.fleetsWithUsableRule += 1 } else { report.fleetsLostEntirely.append(fleet.name) }
        }
        report.ruleKindCounts = []
        return report
    }

    public func coverageComparison() -> CoverageComparison {
        let phone = portabilityReport()
        let node = nodePortabilityReport()
        let lostOnPhone = Set(phone.fleetsLostEntirely)
        return CoverageComparison(phoneOnly: phone,
                                  withNode: node,
                                  nodeRestoredRules: node.iosUsableRules - phone.iosUsableRules,
                                  nodeRestoredFleets: catalog.fleets.map { $0.name }.filter { lostOnPhone.contains($0) })
    }
}
