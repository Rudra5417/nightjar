import SwiftUI
import NightjarCore

/// The app's palette in one place: cyan and violet on near-black.
enum Palette {
    static let cyan = Color(red: 0.176, green: 0.831, blue: 0.969)   // #2dd4f7
    static let violet = Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.15)
    static let ink = Color(red: 0.04, green: 0.05, blue: 0.07)

    /// A tier's colour. A settled claim is cyan; a hedged one is amber, so the hedge is visible.
    static func colour(for tier: Confidence) -> Color {
        switch tier {
        case .certain: return cyan
        case .probable: return violet
        case .possible: return amber
        }
    }
}
