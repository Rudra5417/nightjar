import Foundation

/// Signature matching engine, ported from Fieldwatch's SignatureEngine.kt.
///
/// Two deliberate differences from the Android original:
///  1. `mac` is optional everywhere — on iOS it is never present for a peer radio.
///  2. A rule that needs a hardware address simply cannot fire; it is reported as
///     "platform-unavailable" instead of silently never matching.
public struct SignatureEngine {
    public let catalog: CatalogFile
    private let enabledFleets: [Fleet]

    public init(catalog: CatalogFile) {
        self.catalog = catalog
        self.enabledFleets = catalog.fleets.filter { $0.enabled }
    }

    public static func load(url: URL) throws -> SignatureEngine {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(CatalogFile.self, from: data)
        return SignatureEngine(catalog: file)
    }

    // MARK: - Rule scoping

    /// nil = matches either radio (mixed / unscoped rule).
    public func ruleScope(_ rule: MatchRule) -> RadioKind? {
        switch rule.kind {
        case .vendorIeOui, .hiddenSsid:
            return .wifi
        case .radioKind:
            return rule.radio
        case .serviceUuid, .serviceData, .manufacturerId, .manufacturerData:
            return rule.radio ?? .ble
        default:
            return rule.radio
        }
    }

    // MARK: - Matching

    public func match(_ obs: Observation) -> [FleetHit] {
        var hits: [FleetHit] = []
        for fleet in enabledFleets where fleetMatches(fleet, obs) {
            let matched = fleet.rules.filter { $0.enabled && ruleHits($0, obs) }
            hits.append(FleetHit(fleet: fleet, matchedRules: matched, decoded: decode(fleet: fleet, obs: obs)))
        }
        return hits.sorted { $0.fleet.name < $1.fleet.name }
    }

    public func fleetMatches(_ fleet: Fleet, _ obs: Observation) -> Bool {
        let rules = fleet.rules.filter { $0.enabled }
        guard !rules.isEmpty else { return false }
        if !fleet.matchAny { return rules.allSatisfy { ruleHits($0, obs) } }
        return rules.contains { ruleHits($0, obs) }
    }

    public func ruleHits(_ rule: MatchRule, _ obs: Observation) -> Bool {
        if rule.kind != .radioKind, let want = rule.radio, want != obs.kind { return false }

        switch rule.kind {
        case .oui, .macPrefix:
            guard let mac = obs.mac else { return false }
            return TextMatch.hexOnly(mac).hasPrefix(TextMatch.hexOnly(rule.text))

        case .nameContains:
            return !obs.name.isEmpty && TextMatch.contains(obs.name, rule.text)

        case .nameGlob:
            return !obs.name.isEmpty && TextMatch.glob(obs.name, rule.text)

        case .serviceUuid:
            let want = UUIDAlias.aliases(rule.text)
            let have = obs.serviceUuids + obs.serviceData.map { $0.uuid }
            return have.contains { uuid in !UUIDAlias.aliases(uuid).isDisjoint(with: want) }

        case .manufacturerId:
            return obs.manufacturerId == rule.companyId

        case .manufacturerData:
            let prefix = TextMatch.hexOnly(rule.dataPrefixHex)
            guard !prefix.isEmpty, let mfg = obs.manufacturerId else { return false }
            guard rule.companyId == 0 || mfg == rule.companyId else { return false }
            return TextMatch.hexOnly(obs.manufacturerDataHex).hasPrefix(prefix)

        case .serviceData:
            let prefix = TextMatch.hexOnly(rule.dataPrefixHex)
            let want = UUIDAlias.aliases(rule.text)
            let hasUuidFilter = !want.isEmpty
            let containsMode = rule.text.isEmpty && !prefix.isEmpty
            for rec in obs.serviceData {
                let uuidOK = !hasUuidFilter || !UUIDAlias.aliases(rec.uuid).isDisjoint(with: want)
                guard uuidOK else { continue }
                let hex = TextMatch.hexOnly(rec.hex)
                if prefix.isEmpty { return true }
                if hex.hasPrefix(prefix) { return true }
                if containsMode && hex.contains(prefix) { return true }
            }
            return false

        case .radioKind:
            return rule.radio == nil || rule.radio == obs.kind

        case .hiddenSsid:
            return obs.hiddenSsid

        case .vendorIeOui:
            return obs.vendorIeOuis.contains { TextMatch.hexOnly($0).hasPrefix(TextMatch.hexOnly(rule.text)) }
        }
    }

    // MARK: - Generic payload decode

    /// Runs the fleet's catalog decode spec against the observation's payload bytes.
    public func decode(fleet: Fleet, obs: Observation) -> [DecodedField] {
        guard let spec = fleet.decode, let fields = spec.fields, !fields.isEmpty else { return [] }

        let payload: Data?
        switch spec.source {
        case "serviceData":
            if let want = spec.serviceUuid.map({ UUIDAlias.aliases($0) }) {
                payload = obs.serviceData
                    .first { !UUIDAlias.aliases($0.uuid).isDisjoint(with: want) }
                    .flatMap { Data(hexString: $0.hex) }
            } else {
                payload = obs.serviceData.first.flatMap { Data(hexString: $0.hex) }
            }
        default:
            payload = Data(hexString: obs.manufacturerDataHex)
        }
        guard let bytes = payload else { return [] }

        var out: [DecodedField] = []
        for field in fields {
            if let gate = field.when {
                let window = bytes.slice(gate.offset, gate.length)
                let want = TextMatch.hexOnly(gate.valueHex)
                let got = window.hexString
                let pass: Bool
                switch gate.op {
                case "eq": pass = got == want
                case "neq": pass = got != want
                default: pass = got == want
                }
                if !pass { continue }
            }
            guard let raw = extract(field, bytes) else { continue }
            let base = format(raw, field)
            let enumLabel = field.cases?[base]
            let note = field.enumNotes?[base]
            let shown = note.map { "\(base) — \($0)" } ?? base
            out.append(DecodedField(id: field.id,
                                    label: field.label,
                                    value: shown,
                                    note: enumLabel,
                                    emphasized: false))
        }
        return out
    }

    private func extract(_ field: DecodeField, _ bytes: Data) -> UInt64? {
        switch field.type {
        case "bits":
            guard let b = bytes.byte(field.offset) else { return nil }
            let width = field.bitWidth ?? 1
            let shift = field.bitOffset ?? 0
            let mask: UInt64 = width >= 64 ? .max : (1 << UInt64(width)) - 1
            return (UInt64(b) >> UInt64(shift)) & mask
        case "u8", "i8", "bool":
            guard let b = bytes.byte(field.offset) else { return nil }
            return UInt64(b)
        case "u16", "i16", "u24", "u32", "i32", "f32":
            let width: Int
            switch field.type {
            case "u16", "i16": width = 2
            case "u24": width = 3
            case "f32": width = 4
            default: width = 4
            }
            let slice = bytes.slice(field.offset, width)
            guard slice.count == width else { return nil }
            var value: UInt64 = 0
            if (field.endian ?? "le") == "le" {
                for (i, b) in slice.enumerated() { value |= UInt64(b) << UInt64(8 * i) }
            } else {
                for b in slice { value = (value << 8) | UInt64(b) }
            }
            return value
        default:
            return nil
        }
    }

    private func format(_ raw: UInt64, _ field: DecodeField) -> String {
        var value = Double(raw)
        if let scale = field.scale { value *= scale }
        if let add = field.offsetAdd { value += add }
        if let mod = field.modulo, mod > 0 { value = value.truncatingRemainder(dividingBy: Double(mod)) }

        var text: String
        switch field.type {
        case "i8":
            text = String(Int8(truncatingIfNeeded: raw))
        case "i16":
            text = String(Int16(truncatingIfNeeded: raw))
        case "i32":
            text = String(Int32(truncatingIfNeeded: raw))
        case "f32":
            text = String(format: "%.6f", Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        default:
            if field.scale != nil || field.offsetAdd != nil || field.modulo != nil {
                text = value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
            } else {
                text = String(raw)
            }
        }
        if let unit = field.unit, !unit.isEmpty { text += " \(unit)" }
        return text
    }
}

// MARK: - Platform portability report

public struct PortabilityReport: Sendable {
    public var totalRules = 0
    public var iosUsableRules = 0
    public var deadRules = 0
    public var fleetsTotal = 0
    public var fleetsWithUsableRule = 0
    public var fleetsLostEntirely: [String] = []
    public var ruleKindCounts: [(kind: RuleKind, total: Int, usable: Int)] = []

    public var usablePercent: Double {
        totalRules == 0 ? 0 : Double(iosUsableRules) / Double(totalRules) * 100
    }
}

extension SignatureEngine {
    /// What survives the move to iOS, computed from the pack itself rather than asserted.
    public func portabilityReport() -> PortabilityReport {
        var report = PortabilityReport()
        var perKind: [RuleKind: (Int, Int)] = [:]

        for fleet in catalog.fleets {
            report.fleetsTotal += 1
            var fleetUsable = false
            for rule in fleet.rules {
                report.totalRules += 1
                let usable = !rule.kind.requiresHardwareAddress && ruleScope(rule) != .wifi
                if usable {
                    report.iosUsableRules += 1
                    fleetUsable = true
                } else {
                    report.deadRules += 1
                }
                var entry = perKind[rule.kind] ?? (0, 0)
                entry.0 += 1
                if usable { entry.1 += 1 }
                perKind[rule.kind] = entry
            }
            if fleetUsable {
                report.fleetsWithUsableRule += 1
            } else {
                report.fleetsLostEntirely.append(fleet.name)
            }
        }
        report.ruleKindCounts = perKind
            .map { (kind: $0.key, total: $0.value.0, usable: $0.value.1) }
            .sorted { $0.total > $1.total }
        return report
    }
}

// MARK: - Data helpers

extension Data {
    init?(hexString: String) {
        let hex = TextMatch.hexOnly(hexString)
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    func byte(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, offset < count, length > 0 else { return Data() }
        let end = Swift.min(offset + length, count)
        return subdata(in: offset..<end)
    }
}
