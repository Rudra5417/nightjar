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

    /// The strongest claim any matched fleet makes about this radio; nil when nothing matched.
    var confidence: Confidence? {
        hits.map { $0.confidence }.max()
    }

    var rssiLabel: String {
        observation.rssiIsKnown ? "\(observation.rssi)" : "—"
    }
}

/// A place and a moment at which a device was heard.
///
/// The coordinate is where the phone was, not where the device is: RSSI gives a range, not a
/// bearing, so a single phone cannot locate a BLE peer.
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

/// A device judged to be travelling with the user, with the evidence behind the verdict.
struct Follower: Identifiable {
    let id: String
    let title: String
    let verdict: CoTravelVerdict

    var evidence: String {
        "\(verdict.places) places · \(verdict.spanLabel) · \(verdict.sightings) sightings"
    }
}

@MainActor
final class AppModel: ObservableObject {

    /// What the list shows. "Named" means a claim worth making: an identifier or a name matched.
    /// A bare vendor id is not one, so it is offered under "Possible" rather than mixed in with
    /// the devices the app can actually stand behind.
    enum Filter: String, CaseIterable, Identifiable {
        case named = "Named"
        case possible = "Possible"
        case all = "All"
        var id: String { rawValue }
    }

    let catalog = Catalog()
    let scanner = RadioScanner()
    let log = SessionLog()
    let reminder = ExpiryReminder()
    let activity = LiveActivityController()
    let location = LocationTracker()
    let mute = MuteList()
    let follow = FollowNotifier()

    @Published private(set) var rows: [RadioRow] = []
    @Published private(set) var detections: [String: [Detection]] = [:]
    /// Devices judged to be travelling with you.
    @Published private(set) var followers: [Follower] = []
    /// The session tag, so the two halves of an A/B walk are labelled in the log itself.
    @Published var sessionMode: SessionLog.Mode {
        didSet {
            log.setMode(sessionMode)
            UserDefaults.standard.set(sessionMode.rawValue, forKey: "nightjar.session.mode")
        }
    }
    @Published var filter: Filter = .named
    @Published var selectedKey: String?

    private let coTravel = CoTravelEngine()
    private var hitsByKey: [String: [FleetHit]] = [:]
    private var rssiHistory: [String: [Int]] = [:]
    /// Verdicts are swept on a slow clock: the answer changes over minutes, not frames, and this
    /// sits inside a path that runs thousands of times a minute.
    private var lastFollowSweep = Date.distantPast
    private var alertedFollowers: Set<String> = []

    init() {
        let stored = UserDefaults.standard.string(forKey: "nightjar.session.mode")
            .flatMap(SessionLog.Mode.init(rawValue:)) ?? .phoneOnly
        sessionMode = stored
        // Property observers do not fire during init, so push the stored mode into the log here.
        log.setMode(stored)
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
        Task { await follow.refreshAuthorization() }
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
        noteMovement(for: key, rssi: obs.rssi)
        log.append(obs, hits: hits, coordinate: location.current?.coordinate)
        refresh()

        activity.update(radios: scanner.radios.count,
                        named: namedCount,
                        node: scanner.nodeId.map { "node \($0)" } ?? "phone",
                        strongest: rows.first(where: { !$0.hits.isEmpty })?.title)
    }

    /// One pin per device per place rather than one per advertisement: 6,000 frames a minute would
    /// otherwise stack 6,000 pins on the same spot.
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
        rows = scanner.radios.values
            .filter { !mute.contains($0.identityKey) }
            .map { obs in
                RadioRow(id: obs.identityKey, observation: obs, hits: hitsByKey[obs.identityKey] ?? [])
            }
            .filter { row in
                switch filter {
                case .all: return true
                case .possible: return !row.hits.isEmpty
                case .named: return (row.confidence ?? .possible) >= .probable
                }
            }
        .sorted { lhs, rhs in
            if lhs.hits.isEmpty != rhs.hits.isEmpty { return !lhs.hits.isEmpty }
            return lhs.observation.sortableRssi > rhs.observation.sortableRssi
        }
    }

    var namedCount: Int {
        scanner.radios.values.filter {
            (hitsByKey[$0.identityKey]?.map { $0.confidence }.max() ?? .possible) >= .probable
        }.count
    }

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

    // MARK: - following

    /// Feed the co-travel engine the same sightings the map gets, then sweep for verdicts.
    private func noteMovement(for key: String, rssi: Int) {
        guard !mute.contains(key),
              rssi != Observation.unknownRssi, rssi <= 0,
              let coordinate = location.current?.coordinate else { return }
        coTravel.observe(CoTravelSighting(key: key, coordinate: coordinate, at: Date(), rssi: rssi))

        guard Date().timeIntervalSince(lastFollowSweep) >= 5 else { return }
        lastFollowSweep = Date()
        sweepFollowers()
    }

    private func sweepFollowers() {
        followers = coTravel.followers().map { verdict in
            Follower(id: verdict.key, title: title(for: verdict.key), verdict: verdict)
        }

        // One alert per device per trip. A device that stops travelling is forgotten so that a
        // later trip can alert again.
        for follower in followers where !alertedFollowers.contains(follower.id) {
            let posted = follow.notify(title: follower.title,
                                       places: follower.verdict.places,
                                       spanLabel: follower.verdict.spanLabel,
                                       key: follower.id)
            if posted || !follow.enabled { alertedFollowers.insert(follower.id) }
        }
        for key in alertedFollowers where !followers.contains(where: { $0.id == key }) {
            if coTravel.verdict(for: key)?.isFollowing != true {
                alertedFollowers.remove(key)
                follow.forget(key)
            }
        }
    }

    private func title(for key: String) -> String {
        guard let obs = scanner.radios[key] else { return "unknown device" }
        return RadioRow(id: key, observation: obs, hits: hitsByKey[key] ?? []).title
    }

    /// Drops a muted device from the verdict list immediately rather than waiting for its track to
    /// go stale.
    func muteDevice(_ key: String, title: String) {
        mute.mute(key, title: title)
        followers.removeAll { $0.id == key }
        alertedFollowers.remove(key)
        follow.forget(key)
        if selectedKey == key { selectedKey = nil }
        refresh()
    }

    /// Turning alerts on is also what asks for permission.
    func setFollowAlerts(_ on: Bool) async {
        await follow.setEnabled(on)
        objectWillChange.send()
    }

    func unmuteAll() {
        mute.unmuteAll()
        refresh()
    }

    var mutedCount: Int { mute.count }
    var mutedSummary: String { mute.summary }

    // MARK: - phone versus node
    //
    // Per-source counts while a scan is running. The comparison tool works on finished logs; these
    // numbers report the node's contribution during the walk.

    var phoneRadios: Int { scanner.radios.values.filter { $0.sourceNodeId == nil }.count }
    var nodeRadios: Int { scanner.radios.values.filter { $0.sourceNodeId != nil }.count }
    var phoneNamed: Int {
        scanner.radios.values.filter { $0.sourceNodeId == nil && hitsByKey[$0.identityKey] != nil }.count
    }
    var nodeNamed: Int {
        scanner.radios.values.filter { $0.sourceNodeId != nil && hitsByKey[$0.identityKey] != nil }.count
    }

    var sourceSplit: String {
        nodeRadios > 0 ? "phone \(phoneRadios) · node \(nodeRadios)" : "phone only"
    }

    /// Plain-language summary of the node's contribution on this walk.
    var nodeVerdict: String {
        guard nodeRadios > 0 else {
            return "No node heard yet. Power it up and it will appear here."
        }
        guard nodeNamed > 0 else {
            return "The node has heard \(nodeRadios) radios but named none of them."
        }
        let ratio = phoneNamed > 0
            ? String(format: "%.1f×", Double(nodeNamed) / Double(phoneNamed))
            : "no baseline"
        return "Node has named \(nodeNamed) radios against the phone's \(phoneNamed) (\(ratio))."
    }

    func clear() {
        hitsByKey.removeAll()
        rssiHistory.removeAll()
        detections.removeAll()
        coTravel.reset()
        followers = []
        alertedFollowers.removeAll()
        lastFollowSweep = .distantPast
        rows = []
    }
}
