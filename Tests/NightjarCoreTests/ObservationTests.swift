import XCTest
@testable import NightjarCore

/// CoreBluetooth returns 127 when it has no reading for a peripheral. It is a sentinel, not a
/// measurement, and must not be sorted as one.
final class ObservationTests: XCTestCase {

    func testUnknownRssiIsNotTreatedAsAMeasurement() {
        let unknown = Observation(kind: .ble, name: "x", rssi: Observation.unknownRssi)
        XCTAssertFalse(unknown.rssiIsKnown)
        XCTAssertEqual(unknown.sortableRssi, -999)

        let real = Observation(kind: .ble, name: "y", rssi: -72)
        XCTAssertTrue(real.rssiIsKnown)
        XCTAssertEqual(real.sortableRssi, -72)

        // A real weak signal must outrank an unknown reading.
        XCTAssertGreaterThan(real.sortableRssi, unknown.sortableRssi)
    }

    func testSortableRssiOrdersRealSignalsByStrength() {
        let strong = Observation(kind: .ble, name: "a", rssi: -40)
        let weak = Observation(kind: .ble, name: "b", rssi: -95)
        let unknown = Observation(kind: .ble, name: "c", rssi: Observation.unknownRssi)
        let sorted = [unknown, weak, strong].sorted { $0.sortableRssi > $1.sortableRssi }
        XCTAssertEqual(sorted.map(\.name), ["a", "b", "c"])
    }

    func testPlatformIdIsNeverUsedForOuiMatching() {
        // iOS gives a per-app UUID, never a MAC. A UUID string must not be mistaken for one.
        let obs = Observation(kind: .ble, name: "", rssi: -60,
                              platformId: "B41E52AA-1111-2222-3333-444455556666")
        XCTAssertNil(obs.mac)
        XCTAssertFalse(obs.hasUsableHardwareAddress)
        XCTAssertTrue(obs.identityKey.contains("plat:"))
    }
}
