import Foundation
import UserNotifications
import NightjarCore

/// The one alert that earns the right to interrupt you: something heard at several places, over
/// time, that is still with you.
///
/// Deliberately local notifications — push would need a paid developer account and a server, and
/// there is nothing here that a server should know. The app is usually in the foreground while
/// you are listening, so the delegate below makes the banner appear even then; otherwise the
/// alert would only be visible after you had already stopped looking.
@MainActor
final class FollowNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// One alert per device per window. A follower is a follower; repeating it every minute
    /// trains you to ignore it.
    private let cooldown: TimeInterval = 30 * 60
    private var lastAlert: [String: Date] = [:]

    private let enabledKey = "nightjar.follow.alerts"
    private let center = UNUserNotificationCenter.current()

    override init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        super.init()
        center.delegate = self
    }

    var summary: String {
        if !enabled { return "off" }
        switch authorization {
        case .authorized, .provisional, .ephemeral: return "on"
        case .denied: return "off in Settings"
        default: return "not asked yet"
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// Turning alerts on is what asks for permission — asking at launch, before there is anything
    /// to say, is how an app gets denied.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        if !on {
            enabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            return true
        }
        let granted = await requestAuthorization()
        enabled = granted
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    private func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        return granted || authorization == .authorized || authorization == .provisional
    }

    /// Returns true if a notification was actually posted, so the caller can say so in the UI
    /// rather than pretending an alert happened.
    @discardableResult
    func notify(title: String, places: Int, spanLabel: String, key: String) -> Bool {
        guard enabled else { return false }
        if let last = lastAlert[key], Date().timeIntervalSince(last) < cooldown { return false }

        let content = UNMutableNotificationContent()
        content.title = "Something is following you"
        content.body = "\(title) was heard at \(places) different places over \(spanLabel) — and it is still nearby."
        content.sound = .default
        content.threadIdentifier = "nightjar.follow"

        center.add(UNNotificationRequest(identifier: "follow-\(key)-\(Int(Date().timeIntervalSince1970))",
                                         content: content,
                                         trigger: nil))
        lastAlert[key] = Date()
        return true
    }

    func forget(_ key: String) { lastAlert.removeValue(forKey: key) }
    func forgetAll() { lastAlert.removeAll() }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
