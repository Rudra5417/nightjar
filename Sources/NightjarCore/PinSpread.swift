import Foundation
import CoreLocation

/// Fans out markers that sit on top of each other so they can actually be seen.
///
/// This is a display convenience and nothing more: the adjusted coordinates are *not* where
/// anything was heard. Standing still puts every device you can hear at one point, and sixteen
/// markers drawn at one point look exactly like no markers at all. The caller is expected to say
/// so on screen — a map that silently moves pins is worse than a crowded one.
public enum PinSpread {

    /// Greedy grouping: any coordinate within `minSeparationMeters` of a member joins that group.
    /// Groups of one are left exactly where they were.
    public static func spread(_ coordinates: [CLLocationCoordinate2D],
                              minSeparationMeters: Double = 10,
                              ringRadiusMeters: Double = 18) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }

        var groups: [[Int]] = []
        for (index, coordinate) in coordinates.enumerated() {
            if let existing = groups.firstIndex(where: { group in
                group.contains { meters(coordinates[$0], coordinate) < minSeparationMeters }
            }) {
                groups[existing].append(index)
            } else {
                groups.append([index])
            }
        }

        var result = coordinates
        for group in groups where group.count > 1 {
            let center = centroid(group.map { coordinates[$0] })
            for (slot, index) in group.enumerated() {
                let angle = 2 * Double.pi * Double(slot) / Double(group.count)
                result[index] = offset(center, meters: ringRadiusMeters, angle: angle)
            }
        }
        return result
    }

    /// True when spreading would move anything — used to show the footnote only when it applies.
    public static func needsSpreading(_ coordinates: [CLLocationCoordinate2D],
                                      minSeparationMeters: Double = 10) -> Bool {
        guard coordinates.count > 1 else { return false }
        for i in coordinates.indices {
            for j in coordinates.indices where j > i {
                if meters(coordinates[i], coordinates[j]) < minSeparationMeters { return true }
            }
        }
        return false
    }

    // MARK: - geometry

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func centroid(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coordinates.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let lat = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let lon = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func offset(_ origin: CLLocationCoordinate2D,
                       meters distance: Double,
                       angle: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(origin.latitude * Double.pi / 180)
        let dLat = (distance * sin(angle)) / metersPerDegreeLat
        let dLon = (distance * cos(angle)) / max(metersPerDegreeLon, 1)
        return CLLocationCoordinate2D(latitude: origin.latitude + dLat, longitude: origin.longitude + dLon)
    }
}
