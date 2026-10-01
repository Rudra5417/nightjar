import Foundation
import CoreLocation
import SwiftUI
import NightjarCore

/// One row of the live list: what was heard, and what the catalog made of it.
struct RadioRow: Identifiable {
    var id: String
    var observation: Observation
    var hits: [FleetHit]

    var title: String {
        if !observation.name.isEmpty { return observation.name }
        if let mac = observation.mac { return mac }
        if let mfg = observation.manufacturerId { return "company 0x\(String(mfg, radix: 16, uppercase: true))" }
        if let sd = observation.serviceData.first { return "service \(sd.uuid)" }
        return "unnamed"
    }

    var address: String {
        if let mac = observation.mac { return mac }
        return "no address (iOS)"
    }

    /// The two that matter at a glance: what it is, and how it was heard. Everything else moved
    /// into the detail view, because a row with six chips is a row nobody reads.
    var primaryBadges: [String] {
        var out = hits.map { $0.fleet.name }
        if let node = observation.sourceNodeId { out.append("node \(node)") }
        return Array(out.prefix(2))
    }

    var detailBadges: [String] {
        var out: [String] = []
        out.append(observation.kind == .wifi ? "Wi-Fi" : "BLE")
        if let band = observation.band { out.append("\(band) GHz") }
        if let ch = observation.channel { out.append("ch \(ch)") }
        if observation.hiddenSsid { out.append("hidden") }
        if let t = observation.addressType { out.append(t) }
        out.append(contentsOf: hits.compactMap { $0.fleet.kind?.label })
        return out
    }

    var strength: Double {
        // -100 dBm .. -30 dBm mapped to 0 .. 1; unknown readings get no bar at all.
        guard observation.rssiIsKnown else { return 0 }
        return Double(max(0, min(1, (Double(observation.rssi) + 100) / 70)))
    }

    var rssiLabel: String {
        observation.rssiIsKnown ? "\(observation.rssi)" : "—"
    }
}

/// A place and a moment at which a device was heard.
///
/// The pin is where *you* were, which is the only position a single phone can honestly put on a
/// map: RSSI gives a range, never a bearing. Walking toward the source and watching the reading
/// climb is the other half of the job.
struct Detection: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let rssi: Int
    let at: Date
}

enum Trend {
    case closer, farther, steady, unknown

    var label: String {
        switch self {
        case .closer: return "getting closer"
        case .farther: return "getting farther"
        case .steady: return "holding steady"
        case .unknown: return "walk to gauge it"
        }
    }

    var symbol: String {
        switch self {
        case .closer: return "arrow.up.right"
        case .farther: return "arrow.down.right"
        case .steady: return "equal"
        case .unknown: return "questionmark"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case named = "Named"
        case all = "All"
        var id: String { rawValue }
    }

    let catalog = Catalog()
    let scanner = RadioScanner()
    let log = SessionLog()
    let reminder = ExpiryReminder()
    let activity = LiveActivityController()
    let location = LocationTracker()

    @Published private(set) var rows: [RadioRow] = []
    @Published private(set) var detections: [String: [Detection]] = [:]
    @Published var filter: Filter = .named
    @Published var selectedKey: String?

    private var hitsByKey: [String: [FleetHit]] = [:]
    private var rssiHistory: [String: [Int]] = [:]

    init() {
        scanner.onObservation = { [weak self] obs in self?.record(obs) }
    }

    // MARK: - lifecycle

    /// Listening, location and the Live Activity start together: the activity is what keeps the
    /// scan alive once the app is backgrounded.
    func startListening() {
        location.requestAuthorization()
        location.start()
        scanner.start()
        activity.start(catalogSource: catalog.source)
    }

    func stopListening() {
        scanner.stop()
        activity.stop()
    }

    // MARK: - ingest

    private func record(_ obs: Observation) {
        let key = obs.identityKey
        let hits = catalog.match(obs)
        if !hits.isEmpty { hitsByKey[key] = hits }

        if obs.rssiIsKnown {
            var history = rssiHistory[key] ?? []
            history.append(obs.rssi)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            rssiHistory[key] = history
        }

        noteLocation(for: key, rssi: obs.rssi)
        log.append(obs, hits: hits, coordinate: location.current?.coordinate)
        refresh()

        activity.update(radios: scanner.radios.count,
                        named: namedCount,
                        node: scanner.nodeId.map { "node \($0)" } ?? "phone",
                        strongest: rows.first(where: { !$0.hits.isEmpty })?.title)
    }

    /// One pin per device per place, not one per advertisement — 6,000 frames a minute would
    /// otherwise become 6,000 identical pins on top of each other.
    private func noteLocation(for key: String, rssi: Int) {
        guard let coordinate = location.current?.coordinate,
              rssi != Observation.unknownRssi, rssi <= 0 else { return }
        var points = detections[key] ?? []
        if let last = points.last {
            let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let there = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            if here.distance(from: there) < 8 && Date().timeIntervalSince(last.at) < 6 { return }
        }
        points.append(Detection(coordinate: coordinate, rssi: rssi, at: Date()))
        if points.count > 400 { points.removeFirst(points.count - 400) }
        detections[key] = points
    }

    // MARK: - derived

    func refresh() {
        rows = scanner.radios.values.map { obs in
            RadioRow(id: obs.identityKey, observation: obs, hits: hitsByKey[obs.identityKey] ?? [])
        }
        .filter { filter == .all || !$0.hits.isEmpty }
        .sorted { lhs, rhs in
            if lhs.hits.isEmpty != rhs.hits.isEmpty { return !lhs.hits.isEmpty }
            return lhs.observation.sortableRssi > rhs.observation.sortableRssi
        }
    }

    var namedCount: Int { scanner.radios.values.filter { hitsByKey[$0.identityKey] != nil }.count }

    var selectedRow: RadioRow? { rows.first { $0.id == selectedKey } }

    func points(for key: String) -> [Detection] { detections[key] ?? [] }

    /// Where the signal has been heading over the last few readings.
    func trend(for key: String) -> Trend {
        guard let history = rssiHistory[key], history.count >= 4 else { return .unknown }
        let recent = history.suffix(2)
        let earlier = history.dropLast(2).suffix(2)
        let delta = Double(recent.reduce(0, +)) / Double(recent.count)
            - Double(earlier.reduce(0, +)) / Double(earlier.count)
        if delta >= 3 { return .closer }
        if delta <= -3 { return .farther }
        return .steady
    }

    func clear() {
        hitsByKey.removeAll()
        rssiHistory.removeAll()
        detections.removeAll()
        rows = []
    }
}
