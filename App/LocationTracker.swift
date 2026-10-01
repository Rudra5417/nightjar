import Foundation
import CoreLocation

/// Where you were when you heard something.
///
/// A single phone cannot triangulate a BLE device — RSSI is a range, not a bearing. What it can
/// do is record the points along your path where a device was heard, which is what makes the
/// map honest: the pins are *your* positions, not the device's. Walking toward the source and
/// watching RSSI climb is the other half.
@MainActor
final class LocationTracker: NSObject, ObservableObject {

    @Published private(set) var current: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var path: [CLLocationCoordinate2D] = []

    /// Enough for a walk without turning into a GPS log.
    private let pathSpacingMeters: CLLocationDistance = 8

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        authorization = manager.authorizationStatus
    }

    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    var isAvailable: Bool { current != nil }

    var statusLabel: String {
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse: return current == nil ? "locating…" : "located"
        case .denied, .restricted: return "location off"
        case .notDetermined: return "no location yet"
        @unknown default: return "location ?"
        }
    }

    fileprivate func accept(_ location: CLLocation) {
        current = location
        let coord = location.coordinate
        if let last = path.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            guard location.distance(from: previous) >= pathSpacingMeters else { return }
        }
        path.append(coord)
    }
}

extension LocationTracker: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let fresh = locations.last(where: { $0.horizontalAccuracy >= 0 })
        guard let fresh else { return }
        Task { @MainActor in self.accept(fresh) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is normal indoors; the last good one stays valid.
    }
}
