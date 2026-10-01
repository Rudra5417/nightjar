import XCTest
import CoreLocation
@testable import NightjarCore

/// Reading a session log, and comparing two of them. The comparison is the part that has to stay
/// honest: it can measure what the node added, but it cannot claim the node confirmed what the
/// phone saw, because the two never share an identifier.
final class SessionTallyTests: XCTestCase {

    private func frame(_ t: String = "ble",
                       node: String = "phone",
                       addr: String = "aa:bb:cc:dd:ee:01",
                       name: String = "",
                       band: String? = nil,
                       lat: Double? = nil,
                       lon: Double? = nil,
                       signatures: [String] = [],
                       classes: [String] = [],
                       mode: String? = "phone") throws -> LoggedFrame {
        var json: [String: Any] = ["t": t, "node": node, "addr": addr, "name": name,
                                   "signatures": signatures, "classes": classes]
        if let band { json["band"] = band }
        if let lat { json["lat"] = lat }
        if let lon { json["lon"] = lon }
        if let mode { json["mode"] = mode }
        return try XCTUnwrap(LoggedFrame(json: json))
    }

    func testTallyCountsRadiosAndNamed() throws {
        let tally = SessionTally(frames: [
            try frame(addr: "aa:01", name: "AirPods Pro", signatures: ["Apple"], classes: ["Audio"]),
            try frame(addr: "aa:01", name: "AirPods Pro", signatures: ["Apple"], classes: ["Audio"]),
            try frame(addr: "aa:02", name: "Nest Thermostat", signatures: ["Nest"], classes: ["Thermostats"]),
            try frame(addr: "aa:03"),
        ])
        XCTAssertEqual(tally.frames, 4)
        XCTAssertEqual(tally.radios.count, 3)
        XCTAssertEqual(tally.named.count, 2, "one radio heard twice is one named radio")
        XCTAssertEqual(tally.fleets, ["Apple", "Nest"])
        XCTAssertEqual(tally.classes, ["Audio", "Thermostats"])
        XCTAssertEqual(tally.namedRatio, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testWifiAndBandsAreCountedSeparately() throws {
        let tally = SessionTally(frames: [
            try frame("ap", node: "node-1", addr: "de:ad:01", band: "2.4"),
            try frame("ap", node: "node-1", addr: "de:ad:02", band: "5"),
            try frame("ble", addr: "aa:01"),
        ])
        XCTAssertEqual(tally.wifi, 2)
        XCTAssertEqual(tally.ble, 1)
        XCTAssertEqual(tally.bands, ["2.4", "5"])
    }

    func testPlacesClusterLikeTheMap() throws {
        // Two spots ~1.5 km apart, several frames each.
        let tally = SessionTally(frames: [
            try frame(addr: "aa:01", lat: 10.00000, lon: 20.00000),
            try frame(addr: "aa:02", lat: 10.00004, lon: 20.00001),
            try frame(addr: "aa:03", lat: 10.01351, lon: 20.00000),
            try frame(addr: "aa:04", lat: 10.01352, lon: 20.00001),
        ])
        XCTAssertEqual(tally.geotagged, 4)
        XCTAssertEqual(tally.places, 2)
    }

    func testPerSourceBreakdown() throws {
        let tally = SessionTally(frames: [
            try frame(node: "phone", addr: "aa:01", signatures: ["Apple"]),
            try frame(node: "phone", addr: "aa:02"),
            try frame("ap", node: "node-1", addr: "de:ad:01", band: "5", signatures: ["Flock Safety"], classes: ["Surveillance"]),
            try frame("ap", node: "node-1", addr: "de:ad:02", band: "5"),
            try frame("ap", node: "node-1", addr: "de:ad:03", band: "2.4"),
        ])
        XCTAssertEqual(Set(tally.sources.keys), ["phone", "node-1"])
        XCTAssertEqual(tally.sources["phone"]?.radios.count, 2)
        XCTAssertEqual(tally.sources["phone"]?.named.count, 1)
        XCTAssertEqual(tally.sources["node-1"]?.radios.count, 3)
        XCTAssertEqual(tally.sources["node-1"]?.bands, ["2.4", "5"])
    }

    func testComparisonReportsWhatTheNodeAdded() throws {
        let phone = SessionTally(frames: [
            try frame(addr: "aa:01", name: "AirPods Pro", signatures: ["Apple"], classes: ["Audio"]),
            try frame(addr: "aa:02", name: "Nest Thermostat", signatures: ["Nest"], classes: ["Thermostats"]),
        ])
        let withNode = SessionTally(frames: [
            try frame(addr: "aa:01", name: "AirPods Pro", signatures: ["Apple"], classes: ["Audio"]),
            try frame(addr: "aa:02", name: "Nest Thermostat", signatures: ["Nest"], classes: ["Thermostats"]),
            try frame("ap", node: "node-1", addr: "de:ad:01", name: "Flock Safety FL-2", band: "5",
                      signatures: ["Flock Safety"], classes: ["Surveillance"]),
            try frame("ap", node: "node-1", addr: "de:ad:02", name: "Axis Q3538", band: "5",
                      signatures: ["Axis"], classes: ["Cameras"]),
        ])
        let diff = SessionComparison(before: phone, after: withNode)
        XCTAssertEqual(diff.radioDelta, 2)
        XCTAssertEqual(diff.namedDelta, 2)
        XCTAssertEqual(diff.newNames, ["axis q3538", "flock safety fl-2"])
        XCTAssertEqual(diff.newFleets, ["Axis", "Flock Safety"])
        XCTAssertEqual(diff.newClasses, ["Cameras", "Surveillance"])
        XCTAssertEqual(diff.newBands, ["5"])
        XCTAssertTrue(diff.verdict.contains("added 2 named radios"), diff.verdict)
    }

    /// The honest limit, encoded as a test: the same device heard by both sources shares no
    /// identifier, so it is not "confirmed" — only its name lines up, and only sometimes.
    func testSharedNameIsNotCountedAsNew() throws {
        let phone = SessionTally(frames: [try frame(addr: "ios-uuid-1", name: "DJI Mavic 3")])
        let withNode = SessionTally(frames: [
            try frame(node: "node-1", addr: "60:60:1f:aa:bb:cc", name: "DJI Mavic 3"),
        ])
        let diff = SessionComparison(before: phone, after: withNode)
        XCTAssertTrue(diff.newNames.isEmpty, "same name, different identity — not new")
        // And the limit this encodes: the two sources hold two identities for one device, so the
        // counts cannot be added up. The union is 2; the truth is 1.
        XCTAssertEqual(diff.radioDelta, 0, "each session counted one radio")
        XCTAssertEqual(phone.radios.union(withNode.radios).count, 2,
                       "one physical device, two identities — never sum these")
    }

    func testVerdictSaysSoWhenTheNodeAddedNothingNameable() throws {
        let phone = SessionTally(frames: [try frame(addr: "aa:01", signatures: ["Apple"])])
        let withNode = SessionTally(frames: [try frame(addr: "aa:01", signatures: ["Apple"])])
        let diff = SessionComparison(before: phone, after: withNode)
        XCTAssertEqual(diff.verdict, "no change in named radios — the node added nothing you could name")
    }

    func testVerdictFlagsARegression() throws {
        let phone = SessionTally(frames: [
            try frame(addr: "aa:01", signatures: ["Apple"]),
            try frame(addr: "aa:02", signatures: ["Nest"]),
        ])
        let withNode = SessionTally(frames: [try frame(addr: "aa:01", signatures: ["Apple"])])
        let diff = SessionComparison(before: phone, after: withNode)
        XCTAssertTrue(diff.verdict.contains("investigate"), diff.verdict)
    }

    func testHeaderAndModeLinesAreNotFrames() {
        XCTAssertNil(LoggedFrame(json: ["t": "session", "name": "sit-1", "mode": "phone"]))
        XCTAssertNil(LoggedFrame(json: ["t": "mode", "mode": "node"]))
    }

    func testReaderSurvivesATruncatedFinalLine() {
        let text = """
        {"t":"session","name":"sit-1","mode":"phone"}
        {"t":"ble","node":"phone","addr":"aa:01","name":"AirPods","signatures":["Apple"],"classes":["Audio"]}
        {"t":"ble","node":"phone","addr":"aa:02","na
        """
        let frames = SessionLogReader.frames(inText: text)
        XCTAssertEqual(frames.count, 1, "a log pulled mid-write loses its last line, not the session")
    }

    func testModeIsCarriedThrough() throws {
        let tally = SessionTally(frames: [
            try frame(addr: "aa:01", mode: "phone"),
            try frame(addr: "aa:02", mode: "node"),
        ])
        XCTAssertEqual(tally.modeLabel, "node+phone")
    }
}
