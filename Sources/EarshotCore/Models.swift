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
}

public struct DecodedField: Sendable {
    public var id: String
    public var label: String
    public var value: String
    public var note: String?
    public var emphasized: Bool
}

// MARK: - Text matching (mirrors Fieldwatch TextMatch)

public enum TextMatch {
    public static func contains(_ hay: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return hay.range(of: needle, options: [.caseInsensitive]) != nil
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
