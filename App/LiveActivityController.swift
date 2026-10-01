import ActivityKit
import Foundation
import NightjarCore

/// Starts and keeps the Live Activity alive.
///
/// Two jobs: show what's being heard on the lock screen, and — per Apple's Core Bluetooth
/// overview — keep the app's foreground scanning privileges while it is backgrounded, as long
/// as a CBManager exists and an activity is running. That second job is the one that matters:
/// without it, an unfiltered background scan returns nothing.
@MainActor
final class LiveActivityController: ObservableObject {

    enum State: Equatable {
        case idle, active, unavailable, failed(String)
    }

    @Published private(set) var state: State = .idle

    private var activity: Activity<ScanActivityAttributes>?
    private var lastUpdate = Date.distantPast
    /// The widget is not a log sink; five seconds is plenty for a lock-screen glance.
    private let minimumUpdateInterval: TimeInterval = 5

    var isActive: Bool { activity != nil }

    func start(catalogSource: String) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            state = .unavailable
            print("[nightjar] live activities disabled in Settings")
            return
        }
        let now = Date()
        let attributes = ScanActivityAttributes(startedAt: now, catalogSource: catalogSource)
        let content = ScanActivityAttributes.ContentState(
            radios: 0, named: 0, node: "phone", strongest: nil, startedAt: now)
        do {
            let requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: nil))
            activity = requested
            state = .active
            print("[nightjar] live activity started id=\(requested.id)")
        } catch {
            state = .failed(error.localizedDescription)
            print("[nightjar] live activity failed: \(error)")
        }
    }

    func update(radios: Int, named: Int, node: String, strongest: String?, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= minimumUpdateInterval else { return }
        lastUpdate = now
        let content = ScanActivityAttributes.ContentState(
            radios: radios, named: named, node: node, strongest: strongest,
            startedAt: activity.attributes.startedAt)
        Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        state = .idle
        print("[nightjar] live activity ended")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    var summary: String {
        switch state {
        case .idle: return "background off"
        case .active: return "background on"
        case .unavailable: return "live activities off"
        case .failed: return "activity failed"
        }
    }
}
