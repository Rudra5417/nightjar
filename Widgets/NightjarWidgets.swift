import ActivityKit
import SwiftUI
import WidgetKit
import NightjarCore

/// Live Activity: what keeps the phone scanning with the screen off.
///
/// Apple's Core Bluetooth overview says an app with an instantiated CBManager that has a Live
/// Activity running keeps its foreground scanning privileges — unfiltered scans and duplicate
/// reporting — while backgrounded. The activity is the price of admission, so it has to be
/// useful in its own right: it shows what is being heard right now.
@main
struct NightjarWidgets: WidgetBundle {
    var body: some Widget {
        ScanActivityWidget()
    }
}

struct ScanActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScanActivityAttributes.self) { context in
            // Lock screen / banner
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.05, blue: 0.07))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.radios)", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.elapsedLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.strongest ?? "nothing named yet")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("\(context.state.named) named · \(context.state.node)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text("\(context.state.radios)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.cyan)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ScanActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("NIGHTJAR · \(context.state.radios) radios")
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(.cyan)
                Text(context.state.strongest ?? "listening")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(context.state.named) named · \(context.state.node) · \(context.state.elapsedLabel)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}
