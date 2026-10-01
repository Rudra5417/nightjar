import Foundation

#if os(iOS)
import ActivityKit

/// Shared between the app (which starts and updates the activity) and the widget extension
/// (which renders it). The content state carries everything the widget needs, so the two
/// processes never touch a shared container — no App Groups, no paid capability.
public struct ScanActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var radios: Int
        public var named: Int
        public var node: String
        public var strongest: String?
        public var startedAt: Date

        public init(radios: Int, named: Int, node: String, strongest: String?, startedAt: Date) {
            self.radios = radios
            self.named = named
            self.node = node
            self.strongest = strongest
            self.startedAt = startedAt
        }

        public var elapsedLabel: String {
            let seconds = Int(Date().timeIntervalSince(startedAt))
            let minutes = seconds / 60
            return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        }
    }

    public var startedAt: Date
    public var catalogSource: String

    public init(startedAt: Date, catalogSource: String) {
        self.startedAt = startedAt
        self.catalogSource = catalogSource
    }
}
#endif
