import SwiftUI
import NightjarCore

struct LiveView: View {

    @ObservedObject var model: AppModel
    @ObservedObject var reminder: ExpiryReminder
    @ObservedObject var activity: LiveActivityController

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live"
        case map = "Map"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .live
    @State private var showInfo = false

    private let cyan = Color(red: 0.176, green: 0.831, blue: 0.969)   // #2dd4f7
    private let violet = Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
    private let ink = Color(red: 0.04, green: 0.05, blue: 0.07)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Picker("view", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                switch tab {
                case .live: liveList
                case .map: ScreenerMap(model: model, location: model.location)
                }

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { infoSheet }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NIGHTJAR")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(cyan)
                statusDot
                Spacer()
                Text("\(model.scanner.radios.count) radios")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Text("\(model.namedCount) named · \(model.log.lines) frames · \(model.location.statusLabel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(model.scanner.isScanning ? cyan : .gray)
            .frame(width: 7, height: 7)
            .shadow(color: model.scanner.isScanning ? cyan.opacity(0.8) : .clear, radius: 4)
    }

    // MARK: - live list

    private var liveList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.filter == .named ? "\(model.rows.count) named" : "\(model.rows.count) radios")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Picker("filter", selection: $model.filter) {
                    ForEach(AppModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: model.filter) { _, _ in model.refresh() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        Button { open(row) } label: { rowView(row) }
                            .buttonStyle(.plain)
                    }
                    if model.rows.isEmpty {
                        Text(model.filter == .named
                             ? "Nothing named yet. Switch to All to see everything being heard."
                             : "Nothing heard yet. Bring the phone near something that talks.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func rowView(_ row: RadioRow) -> some View {
        let places = model.points(for: row.id).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(row.rssiLabel == "—" ? "—" : "\(row.rssiLabel)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(row.hits.isEmpty ? .white.opacity(0.45) : cyan)
            }
            HStack(spacing: 6) {
                ForEach(row.primaryBadges, id: \.self) { chip($0, strong: true) }
                if row.hits.isEmpty { chip("unmatched", strong: false) }
                Spacer()
                if places > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.and.ellipse")
                        Text("\(places)")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(row.hits.isEmpty ? 0.04 : 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(row.hits.isEmpty ? .clear : cyan.opacity(0.30), lineWidth: 1)
                )
        )
        .overlay(alignment: .bottomLeading) {
            if row.observation.rssiIsKnown {
                Capsule()
                    .fill(row.hits.isEmpty ? .white.opacity(0.18) : violet)
                    .frame(width: max(4, 60 * row.strength), height: 2)
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    private func chip(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(strong ? cyan.opacity(0.22) : .white.opacity(0.08)))
            .foregroundStyle(strong ? cyan : .white.opacity(0.6))
    }

    private func open(_ row: RadioRow) {
        model.selectedKey = row.id
        tab = .map
    }

    // MARK: - bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(model.scanner.isScanning ? "Pause" : "Listen") {
                model.scanner.isScanning ? model.stopListening() : model.startListening()
            }
            .buttonStyle(.borderedProminent)
            .tint(cyan)

            if model.scanner.nodeId != nil {
                Button(model.scanner.nodeScanning ? "Stop node" : "Start node") {
                    model.scanner.nodeScanning ? model.scanner.stopNode() : model.scanner.startNode()
                }
                .buttonStyle(.bordered)
                .tint(violet)
            } else {
                Text("no sensor node")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            Text(activity.isActive ? "background on" : "background off")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(activity.isActive ? violet : .white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ink.opacity(0.95))
    }

    // MARK: - info sheet (everything that used to clutter the header)

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section("session") {
                    row("name", model.log.sessionName)
                    row("frames", "\(model.log.lines)")
                    row("radios heard", "\(model.scanner.radios.count)")
                    row("named by catalog", "\(model.namedCount)")
                    row("places mapped", "\(model.detections.values.reduce(0) { $0 + $1.count })")
                }
                Section("catalog") {
                    row("source", model.catalog.source)
                    row("fleets", "\(model.catalog.fleets)")
                    row("rules", "\(model.catalog.rules)")
                    row("usable phone-only", "\(model.catalog.iosUsableRules) of \(model.catalog.rules)")
                }
                Section("background scanning") {
                    row("live activity", activity.summary)
                    row("node", model.scanner.nodeState)
                }
                Section("build signature") {
                    row("status", reminder.summary)
                    Button(reminderLabel) {
                        Task {
                            if reminder.authorization == .notDetermined {
                                await reminder.requestAuthorization()
                            } else {
                                reminder.schedule()
                            }
                        }
                    }
                    .disabled(!reminder.hasClock || reminder.urgency == .expired)
                }
                Section {
                    Text("Everything stays on this phone. Nothing is uploaded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nightjar")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showInfo = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var reminderLabel: String {
        guard reminder.hasClock else { return "no clock" }
        if reminder.authorization == .denied { return "notifications off" }
        if reminder.urgency == .expired { return "expired" }
        return reminder.scheduled.isEmpty ? "remind me before it expires" : "reminder set"
    }
}
