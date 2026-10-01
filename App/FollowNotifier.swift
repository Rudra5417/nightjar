import Foundation
import UserNotifications
import NightjarCore

/// Posts a local notification when a device is judged to be travelling with the user.
///
/// Local notifications only: push requires a paid developer account and a server. The app is
/// usually in the foreground while listening, so the delegate below presents the banner in the
/// foreground too; otherwise the alert would arrive only after the user stopped looking.
@MainActor
final class FollowNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// One alert per device per window; repeating it every minute trains the user to ignore it.
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

    /// Enabling alerts is also what requests permission. Asking at launch, before there is
    /// anything to report, invites a denial.
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

    /// Returns true if a notification was posted, so callers can report the outcome accurately.
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
