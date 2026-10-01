import Foundation
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

    var badges: [String] {
        var out: [String] = []
        if let node = observation.sourceNodeId { out.append("node \(node)") } else { out.append("phone") }
        if observation.kind == .wifi {
            out.append("Wi-Fi")
            if let band = observation.band { out.append("\(band) GHz") }
            if let ch = observation.channel { out.append("ch \(ch)") }
            if observation.hiddenSsid { out.append("hidden") }
        } else {
            out.append("BLE")
            if let t = observation.addressType { out.append(t) }
        }
        out.append(contentsOf: hits.compactMap { $0.fleet.kind?.label })
        out.append(contentsOf: hits.map { $0.fleet.name })
        return out
    }

    var strength: Double {
        // -100 dBm .. -30 dBm mapped to 0 .. 1; unknown readings get no bar at all.
        guard observation.rssiIsKnown else { return 0 }
        return Double(max(0, min(1, (Double(observation.rssi) + 100) / 70)))
    }

    var rssiLabel: String {
        observation.rssiIsKnown ? "\(observation.rssi) dBm" : "no reading"
    }
}

@MainActor
final class AppModel: ObservableObject {

    let catalog = Catalog()
    let scanner = RadioScanner()
    let log = SessionLog()
    let reminder = ExpiryReminder()
    let activity = LiveActivityController()

    @Published private(set) var rows: [RadioRow] = []
    @Published var showOnlyNamed = false

    private var hitsByKey: [String: [FleetHit]] = [:]

    init() {
        scanner.onObservation = { [weak self] obs in
            self?.record(obs)
        }
    }

    private func record(_ obs: Observation) {
        let hits = catalog.match(obs)
        if !hits.isEmpty { hitsByKey[obs.identityKey] = hits }
        log.append(obs, hits: hits)
        refresh()
        activity.update(radios: scanner.radios.count,
                        named: namedCount,
                        node: scanner.nodeId.map { "node \($0)" } ?? "phone",
                        strongest: rows.first(where: { !$0.hits.isEmpty })?.title)
    }

    /// Listening and the Live Activity start together: the activity is what keeps the scan
    /// alive once the app is backgrounded.
    func startListening() {
        scanner.start()
        activity.start(catalogSource: catalog.source)
    }

    func stopListening() {
        scanner.stop()
        activity.stop()
    }

    func refresh() {
        rows = scanner.radios.values.map { obs in
            RadioRow(id: obs.identityKey, observation: obs, hits: hitsByKey[obs.identityKey] ?? [])
        }
        .filter { !showOnlyNamed || !$0.hits.isEmpty }
        .sorted { lhs, rhs in
            if lhs.hits.isEmpty != rhs.hits.isEmpty { return !lhs.hits.isEmpty }
            return lhs.observation.sortableRssi > rhs.observation.sortableRssi
        }
    }

    var namedCount: Int { rows.filter { !$0.hits.isEmpty }.count }

    func clear() {
        hitsByKey.removeAll()
        rows = []
    }
}
