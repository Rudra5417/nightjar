import XCTest
import CoreLocation
@testable import NightjarCore

/// N devices at one coordinate is the normal case for a stationary scan, and renders as a single
/// dot indistinguishable from nothing.
final class PinSpreadTests: XCTestCase {

    /// Synthetic coordinates: fixtures are published, so they carry no real location.
    private let home = CLLocationCoordinate2D(latitude: 10.00000, longitude: 20.00000)

    func testSingleCoordinateIsLeftAlone() {
        let spread = PinSpread.spread([home])
        XCTAssertEqual(spread.count, 1)
        XCTAssertEqual(spread[0].latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(spread[0].longitude, home.longitude, accuracy: 1e-9)
    }

    func testStackedPinsAreSeparatedAndNoneAreLost() {
        let stacked = Array(repeating: home, count: 16)
        XCTAssertTrue(PinSpread.needsSpreading(stacked))

        let spread = PinSpread.spread(stacked)
        XCTAssertEqual(spread.count, 16, "no pin may be dropped")

        // Every pin must be distinguishable from every other one.
        for i in spread.indices {
            for j in spread.indices where j > i {
                XCTAssertGreaterThan(PinSpread.meters(spread[i], spread[j]), 1,
                                     "pins \(i) and \(j) still overlap")
            }
        }
        // ...and they must stay near where they came from, not fly off the map.
        for pin in spread {
            XCTAssertLessThan(PinSpread.meters(pin, home), 40, "fan drifted too far from the truth")
        }
    }

    func testDistantPinsAreNotTouched() {
        let far = CLLocationCoordinate2D(latitude: home.latitude + 0.01, longitude: home.longitude)
        let input = [home, far]
        XCTAssertFalse(PinSpread.needsSpreading(input))
        let spread = PinSpread.spread(input)
        XCTAssertEqual(spread[0].latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(spread[1].latitude, far.latitude, accuracy: 1e-9)
    }

    func testMixedGroupsOnlySpreadTheStackedOnes() {
        let far = CLLocationCoordinate2D(latitude: home.latitude + 0.01, longitude: home.longitude)
        let input = [home, home, far]
        let spread = PinSpread.spread(input)
        XCTAssertEqual(spread.count, 3)
        XCTAssertEqual(spread[2].latitude, far.latitude, accuracy: 1e-9, "the lone pin moved")
        XCTAssertGreaterThan(PinSpread.meters(spread[0], spread[1]), 1)
    }
}
