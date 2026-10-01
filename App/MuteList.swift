import Foundation
import SwiftUI

/// Devices you have told the app to stop showing you.
///
/// A scan of a normal room is mostly your own things: your laptop, your earbuds, your television,
/// your router. They are not findings, they are furniture, and they crowd out the handful of
/// radios that actually are worth looking at. Muting is per identity key, and the key iOS gives
/// us is stable for the life of the install, so a mute survives a relaunch.
@MainActor
final class MuteList: ObservableObject {

    @Published private(set) var keys: Set<String> = []
    /// Kept alongside so the list can be shown in words rather than as UUIDs.
    @Published private(set) var titles: [String: String] = [:]

    private let defaults: UserDefaults
    private let keyStore = "nightjar.muted.keys"
    private let titleStore = "nightjar.muted.titles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = Set(defaults.stringArray(forKey: keyStore) ?? [])
        titles = (defaults.dictionary(forKey: titleStore) as? [String: String]) ?? [:]
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    func mute(_ key: String, title: String) {
        keys.insert(key)
        titles[key] = title
        persist()
    }

    func unmute(_ key: String) {
        keys.remove(key)
        titles.removeValue(forKey: key)
        persist()
    }

    func unmuteAll() {
        keys.removeAll()
        titles.removeAll()
        persist()
    }

    var count: Int { keys.count }

    var summary: String {
        guard !keys.isEmpty else { return "nothing muted" }
        let names = keys.compactMap { titles[$0] }.sorted()
        return names.prefix(3).joined(separator: ", ")
            + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }

    private func persist() {
        defaults.set(Array(keys), forKey: keyStore)
        defaults.set(titles, forKey: titleStore)
    }
}
