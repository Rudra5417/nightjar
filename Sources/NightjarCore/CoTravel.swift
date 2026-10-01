import Foundation
import CoreLocation

public struct CoTravelSighting {
    public let key: String
    public let coordinate: CLLocationCoordinate2D
    public let at: Date
    public let rssi: Int

    public init(key: String, coordinate: CLLocationCoordinate2D, at: Date, rssi: Int) {
        self.key = key
        self.coordinate = coordinate
        self.at = at
        self.rssi = rssi
    }
}

public struct CoTravelVerdict: Equatable {
    public let key: String
    public let places: Int
    public let sightings: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let bestRssi: Int

    public var span: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
    public var isFollowing: Bool

    public var spanLabel: String {
        let minutes = Int(span / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// Decides whether something is travelling with you.
///
/// The rule is about places, not signal strength. A device heard at one place is a neighbour, a
/// router or a fixed camera, which is most of what any scan picks up. Three or more distinct
/// places, spread over at least `minimumSpan`, and still being heard within `freshness`, counts
/// as travelling with you.
///
/// Limitation: iOS exposes a per-app UUID rather than a MAC, so a device that rotates its address
/// can appear as two identities. This can under-count a follower; it cannot invent one.
public final class CoTravelEngine {

    /// Sightings closer together than this count as the same place, so walking around one
    /// building does not read as three.
    public let placeRadiusMeters: Double
    public let minimumPlaces: Int
    public let minimumSpan: TimeInterval
    /// How recently it must have been heard to count as "still with you".
    public let freshness: TimeInterval

    private struct Place {
        var center: CLLocationCoordinate2D
        var sightings: Int
        var first: Date
        var last: Date
    }

    private struct Track {
        var places: [Place] = []
        var sightings = 0
        var firstSeen = Date.distantFuture
        var lastSeen = Date.distantPast
        var bestRssi = Int.min
    }

    private var tracks: [String: Track] = [:]

    public init(placeRadiusMeters: Double = 60,
                minimumPlaces: Int = 3,
                minimumSpan: TimeInterval = 5 * 60,
                freshness: TimeInterval = 15 * 60) {
        self.placeRadiusMeters = placeRadiusMeters
        self.minimumPlaces = minimumPlaces
        self.minimumSpan = minimumSpan
        self.freshness = freshness
    }

    public func observe(_ sighting: CoTravelSighting) {
        var track = tracks[sighting.key] ?? Track()
        track.sightings += 1
        track.firstSeen = min(track.firstSeen, sighting.at)
        track.lastSeen = max(track.lastSeen, sighting.at)
        if sighting.rssi <= 0 { track.bestRssi = max(track.bestRssi, sighting.rssi) }

        if let index = nearestPlace(to: sighting.coordinate, in: track.places) {
            track.places[index].sightings += 1
            track.places[index].last = max(track.places[index].last, sighting.at)
            track.places[index].first = min(track.places[index].first, sighting.at)
        } else {
            track.places.append(Place(center: sighting.coordinate, sightings: 1,
                                      first: sighting.at, last: sighting.at))
        }
        tracks[sighting.key] = track
    }

    public func verdict(for key: String, now: Date = Date()) -> CoTravelVerdict? {
        guard let track = tracks[key], track.sightings > 0 else { return nil }
        let stillAround = now.timeIntervalSince(track.lastSeen) <= freshness
        let verdict = CoTravelVerdict(
            key: key,
            places: track.places.count,
            sightings: track.sightings,
            firstSeen: track.firstSeen,
            lastSeen: track.lastSeen,
            bestRssi: track.bestRssi == Int.min ? Observation.unknownRssi : track.bestRssi,
            isFollowing: track.places.count >= minimumPlaces
                && track.lastSeen.timeIntervalSince(track.firstSeen) >= minimumSpan
                && stillAround)
        return verdict
    }

    /// Everything currently judged to be travelling with you, strongest evidence first.
    public func followers(now: Date = Date()) -> [CoTravelVerdict] {
        tracks.keys.compactMap { verdict(for: $0, now: now) }
            .filter(\.isFollowing)
            .sorted { ($0.places, $0.sightings) > ($1.places, $1.sightings) }
    }

    /// Devices with enough history to judge, following or not.
    public func judged(now: Date = Date()) -> [CoTravelVerdict] {
        tracks.keys.compactMap { verdict(for: $0, now: now) }
            .sorted { $0.places > $1.places }
    }

    public func reset() { tracks.removeAll() }

    private func nearestPlace(to coordinate: CLLocationCoordinate2D, in places: [Place]) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, place) in places.enumerated() {
            let distance = CLLocation(latitude: place.center.latitude, longitude: place.center.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard distance <= placeRadiusMeters else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }
}
