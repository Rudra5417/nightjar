import Foundation
import SwiftUI

/// Devices the user has chosen to hide.
///
/// A scan of an ordinary room is dominated by the user's own equipment, which is not a finding
/// and crowds out the few radios worth looking at. Muting is by identity key, which iOS keeps
/// stable for the life of the install, so a mute survives a relaunch.
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
