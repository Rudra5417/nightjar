import Foundation

// MARK: - Platform-neutral radio vocabulary
//
// Ported from Fieldwatch (MIT, (c) Off Grid Pete LLC) Models.kt / SignatureEngine.kt.
// Rule semantics, glob/contains behaviour and radio scoping mirror the Android original
// so a stock catalog pack keeps meaning on Apple platforms.

public enum RadioKind: String, Codable, Sendable {
    case wifi = "WIFI"
    case ble = "BLE"
}

public enum RuleKind: String, Codable, Sendable {
    case oui = "OUI"
    case macPrefix = "MAC_PREFIX"
    case nameContains = "NAME_CONTAINS"
    case nameGlob = "NAME_GLOB"
    case serviceUuid = "SERVICE_UUID"
    case serviceData = "SERVICE_DATA"
    case manufacturerId = "MANUFACTURER_ID"
    case manufacturerData = "MANUFACTURER_DATA"
    case radioKind = "RADIO_KIND"
    case hiddenSsid = "HIDDEN_SSID"
    case vendorIeOui = "VENDOR_IE_OUI"

    /// Rules that can never fire on iOS: no MAC address is ever exposed for a
    /// peer radio, and no neighbouring access point is enumerable.
    public var requiresHardwareAddress: Bool {
        switch self {
        case .oui, .macPrefix, .vendorIeOui: return true
        default: return false
        }
    }
}

public struct MatchRule: Codable, Sendable {
    public var kind: RuleKind
    public var text: String
    public var companyId: Int
    public var dataPrefixHex: String
    public var radio: RadioKind?
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case kind, text, companyId, dataPrefixHex, radio, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(RuleKind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        companyId = try c.decodeIfPresent(Int.self, forKey: .companyId) ?? 0
        dataPrefixHex = try c.decodeIfPresent(String.self, forKey: .dataPrefixHex) ?? ""
        radio = try c.decodeIfPresent(RadioKind.self, forKey: .radio)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public init(kind: RuleKind,
                text: String = "",
                companyId: Int = 0,
                dataPrefixHex: String = "",
                radio: RadioKind? = nil,
                enabled: Bool = true) {
        self.kind = kind
        self.text = text
        self.companyId = companyId
        self.dataPrefixHex = dataPrefixHex
        self.radio = radio
        self.enabled = enabled
    }
}

public enum SignatureClass: String, Codable, Sendable {
    case finder = "FINDER", beacon = "BEACON", signage = "SIGNAGE", wearable = "WEARABLE"
    case surveillance = "SURVEILLANCE", drone = "DRONE", hacking = "HACKING", bodyworn = "BODYWORN"
    case lawEnforcement = "LAW_ENFORCEMENT", vehicle = "VEHICLE", glasses = "GLASSES", audio = "AUDIO"
    case camera = "CAMERA", thermostat = "THERMOSTAT", lock = "LOCK", health = "HEALTH"
    case home = "HOME", isp = "ISP", mesh = "MESH", phone = "PHONE", other = "OTHER"

    public var label: String {
        switch self {
        case .finder: return "Finder tags"
        case .beacon: return "Retail beacons"
        case .signage: return "Signage"
        case .wearable, .bodyworn: return "Wearables"
        case .surveillance: return "Surveillance"
        case .drone: return "Drones"
        case .hacking: return "Pentest"
        case .lawEnforcement: return "Public safety"
        case .vehicle: return "Vehicle"
        case .glasses: return "Glasses"
        case .audio: return "Audio"
        case .camera: return "Cameras"
        case .thermostat: return "Thermostats"
        case .lock: return "Access control"
        case .health: return "Health"
        case .home: return "Home IoT"
        case .isp: return "ISP / routers"
        case .mesh: return "Mesh"
        case .phone: return "Phones / PCs"
        case .other: return "Other"
        }
    }
}

// MARK: - Decode spec (generic field descriptor, as shipped in the catalog pack)

public struct DecodeWhen: Codable, Sendable {
    public var offset: Int
    public var length: Int
    public var op: String
    public var valueHex: String
}

public struct DecodeField: Codable, Sendable {
    public var id: String
    public var label: String
    public var offset: Int
    public var length: Int?
    public var type: String
    public var endian: String?
    public var bitOffset: Int?
    public var bitWidth: Int?
    public var scale: Double?
    public var offsetAdd: Double?
    public var modulo: Int?
    public var unit: String?
    public var cases: [String: String]?
    public var live: Bool?
    public var enumNotes: [String: String]?
    public var when: DecodeWhen?

    enum CodingKeys: String, CodingKey {
        case id, label, offset, length, type, endian, bitOffset, bitWidth
        case scale, offsetAdd, modulo, unit, live, enumNotes, when
        case cases = "enum"
    }
}

public struct DecodeSpec: Codable, Sendable {
    public var source: String          // "manufacturerData" | "serviceData"
    public var serviceUuid: String?
    public var companyId: Int?
    public var fields: [DecodeField]?
}

public struct Fleet: Codable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var matchAny: Bool
    public var kind: SignatureClass?
    public var notes: String?
    public var attentionNote: String?
    public var builtIn: Bool?
    public var rules: [MatchRule]
    public var decode: DecodeSpec?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, matchAny, kind, notes, attentionNote, builtIn, rules, decode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchAny = try c.decodeIfPresent(Bool.self, forKey: .matchAny) ?? true
        kind = try c.decodeIfPresent(SignatureClass.self, forKey: .kind)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        attentionNote = try c.decodeIfPresent(String.self, forKey: .attentionNote)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn)
        rules = try c.decodeIfPresent([MatchRule].self, forKey: .rules) ?? []
        decode = try c.decodeIfPresent(DecodeSpec.self, forKey: .decode)
    }

    public init(id: String,
                name: String,
                enabled: Bool = true,
                matchAny: Bool = true,
                kind: SignatureClass? = nil,
                notes: String? = nil,
                attentionNote: String? = nil,
                builtIn: Bool? = nil,
                rules: [MatchRule] = [],
                decode: DecodeSpec? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchAny = matchAny
        self.kind = kind
        self.notes = notes
        self.attentionNote = attentionNote
        self.builtIn = builtIn
        self.rules = rules
        self.decode = decode
    }
}

public struct CatalogFile: Codable, Sendable {
    public var format: String?
    public var formatVersion: Int?
    public var appVersion: String?
    public var catalogVersion: Int
    public var fleets: [Fleet]
}

// MARK: - What a scan produced, platform-independent

public struct ServiceDataRecord: Sendable, Equatable {
    public var uuid: String
    public var hex: String
    public init(uuid: String, hex: String) {
        self.uuid = uuid
        self.hex = hex
    }
}

/// A single radio as the OS let us see it.
///
/// `mac` is nil on iOS for every BLE peer (CoreBluetooth only yields a per-app
/// UUID) and nil for Wi-Fi unless the app holds Apple's Access Wi-Fi Information
/// entitlement and is joined to that one network.
public struct Observation: Sendable {
    public var kind: RadioKind
    public var mac: String?
    public var name: String
    public var serviceUuids: [String]
    public var manufacturerId: Int?
    public var manufacturerDataHex: String
    public var serviceData: [ServiceDataRecord]
    public var vendorIeOuis: [String]
    public var hiddenSsid: Bool
    public var rssi: Int
    /// Where this was heard: nil = this iPhone. Otherwise the sensor node's id.
    public var sourceNodeId: String?
    /// Wi-Fi only, from the node. "2.4" | "5" | "6"
    public var band: String?
    public var channel: Int?
    /// BLE address type: "public" addresses carry a real OUI, "random" ones do not.
    public var addressType: String?
    /// The platform's own opaque handle for this radio. On iOS that is CoreBluetooth's
    /// per-app `CBPeripheral.identifier` — stable inside this app, meaningless outside it,
    /// and deliberately never used for OUI matching.
    public var platformId: String?
    public var firstSeenMs: Int?
    public var lastSeenMs: Int?
    public var heardCount: Int

    public init(kind: RadioKind,
                mac: String? = nil,
                name: String = "",
                serviceUuids: [String] = [],
                manufacturerId: Int? = nil,
                manufacturerDataHex: String = "",
                serviceData: [ServiceDataRecord] = [],
                vendorIeOuis: [String] = [],
                hiddenSsid: Bool = false,
                rssi: Int = -60,
                sourceNodeId: String? = nil,
                band: String? = nil,
                channel: Int? = nil,
                addressType: String? = nil,
                platformId: String? = nil,
                firstSeenMs: Int? = nil,
                lastSeenMs: Int? = nil,
                heardCount: Int = 1) {
        self.kind = kind
        self.mac = mac
        self.name = name
        self.serviceUuids = serviceUuids
        self.manufacturerId = manufacturerId
        self.manufacturerDataHex = manufacturerDataHex
        self.serviceData = serviceData
        self.vendorIeOuis = vendorIeOuis
        self.hiddenSsid = hiddenSsid
        self.rssi = rssi
        self.sourceNodeId = sourceNodeId
        self.band = band
        self.channel = channel
        self.addressType = addressType
        self.platformId = platformId
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
        self.heardCount = heardCount
    }

    /// True when the address is real enough for an OUI lookup to mean anything.
    public var hasUsableHardwareAddress: Bool {
        guard let mac, !mac.isEmpty else { return false }
        if kind == .ble, let addressType, addressType.lowercased() != "public" { return false }
        return true
    }

    /// CoreBluetooth reports 127 when it has no signal strength reading for a peripheral
    /// (commonly for a device already connected to something else). It is a sentinel, not a
    /// measurement — 127 dBm does not exist — so it must never be logged or sorted as one.
    public static let unknownRssi = 127

    public var rssiIsKnown: Bool { rssi != Observation.unknownRssi && rssi <= 0 }

    /// Sortable strength: unknown readings rank below every real one.
    public var sortableRssi: Int { rssiIsKnown ? rssi : -999 }

    /// Stable-ish identity for a session. iOS gives no MAC, so this is what we have.
    public var identityKey: String {
        if let mac, !mac.isEmpty { return "\(kind.rawValue):\(mac)" }
        if let platformId, !platformId.isEmpty { return "\(kind.rawValue):plat:\(platformId)" }
        if !name.isEmpty { return "\(kind.rawValue):name:\(name.lowercased())" }
        if let mfg = manufacturerId {
            return "\(kind.rawValue):mfg:\(mfg):\(TextMatch.hexOnly(manufacturerDataHex).prefix(8))"
        }
        if let sd = serviceData.first { return "\(kind.rawValue):sd:\(sd.uuid):\(TextMatch.hexOnly(sd.hex).prefix(8))" }
        return "\(kind.rawValue):unknown"
    }
}

public struct FleetHit: Sendable {
    public var fleet: Fleet
    public var matchedRules: [MatchRule]
    public var decoded: [DecodedField]
    /// How much the matched rules actually establish. See `Confidence`.
    public var confidence: Confidence

    public init(fleet: Fleet,
                matchedRules: [MatchRule],
                decoded: [DecodedField],
                confidence: Confidence) {
        self.fleet = fleet
        self.matchedRules = matchedRules
        self.decoded = decoded
        self.confidence = confidence
    }
}

public struct DecodedField: Sendable {
    public var id: String
    public var label: String
    public var value: String
    public var note: String?
    public var emphasized: Bool
}

// MARK: - Confidence

/// How much a match actually establishes.
///
/// A catalog rule is not a statement of identity. `MANUFACTURER_ID 117` says a radio was made by
/// Samsung; it does not say that a television is a tracker. `NAME_CONTAINS "DJI"` says those three
/// letters appear in an advertised name, which is equally true of a Windows host called
/// `DESKTOP-KOQDJIH`. Reporting both at the same weight as `SERVICE_UUID FD5A` is how a scanner
/// teaches its user to ignore it, so every hit carries the strength of the evidence behind it.
public enum Confidence: Int, Codable, Sendable, Comparable, CaseIterable {
    /// A vendor id, a radio type, or a hidden network. Describes a category, not a product.
    case possible = 0
    /// A name matching a product family, on whole words.
    case probable = 1
    /// An identifier belonging to the device itself: a service UUID, a payload prefix, an OUI.
    case certain = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .possible: return "possible"
        case .probable: return "likely"
        case .certain: return "identified"
        }
    }

    /// What the tier claims, in one sentence, for the evidence view.
    public var claim: String {
        switch self {
        case .possible:
            return "One weak rule matched. That narrows the vendor or the category, not the product."
        case .probable:
            return "A name matched as a whole word. That identifies the product family, and a name can be changed by whoever owns the device."
        case .certain:
            return "An identifier belonging to the device itself matched. Changing a name cannot fake that."
        }
    }

    public func promoted() -> Confidence {
        switch self {
        case .possible: return .probable
        case .probable, .certain: return .certain
        }
    }
}

/// The kind of evidence a rule represents. Two rules of the same class are the same evidence
/// twice, not corroboration: a name match agreeing with another name match says nothing new.
public enum EvidenceClass: Sendable {
    /// Belongs to the device: a service UUID, a payload prefix, a hardware address.
    case identifier
    /// A name the device advertises, which its owner can change.
    case name
    /// A vendor id, a radio type, a hidden network — a category, not a product.
    case weak
}

extension RuleKind {
    public var evidenceClass: EvidenceClass {
        switch self {
        case .serviceUuid, .serviceData, .manufacturerData, .oui, .macPrefix, .vendorIeOui:
            return .identifier
        case .nameContains, .nameGlob:
            return .name
        case .manufacturerId, .radioKind, .hiddenSsid:
            return .weak
        }
    }

    /// What a match on this rule kind establishes on its own.
    public var confidence: Confidence {
        switch evidenceClass {
        case .identifier: return .certain
        case .name: return .probable
        case .weak: return .possible
        }
    }

    /// Whether a match on this kind identifies a product without help.
    public var isIdentifying: Bool { evidenceClass == .identifier }
}

extension MatchRule {
    /// The rule's own pattern, rendered for display.
    public var pattern: String {
        switch kind {
        case .manufacturerId:
            return String(format: "0x%04X (%d)", companyId, companyId)
        case .manufacturerData:
            return dataPrefixHex.isEmpty
                ? "company \(companyId)"
                : "company \(companyId), payload \(dataPrefixHex)"
        case .serviceData:
            let service = text.isEmpty ? "any service" : text
            return dataPrefixHex.isEmpty ? service : "\(service), payload \(dataPrefixHex)"
        case .radioKind:
            return radio?.rawValue ?? "either radio"
        case .hiddenSsid:
            return "hidden network"
        default:
            return text
        }
    }

    /// What a match on this rule can and cannot establish, in one sentence.
    public var strengthNote: String {
        switch kind {
        case .manufacturerId:
            return "A Bluetooth company id identifies the vendor, and every product that vendor makes shares it."
        case .manufacturerData:
            return "A payload prefix is written by the device's own firmware, so it identifies the product."
        case .serviceUuid:
            return "A service UUID is assigned to a product or a protocol, and the device advertises it itself."
        case .serviceData:
            return "A service-data prefix comes from the device's own payload."
        case .nameContains:
            return "Matched on whole words only: \"DJI\" matches \"DJI Mavic\" but not \"KOQDJIH\"."
        case .nameGlob:
            return "A name pattern. Whoever owns the device can change its name."
        case .oui:
            return "An OUI identifies the manufacturer, from a real hardware address."
        case .macPrefix:
            return "A MAC prefix identifies the manufacturer, from a real hardware address."
        case .vendorIeOui:
            return "A vendor information element, written into the device's own beacon."
        case .radioKind:
            return "A radio type on its own does not identify anything."
        case .hiddenSsid:
            return "A hidden network on its own does not identify anything."
        }
    }
}

// MARK: - Text matching (mirrors Fieldwatch TextMatch)

public enum TextMatch {
    /// Whole-word contains: the needle must be bounded by non-alphanumeric characters on both
    /// sides. "DJI" matches "DJI Mavic 3" and "Mavic (DJI)"; it does not match "KOQDJIH".
    ///
    /// Deliberate divergence from Fieldwatch, whose NAME_CONTAINS is a bare substring — the
    /// reason a Windows host named DESKTOP-KOQDJIH was reported as a drone. A glob keeps its
    /// substring meaning, because `*DJI*` states that intent explicitly.
    public static func containsWord(_ hay: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !hay.isEmpty else { return false }
        var search = hay.startIndex..<hay.endIndex
        while let found = hay.range(of: needle, options: [.caseInsensitive], range: search) {
            let before = found.lowerBound == hay.startIndex ? nil : hay[hay.index(before: found.lowerBound)]
            let after = found.upperBound == hay.endIndex ? nil : hay[found.upperBound]
            let leftOK = before.map { !isWordCharacter($0) } ?? true
            let rightOK = after.map { !isWordCharacter($0) } ?? true
            if leftOK && rightOK { return true }
            guard found.lowerBound < hay.endIndex else { break }
            search = hay.index(after: found.lowerBound)..<hay.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    public static func glob(_ text: String, _ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        var body = "^"
        for ch in pattern {
            switch ch {
            case "*": body += ".*"
            case "?": body += "."
            default: body += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        body += "$"
        return text.range(of: body, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func hexOnly(_ s: String) -> String {
        s.uppercased().filter { $0.isHexDigit }
    }
}

/// UUID normalisation: a 16-bit alias and its Bluetooth base form must compare equal.
public enum UUIDAlias {
    public static let base = "00001000800000805F9B34FB"

    public static func aliases(_ raw: String) -> Set<String> {
        let hex = TextMatch.hexOnly(raw)
        var out: Set<String> = []
        guard !hex.isEmpty else { return out }
        out.insert(hex)
        if hex.count == 4 {
            out.insert("0000" + hex + base)
        } else if hex.count == 32, hex.hasPrefix("0000"), hex.hasSuffix(base) {
            let start = hex.index(hex.startIndex, offsetBy: 4)
            let end = hex.index(hex.endIndex, offsetBy: -base.count)
            out.insert(String(hex[start..<end]))
        }
        return out
    }
}
