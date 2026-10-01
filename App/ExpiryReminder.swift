import Foundation
import UserNotifications
import EarshotCore

/// Watches the build's own signature and nags before it lapses.
///
/// A sideloaded app stops opening when its 7-day provisioning profile expires, so the app is
/// the only thing in the system that can warn you in time — it reads its own
/// `embedded.mobileprovision`, schedules two local notifications ahead of the expiry, and
/// shows the countdown on screen.
///
/// Local notifications only. Push notifications need a paid developer account; a
/// `UNTimeIntervalNotificationTrigger` does not.
@MainActor
final class ExpiryReminder: ObservableObject {

    /// How far ahead of expiry to warn. Two chances, because the first one is easy to swipe away.
    static let warningOffsets: [TimeInterval] = [48 * 3600, 12 * 3600]

    @Published private(set) var profile: ProvisioningProfile?
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var scheduled: [Date] = []

    private let center = UNUserNotificationCenter.current()
    private let ids = ["earshot.expiry.48h", "earshot.expiry.12h"]

    init() {
        profile = ProvisioningProfile.load()
        Task { await refreshAuthorization() }
    }

    // MARK: - status

    var hasClock: Bool { profile != nil }

    var summary: String {
        guard let profile else { return "no expiry clock (App Store build)" }
        return profile.isExpired() ? "signature expired — re-sign to open"
                                  : "signature \(profile.remainingLabel()) left"
    }

    /// Amber under two days, red once expired, plain otherwise.
    var urgency: Urgency {
        guard let profile else { return .none }
        if profile.isExpired() { return .expired }
        return profile.timeRemaining() < 48 * 3600 ? .soon : .fine
    }

    enum Urgency { case none, fine, soon, expired }

    // MARK: - permission

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional { schedule() }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    // MARK: - scheduling

    /// Reschedule from the profile's real expiry. Called on launch and after permission is
    /// granted, so the timers always track the current build rather than a stale one.
    func schedule() {
        guard let profile, !profile.isExpired() else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let now = Date()
        var planned: [Date] = []
        for (index, offset) in Self.warningOffsets.enumerated() {
            let fireDate = profile.expirationDate.addingTimeInterval(-offset)
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Earshot expires in \(Int(offset / 3600))h"
            content.body = "Plug the phone into your Mac and hit Run in Xcode to re-sign. "
                + "Your session log is kept."
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: ids[index], content: content, trigger: trigger))
            planned.append(fireDate)
        }
        scheduled = planned
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        scheduled = []
    }
}
