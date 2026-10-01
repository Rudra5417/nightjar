import SwiftUI
import EarshotCore

struct LiveView: View {

    @ObservedObject var model: AppModel
    @ObservedObject var reminder: ExpiryReminder
    @State private var tick = Date()

    private let cyan = Color(red: 0.176, green: 0.831, blue: 0.969)   // #2dd4f7
    private let violet = Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
    private let ink = Color(red: 0.04, green: 0.05, blue: 0.07)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(violet.opacity(0.3))
                list
                Divider().overlay(violet.opacity(0.3))
                footer
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    // MARK: - pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("EARSHOT")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(cyan)
                Spacer()
                Text("\(model.scanner.radios.count) radios")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text("\(model.namedCount) named · \(model.catalog.source) · \(model.catalog.fleets) fleets / \(model.catalog.rules) rules")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 8) {
                pill(model.scanner.isScanning ? "listening" : "paused",
                     color: model.scanner.isScanning ? cyan : .gray)
                pill(model.scanner.nodeState,
                     color: model.scanner.nodeState.contains("node ") ? violet : .gray)
                pill("catalog covers \(model.catalog.iosUsableRules)/\(model.catalog.rules) rules phone-only",
                     color: .gray)
                pill(reminder.summary, color: expiryColor)
            }
            HStack(spacing: 8) {
                Button(model.scanner.isScanning ? "Pause" : "Listen") {
                    model.scanner.isScanning ? model.scanner.stop() : model.scanner.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(cyan)

                Button(model.scanner.nodeScanning ? "Stop node" : "Start node") {
                    model.scanner.nodeScanning ? model.scanner.stopNode() : model.scanner.startNode()
                }
                .buttonStyle(.bordered)
                .tint(violet)
                .disabled(model.scanner.nodeId == nil)

                Toggle("named only", isOn: $model.showOnlyNamed)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: model.showOnlyNamed) { _, _ in model.refresh() }
                Text("named only")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))

                Button(reminderLabel) {
                    Task {
                        if reminder.authorization == .notDetermined {
                            await reminder.requestAuthorization()
                        } else {
                            reminder.schedule()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!reminder.hasClock || reminder.urgency == .expired)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.rows) { row in
                    rowView(row)
                }
                if model.rows.isEmpty {
                    Text("Nothing heard yet. Bring the phone near something that talks.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
    }

    private func rowView(_ row: RadioRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text("\(row.observation.rssi) dBm")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(row.hits.isEmpty ? .white.opacity(0.5) : cyan)
            }
            Text(row.address)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            HStack(spacing: 6) {
                ForEach(row.badges.prefix(6), id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(badgeFill(badge, named: !row.hits.isEmpty))
                        )
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            ProgressView(value: row.strength)
                .tint(row.hits.isEmpty ? .white.opacity(0.25) : violet)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(row.hits.isEmpty ? 0.04 : 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(row.hits.isEmpty ? .clear : cyan.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func badgeFill(_ badge: String, named: Bool) -> Color {
        if badge.hasPrefix("node ") { return violet.opacity(0.45) }
        if badge.hasPrefix("phone") { return .white.opacity(0.12) }
        if named && ["Surveillance", "Public safety", "Cameras", "Drones", "Finder tags", "Glasses"]
            .contains(badge) {
            return cyan.opacity(0.30)
        }
        return .white.opacity(0.10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("session \(model.log.sessionName) · \(model.log.lines) frames")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text("stored on this phone only · nothing is uploaded")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var expiryColor: Color {
        switch reminder.urgency {
        case .expired: return .red
        case .soon: return .orange
        case .fine: return cyan
        case .none: return .gray
        }
    }

    private var reminderLabel: String {
        guard reminder.hasClock else { return "no clock" }
        if reminder.authorization == .denied { return "notifications off" }
        if reminder.urgency == .expired { return "expired" }
        return reminder.scheduled.isEmpty ? "remind me" : "reminder set"
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.20)))
            .foregroundStyle(color)
    }
}
