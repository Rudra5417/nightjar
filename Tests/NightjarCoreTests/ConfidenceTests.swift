import XCTest
@testable import NightjarCore

/// The stock catalog reported two confidently wrong things on a real walk: a Windows host named
/// `DESKTOP-KOQDJIH` as a DJI drone, and a Samsung television as a SmartTag. Both frames are here,
/// together with the true positives the fix must not cost.
final class ConfidenceTests: XCTestCase {

    private static var engine: SignatureEngine!

    override class func setUp() {
        super.setUp()
        engine = TestCatalog.load()
    }

    private func requireEngine() throws -> SignatureEngine {
        try XCTSkipIf(Self.engine == nil, "stock catalog pack not available")
        return Self.engine
    }

    private func hit(_ hits: [FleetHit], _ fleet: String) -> FleetHit? {
        hits.first { $0.fleet.name == fleet }
    }

    // MARK: - Whole-word name matching

    func testWholeWordContains() {
        // A word boundary is a non-alphanumeric character or the end of the string.
        XCTAssertTrue(TextMatch.containsWord("DJI Mavic 3", "DJI"))
        XCTAssertTrue(TextMatch.containsWord("Mavic (DJI)", "DJI"))
        XCTAssertTrue(TextMatch.containsWord("Flock-4c21ab", "Flock"))
        XCTAssertTrue(TextMatch.containsWord("AirTag", "AirTag"))
        XCTAssertTrue(TextMatch.containsWord("galaxy smart tag 2", "Smart Tag"))

        // The two failures this exists to prevent, and the trade-off it accepts.
        XCTAssertFalse(TextMatch.containsWord("KOQDJIH", "DJI"), "a substring inside a word is not the word")
        XCTAssertFalse(TextMatch.containsWord("DESKTOP-KOQDJIH", "DJI"))
        XCTAssertFalse(TextMatch.containsWord("NestWifi", "Nest"), "a name glued to another is not matched")
        XCTAssertFalse(TextMatch.containsWord("", "DJI"))
    }

    func testWindowsHostnameIsNotReportedAsADrone() throws {
        let engine = try requireEngine()
        let host = Observation(kind: .ble, name: "DESKTOP-KOQDJIH", rssi: -77)
        XCTAssertNil(hit(engine.match(host), "DJI"), "a PC called DESKTOP-KOQDJIH is not a drone")
    }

    func testDroneNameStillMatches() throws {
        let engine = try requireEngine()
        let drone = Observation(kind: .ble, name: "DJI Mavic 3", rssi: -60)
        let dji = hit(engine.match(drone), "DJI")
        XCTAssertNotNil(dji, "a real DJI name must still match")
        XCTAssertEqual(dji?.confidence, .probable)
    }

    // MARK: - Weak rules stay weak

    func testDroneCompanyIdAloneIsOnlyPossible() throws {
        let engine = try requireEngine()
        // 2218 = 0x08AA, DJI's Bluetooth company id, with no name and no payload.
        let bare = Observation(kind: .ble, manufacturerId: 2218, rssi: -70)
        let dji = hit(engine.match(bare), "DJI")
        XCTAssertEqual(dji?.confidence, .possible,
                       "a company id identifies the vendor, not the product")
    }

    func testTelevisionIsReportedAsATrackerOnlyAsPossible() throws {
        let engine = try requireEngine()
        // The real frame: a 55" QLED advertising Samsung's company id, which is also the only rule
        // the SmartTag fleet has that this television can satisfy.
        let tv = Observation(kind: .ble, name: "55\" QLED", manufacturerId: 117, rssi: -92)
        let smartTag = hit(engine.match(tv), "Samsung SmartTags")
        XCTAssertEqual(smartTag?.confidence, .possible,
                       "a television must never be claimed as a tracker")
        XCTAssertEqual(smartTag?.confidence, .possible)
    }

    func testSmartTagServiceUuidIsIdentified() throws {
        let engine = try requireEngine()
        // FD5A is the service the tag itself advertises.
        let tag = Observation(kind: .ble, name: "Galaxy SmartTag 2", serviceUuids: ["FD5A"], rssi: -80)
        XCTAssertEqual(hit(engine.match(tag), "Samsung SmartTags")?.confidence, .certain)
    }

    func testTwoNameRulesAreNotCorroboration() throws {
        let engine = try requireEngine()
        // The Axon fleet matches a name by both NAME_CONTAINS and NAME_GLOB. That is one piece of
        // evidence stated twice, so it must not read as two independent kinds agreeing.
        let body = Observation(kind: .ble, name: "Axon Body 4", rssi: -65)
        let axon = hit(engine.match(body), "Axon")
        XCTAssertEqual(axon?.confidence, .probable)
        XCTAssertEqual(Set((axon?.matchedRules ?? []).map { $0.kind.evidenceClass }).count, 1)
    }

    // MARK: - Tier logic

    func testTierLogic() {
        XCTAssertEqual(SignatureEngine.confidence([]), .possible, "nothing matched")
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .manufacturerId, companyId: 117)]),
                       .possible)
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .radioKind, radio: .ble)]),
                       .possible, "a radio type on its own identifies nothing")
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .nameContains, text: "DJI")]),
                       .probable)
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .serviceUuid, text: "FD5A")]),
                       .certain)
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .nameContains, text: "SmartTag"),
                                                   MatchRule(kind: .manufacturerId, companyId: 117)]),
                       .probable, "a name and a vendor id corroborate, but do not identify")
        XCTAssertEqual(SignatureEngine.confidence([MatchRule(kind: .serviceUuid, text: "FD5A"),
                                                   MatchRule(kind: .manufacturerId, companyId: 117)]),
                       .certain)
    }

    func testTiersAreOrderedAndLabelled() {
        XCTAssertLessThan(Confidence.possible, Confidence.probable)
        XCTAssertLessThan(Confidence.probable, Confidence.certain)
        XCTAssertEqual(Confidence.possible.label, "possible")
        XCTAssertEqual(Confidence.probable.label, "likely")
        XCTAssertEqual(Confidence.certain.label, "identified")
        XCTAssertFalse(Confidence.possible.claim.isEmpty)
    }

    func testEveryRuleKindDeclaresItsEvidenceClass() {
        // Exhaustive by construction: a new RuleKind cannot compile without a class here.
        for kind in [RuleKind.oui, .macPrefix, .nameContains, .nameGlob, .serviceUuid, .serviceData,
                     .manufacturerId, .manufacturerData, .radioKind, .hiddenSsid, .vendorIeOui] {
            _ = kind.evidenceClass
            _ = MatchRule(kind: kind, text: "x", companyId: 1).pattern
            XCTAssertFalse(MatchRule(kind: kind, text: "x", companyId: 1).strengthNote.isEmpty,
                           "\(kind.rawValue) must explain what it can establish")
        }
    }
}
