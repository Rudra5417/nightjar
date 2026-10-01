import XCTest
@testable import EarshotCore

final class ProvisioningProfileTests: XCTestCase {

    /// Build a plist payload the way Apple's provisioning profiles carry one.
    private func makePlist(expiration: Date, name: String = "iOS Team Provisioning Profile: *") -> Data {
        let object: [String: Any] = [
            "Name": name,
            "TeamIdentifier": ["ABCDE12345"],
            "CreationDate": expiration.addingTimeInterval(-7 * 24 * 3600),
            "ExpirationDate": expiration,
            "Entitlements": ["application-identifier": "ABCDE12345.com.rudrapatel.earshot"],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func testParsesExpirationFromCMSEnvelope() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let plist = makePlist(expiration: expiry)

        // A real .mobileprovision is a DER envelope with the plist in the middle.
        var blob = Data(repeating: 0x30, count: 512)
        blob.append(plist)
        blob.append(Data(repeating: 0x00, count: 256))

        let profile = try XCTUnwrap(ProvisioningProfile.parse(cmsData: blob))
        XCTAssertEqual(profile.expirationDate, expiry)
        XCTAssertEqual(profile.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(profile.applicationIdentifier, "ABCDE12345.com.rudrapatel.earshot")
        XCTAssertFalse(profile.isExpired(at: expiry.addingTimeInterval(-60)))
        XCTAssertTrue(profile.isExpired(at: expiry.addingTimeInterval(60)))
    }

    func testParsesBarePlist() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = try XCTUnwrap(ProvisioningProfile.parse(cmsData: makePlist(expiration: expiry)))
        XCTAssertEqual(profile.expirationDate, expiry)
    }

    func testGarbageAndMissingExpiryReturnNil() {
        XCTAssertNil(ProvisioningProfile.parse(cmsData: Data("not a profile".utf8)))
        XCTAssertNil(ProvisioningProfile.parse(cmsData: Data()))
        let noExpiry = try! PropertyListSerialization.data(
            fromPropertyList: ["Name": "x"], format: .xml, options: 0)
        XCTAssertNil(ProvisioningProfile.parse(cmsData: noExpiry))
    }

    func testRemainingLabelIsHumanReadable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sixDays = ProvisioningProfile(name: nil, teamIdentifier: nil,
                                          applicationIdentifier: nil, creationDate: nil,
                                          expirationDate: now.addingTimeInterval(6 * 86_400 + 4 * 3_600))
        XCTAssertEqual(sixDays.remainingLabel(at: now), "6d 4h")

        let minutes = ProvisioningProfile(name: nil, teamIdentifier: nil,
                                          applicationIdentifier: nil, creationDate: nil,
                                          expirationDate: now.addingTimeInterval(90 * 60))
        XCTAssertEqual(minutes.remainingLabel(at: now), "1h 30m")

        XCTAssertEqual(sixDays.remainingLabel(at: now.addingTimeInterval(7 * 86_400)), "expired")
    }

    /// Runs for real the moment this Mac has a profile from a signed build; skips until then.
    func testParsesARealProvisioningProfileWhenOneExists() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let file = profiles.first(where: { $0.pathExtension == "mobileprovision" }) else {
            throw XCTSkip("no provisioning profile on this machine yet")
        }
        let profile = try XCTUnwrap(ProvisioningProfile.parse(cmsData: try Data(contentsOf: file)))
        XCTAssertGreaterThan(profile.expirationDate, Date(timeIntervalSince1970: 1_600_000_000))
        print("real profile: \(file.lastPathComponent) expires \(profile.expirationDate)")
    }
}
