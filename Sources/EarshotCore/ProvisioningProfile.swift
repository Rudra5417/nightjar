import Foundation

/// The 7-day clock a free Apple ID puts on a sideloaded build.
///
/// A development-signed app carries `embedded.mobileprovision` at the root of its bundle.
/// That file is a CMS (DER) envelope with the actual plist sitting in the middle of it, so
/// the payload is recovered by slicing between the XML header and `</plist>` rather than by
/// pulling in a CMS library. Once parsed, the app knows exactly when it will stop opening
/// and can warn its owner before that happens.
public struct ProvisioningProfile: Equatable {

    public let name: String?
    public let teamIdentifier: String?
    public let applicationIdentifier: String?
    public let creationDate: Date?
    public let expirationDate: Date

    public init(name: String?, teamIdentifier: String?, applicationIdentifier: String?,
                creationDate: Date?, expirationDate: Date) {
        self.name = name
        self.teamIdentifier = teamIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.creationDate = creationDate
        self.expirationDate = expirationDate
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expirationDate }

    public func timeRemaining(at now: Date = Date()) -> TimeInterval {
        max(0, expirationDate.timeIntervalSince(now))
    }

    /// "6d 4h" — short enough for a status pill.
    public func remainingLabel(at now: Date = Date()) -> String {
        guard !isExpired(at: now) else { return "expired" }
        let total = Int(timeRemaining(at: now))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = (total % 3_600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - parsing

    /// Recover the plist payload from the CMS envelope (or from a bare plist).
    public static func parse(cmsData data: Data) -> ProvisioningProfile? {
        guard let plistData = extractPlist(from: data) else { return nil }
        guard let object = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil) as? [String: Any] else { return nil }
        guard let expiration = object["ExpirationDate"] as? Date else { return nil }

        let entitlements = object["Entitlements"] as? [String: Any]
        let team = (object["TeamIdentifier"] as? [String])?.first
        return ProvisioningProfile(
            name: object["Name"] as? String,
            teamIdentifier: team,
            applicationIdentifier: entitlements?["application-identifier"] as? String,
            creationDate: object["CreationDate"] as? Date,
            expirationDate: expiration)
    }

    /// `embedded.mobileprovision` inside the app's own bundle. Absent on simulator builds and
    /// on anything installed from the App Store, which is exactly when there is no 7-day clock
    /// to warn about — so nil is a normal answer, not an error.
    public static func load(from bundle: Bundle = .main) -> ProvisioningProfile? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(cmsData: data)
    }

    static func extractPlist(from data: Data) -> Data? {
        // Bare plist (already the payload).
        if data.starts(with: Array("<?xml".utf8)) { return data }

        let open = Array("<?xml".utf8)
        let close = Array("</plist>".utf8)
        guard let start = data.range(of: Data(open))?.lowerBound,
              let end = data.range(of: Data(close), in: start..<data.endIndex)?.upperBound
        else { return nil }
        return data.subdata(in: start..<end)
    }
}
