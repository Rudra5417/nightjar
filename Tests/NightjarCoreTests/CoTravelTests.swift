import XCTest
import CoreLocation
@testable import NightjarCore

/// The rule that decides something is travelling with you. The failure that matters is a false
/// alarm — "something is following you" has to mean it — so most of these tests are about
/// devices that must *not* be flagged.
final class CoTravelTests: XCTestCase {

    private let home = CLLocationCoordinate2D(latitude: 10.00000, longitude: 20.00000)
    /// ~1.5 km away, comfortably outside the 60 m place radius.
    private let cafe = CLLocationCoordinate2D(latitude: 10.01351, longitude: 20.00000)
    private let store = CLLocationCoordinate2D(latitude: 10.02702, longitude: 20.00000)

    private func at(_ minutes: Double) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
    }

    private func engine() -> CoTravelEngine {
        CoTravelEngine(placeRadiusMeters: 60, minimumPlaces: 3,
                       minimumSpan: 5 * 60, freshness: 15 * 60)
    }

    func testOnePlaceIsNotFollowing() {
        let e = engine()
        for minute in stride(from: 0.0, through: 40, by: 2) {
            e.observe(.init(key: "tv", coordinate: home, at: at(minute), rssi: -70))
        }
        let verdict = try! XCTUnwrap(e.verdict(for: "tv", now: at(41)))
        XCTAssertEqual(verdict.places, 1)
        XCTAssertFalse(verdict.isFollowing, "a neighbour's television is heard in one place")
        XCTAssertTrue(e.followers(now: at(41)).isEmpty)
    }

    func testThreePlacesOverTimeIsFollowing() {
        let e = engine()
        e.observe(.init(key: "tag", coordinate: home, at: at(0), rssi: -70))
        e.observe(.init(key: "tag", coordinate: cafe, at: at(12), rssi: -68))
        e.observe(.init(key: "tag", coordinate: store, at: at(24), rssi: -72))

        let verdict = try! XCTUnwrap(e.verdict(for: "tag", now: at(25)))
        XCTAssertEqual(verdict.places, 3)
        XCTAssertTrue(verdict.isFollowing)
        XCTAssertEqual(e.followers(now: at(25)).map(\.key), ["tag"])
    }

    /// Three places inside one minute is a device the scan saw from a car window, not something
    /// that spent an hour with you. The span requirement keeps that out.
    func testThreePlacesTooQuicklyIsNotFollowing() {
        let e = engine()
        e.observe(.init(key: "blip", coordinate: home, at: at(0), rssi: -80))
        e.observe(.init(key: "blip", coordinate: cafe, at: at(0.4), rssi: -80))
        e.observe(.init(key: "blip", coordinate: store, at: at(0.8), rssi: -80))

        let verdict = try! XCTUnwrap(e.verdict(for: "blip", now: at(1)))
        XCTAssertEqual(verdict.places, 3)
        XCTAssertFalse(verdict.isFollowing, "three places in under a minute is not following")
    }

    /// Something heard an hour ago and never since is not with you now.
    func testStaleTrackStopsFollowing() {
        let e = engine()
        e.observe(.init(key: "tag", coordinate: home, at: at(0), rssi: -70))
        e.observe(.init(key: "tag", coordinate: cafe, at: at(12), rssi: -68))
        e.observe(.init(key: "tag", coordinate: store, at: at(24), rssi: -72))

        XCTAssertTrue(try! XCTUnwrap(e.verdict(for: "tag", now: at(25))).isFollowing)
        XCTAssertFalse(try! XCTUnwrap(e.verdict(for: "tag", now: at(90))).isFollowing,
                       "last heard 66 minutes ago — it stayed behind")
    }

    /// Walking around one building is one place, not four.
    func testNearbySightingsClusterToOnePlace() {
        let e = engine()
        // ~20 m apart each step, all within the 60 m radius of the first.
        for (index, metres) in [0.0, 20.0, 40.0, 55.0].enumerated() {
            let coordinate = CLLocationCoordinate2D(
                latitude: home.latitude + metres / 111_000.0,
                longitude: home.longitude)
            e.observe(.init(key: "walker", coordinate: coordinate, at: at(Double(index) * 3), rssi: -65))
        }
        let verdict = try! XCTUnwrap(e.verdict(for: "walker", now: at(12)))
        XCTAssertEqual(verdict.places, 1, "pacing around one spot is still one place")
        XCTAssertFalse(verdict.isFollowing)
    }

    func testTwoPlacesIsNotEnough() {
        let e = engine()
        e.observe(.init(key: "tag", coordinate: home, at: at(0), rssi: -70))
        e.observe(.init(key: "tag", coordinate: cafe, at: at(20), rssi: -70))
        XCTAssertFalse(try! XCTUnwrap(e.verdict(for: "tag", now: at(21))).isFollowing)
    }

    func testUnknownKeyHasNoVerdict() {
        XCTAssertNil(engine().verdict(for: "never-seen"))
    }

    func testFollowersAreRankedByEvidence() {
        let e = engine()
        let stops = [home, cafe, store]
        for (index, minute) in [0.0, 10, 20].enumerated() {
            e.observe(.init(key: "weak", coordinate: stops[index], at: at(minute), rssi: -70))
        }
        // Same three places, heard far more often, still nearby — stronger evidence.
        for (index, minute) in [0.0, 10, 20, 22, 24, 26, 28, 30].enumerated() {
            e.observe(.init(key: "strong", coordinate: stops[index % stops.count], at: at(minute), rssi: -70))
        }
        let followers = e.followers(now: at(32))
        XCTAssertEqual(Set(followers.map(\.key)), ["weak", "strong"])
        XCTAssertEqual(followers.first?.key, "strong", "more sightings, same places, ranks first")
    }

    func testSpanLabelReadsLikeAClaim() {
        let e = engine()
        e.observe(.init(key: "tag", coordinate: home, at: at(0), rssi: -70))
        e.observe(.init(key: "tag", coordinate: cafe, at: at(22), rssi: -70))
        e.observe(.init(key: "tag", coordinate: store, at: at(22), rssi: -70))
        XCTAssertEqual(try! XCTUnwrap(e.verdict(for: "tag", now: at(23))).spanLabel, "22 min")
    }

    func testResetForgetsEverything() {
        let e = engine()
        e.observe(.init(key: "tag", coordinate: home, at: at(0), rssi: -70))
        e.reset()
        XCTAssertNil(e.verdict(for: "tag", now: at(1)))
    }
}
