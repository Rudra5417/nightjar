import XCTest
@testable import EarshotCore

final class EngineTests: XCTestCase {
    static var engine: SignatureEngine!

    override class func setUp() {
        super.setUp()
        let path = ProcessInfo.processInfo.environment["FIELDWATCH_CATALOG"]
            ?? "\(NSHomeDirectory())/.hermes/cache/scratch/fw/Fieldwatch/dist/fieldwatch-signatures-v2.json"
        guard FileManager.default.fileExists(atPath: path),
              let loaded = try? SignatureEngine.load(url: URL(fileURLWithPath: path)) else {
            return
        }
        engine = loaded
    }

    private func requireEngine() throws -> SignatureEngine {
        try XCTSkipIf(Self.engine == nil, "stock catalog pack not available")
        return Self.engine
    }

    private func names(_ hits: [FleetHit]) -> Set<String> { Set(hits.map { $0.fleet.name }) }

    func testAirTagMatchesWithoutAnyHardwareAddress() throws {
        let engine = try requireEngine()
        let obs = Observation(kind: .ble, name: "AirTag", serviceUuids: ["FD44"],
                              manufacturerId: 0x004C, manufacturerDataHex: "121A00")
        XCTAssertTrue(names(engine.match(obs)).contains("Apple AirTags"))
    }

    func test16BitUuidAliasMatchesFullBluetoothBaseUuid() throws {
        let engine = try requireEngine()
        // Catalog rule says FD44; iOS hands back the full 128-bit form.
        let obs = Observation(kind: .ble, name: "",
                              serviceUuids: ["0000FD44-0000-1000-8000-00805F9B34FB"])
        XCTAssertTrue(names(engine.match(obs)).contains("Apple AirTags"))
    }

    func testAxonMatchesOnNameAlone() throws {
        let engine = try requireEngine()
        let obs = Observation(kind: .ble, name: "Axon Body 4")
        XCTAssertTrue(names(engine.match(obs)).contains("Axon"))
    }

    func testRemoteIdFrameMatchesAndDecodesUasId() throws {
        let engine = try requireEngine()
        var bytes: [UInt8] = [0x0D, 0x00, 0x00, 0x12]
        bytes += Array("1596F3A1B2C3D4E5F607".utf8)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let obs = Observation(kind: .ble, serviceData: [ServiceDataRecord(uuid: "FFFA", hex: hex)])
        let hits = engine.match(obs)
        guard let remoteId = hits.first(where: { $0.fleet.name == "Remote ID" }) else {
            return XCTFail("Remote ID not matched; got \(names(hits))")
        }
        XCTAssertFalse(remoteId.decoded.isEmpty, "decode spec should produce fields")
    }

    func testDultSeparatedModeDecodes() throws {
        let engine = try requireEngine()
        let obs = Observation(kind: .ble, serviceData: [ServiceDataRecord(uuid: "FCB2", hex: "4A00")])
        let hits = engine.match(obs)
        guard let dult = hits.first(where: { $0.fleet.name == "DULT tracker" }) else {
            return XCTFail("DULT not matched; got \(names(hits))")
        }
        let mode = dult.decoded.first { $0.id == "mode" }
        XCTAssertEqual(mode?.value.hasPrefix("0"), true, "mode byte 0x00 must read as separated")
    }

    func testOuiRuleCannotFireWithoutMac() throws {
        let engine = try requireEngine()
        let bleNoMac = Observation(kind: .ble, name: "", manufacturerId: 0x004C)
        let wifiWithMac = Observation(kind: .wifi, mac: "B4:1E:52:11:22:33", name: "")
        let bleHits = names(engine.match(bleNoMac))
        let wifiHits = names(engine.match(wifiWithMac))
        XCTAssertTrue(wifiHits.contains("Flock Safety Cameras"), "OUI path works when a MAC exists")
        XCTAssertFalse(bleHits.contains("Flock Safety Cameras"), "OUI path must not fire on a MAC-less iOS BLE frame")
    }

    func testGlobRuleIsAnchoredAndCaseInsensitive() throws {
        let engine = try requireEngine()
        // Test the glob rule in isolation: an unanchored NAME_CONTAINS rule in the
        // stock pack would legitimately match a name that merely embeds the token.
        let globFleet = Fleet(
            id: "test-glob",
            name: "test glob",
            enabled: true,
            matchAny: true,
            kind: nil,
            notes: nil,
            attentionNote: nil,
            builtIn: nil,
            rules: [MatchRule(kind: .nameGlob, text: "Flock-*")],
            decode: nil
        )
        XCTAssertTrue(engine.fleetMatches(globFleet, Observation(kind: .ble, name: "flock-4c21ab")))
        XCTAssertFalse(engine.fleetMatches(globFleet, Observation(kind: .ble, name: "x-flock-4c21ab")))
        // ...and the pack's own contains rule is unanchored, which is the original behaviour.
        XCTAssertTrue(names(engine.match(Observation(kind: .ble, name: "x-flock-4c21ab"))).contains("Flock Safety Cameras"))
    }

    func testPortabilityReportIsComputedFromThePack() throws {
        let engine = try requireEngine()
        let report = engine.portabilityReport()
        XCTAssertGreaterThan(report.totalRules, 6000)
        XCTAssertGreaterThan(report.iosUsableRules, 400)
        XCTAssertLessThan(report.usablePercent, 20, "the OUI bulk cannot survive on iOS")
        XCTAssertEqual(report.totalRules, report.iosUsableRules + report.deadRules)
    }

    // MARK: - sensor node path

    func testNodeSessionSurvivesSplitBleWrites() throws {
        let line = "{\"t\":\"ap\",\"node\":\"N1\",\"bssid\":\"B4:1E:52:11:22:33\",\"ssid\":\"Flock-1\",\"rssi\":-61,\"ch\":6,\"band\":\"2.4\"}\n"
        var decoder = NodeFrameDecoder()
        XCTAssertTrue(decoder.feed(String(line.prefix(30))).isEmpty, "half a frame must not emit")
        let frames = decoder.feed(String(line.dropFirst(30)))
        XCTAssertEqual(frames.count, 1, "the two halves must join into one frame")
        guard case .ap(let obs) = frames[0] else { return XCTFail("expected an ap frame") }
        XCTAssertEqual(obs.mac, "B4:1E:52:11:22:33")
        XCTAssertEqual(obs.channel, 6)
        XCTAssertEqual(obs.band, "2.4")
    }

    func testDecoderHandlesBatchedFramesAndSkipsGarbage() throws {
        let two = "{\"t\":\"scan\",\"phase\":\"wifi\",\"ms\":812,\"aps\":7}\n"
            + "{\"t\":\"log\",\"msg\":\"wifi phase start\"}\n"
        var decoder = NodeFrameDecoder()
        let frames = decoder.feed(two)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(decoder.feed("not json at all\n").count, 0, "junk lines are dropped, not fatal")
    }

    func testAccessPointFromNodeMatchesOuiRuleTheePhoneCannotSee() throws {
        let engine = try requireEngine()
        let json = "{\"t\":\"ap\",\"node\":\"N1\",\"bssid\":\"B4:1E:52:AA:BB:CC\",\"ssid\":\"\",\"rssi\":-61,\"ch\":6,\"band\":\"2.4\",\"hidden\":true}\n"
        var decoder = NodeFrameDecoder()
        let frames = decoder.feed(json)
        guard case .ap(let obs) = frames[0] else { return XCTFail("expected ap") }
        XCTAssertTrue(names(engine.match(obs)).contains("Flock Safety Cameras"))
        XCTAssertTrue(obs.hasUsableHardwareAddress)
    }

    func testRandomizedBleAddressIsNotTreatedAsAnOui() throws {
        let engine = try requireEngine()
        let json = "{\"t\":\"ble\",\"node\":\"N1\",\"addr\":\"B4:1E:52:AA:BB:CC\",\"addr_type\":\"random\",\"rssi\":-70}\n"
        var decoder = NodeFrameDecoder()
        guard case .ble(let obs) = decoder.feed(json)[0] else { return XCTFail("expected ble") }
        XCTAssertFalse(obs.hasUsableHardwareAddress, "random addresses must not be OUI-matched")
    }

    func testNodeCoverageClosesTheWholeGap() throws {
        let engine = try requireEngine()
        let cov = engine.coverageComparison()
        XCTAssertEqual(cov.withNode.iosUsableRules, cov.withNode.totalRules)
        XCTAssertEqual(cov.withNode.fleetsWithUsableRule, cov.withNode.fleetsTotal)
        XCTAssertEqual(cov.nodeRestoredRules, cov.phoneOnly.deadRules)
        XCTAssertEqual(cov.nodeRestoredFleets.count, cov.phoneOnly.fleetsLostEntirely.count)
    }
}
