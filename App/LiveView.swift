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
    @State private var evidence: RadioRow?

    private let cyan = Palette.cyan
    private let violet = Palette.violet
    private let amber = Palette.amber
    private let ink = Palette.ink

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
        .sheet(item: $evidence) { row in
            EvidenceView(model: model, row: row) {
                evidence = nil
                open(row)
            }
        }
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
            Text("\(model.namedCount) named · \(model.log.lines) frames · \(model.sourceSplit)")
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
                    if !model.followers.isEmpty { followingSection }
                    ForEach(model.rows) { row in
                        Button { evidence = row } label: { rowView(row) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    model.muteDevice(row.id, title: row.title)
                                } label: {
                                    Label("Mute this device", systemImage: "bell.slash")
                                }
                            }
                    }
                    if model.rows.isEmpty {
                        Text(emptyMessage)
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

    /// The only conclusion on this screen rather than a raw reading.
    private var followingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 12, weight: .bold))
                Text(model.followers.count == 1
                     ? "1 DEVICE IS TRAVELLING WITH YOU"
                     : "\(model.followers.count) DEVICES ARE TRAVELLING WITH YOU")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
            }
            .foregroundStyle(amber)

            ForEach(model.followers) { follower in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(follower.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(follower.evidence)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                        Text("heard where you were, over and over — not a fixed device")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Button {
                        model.muteDevice(follower.id, title: follower.title)
                    } label: {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(7)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(amber.opacity(0.13))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber.opacity(0.45), lineWidth: 1))
                )
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
                if let tier = row.confidence { tierChip(tier) }
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

    /// The confidence tier, so a hedged claim looks hedged on the list itself.
    private func tierChip(_ tier: Confidence) -> some View {
        Text(tier.label.uppercased())
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.colour(for: tier).opacity(0.20)))
            .foregroundStyle(Palette.colour(for: tier))
    }

    private func open(_ row: RadioRow) {
        model.selectedKey = row.id
        tab = .map
    }

    private var emptyMessage: String {
        switch model.filter {
        case .all:
            return "Nothing heard yet. Bring the phone near something that talks."
        case .possible:
            return "Nothing matched yet. All shows everything being heard."
        case .named:
            return "Nothing identified yet. Possible shows the hedged matches, All shows everything heard."
        }
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

    // MARK: - info sheet

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section("this walk") {
                    Picker("mode", selection: $model.sessionMode) {
                        ForEach(SessionLog.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.sessionMode.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    row("session", model.log.sessionName)
                    row("tagged", model.log.mode.rawValue)
                    row("location", model.location.statusLabel)
                    row("frames", "\(model.log.lines)")
                    row("radios heard", "\(model.scanner.radios.count)")
                    row("named by catalog", "\(model.namedCount)")
                    row("places mapped", "\(model.detections.values.reduce(0) { $0 + $1.count })")
                }
                Section("phone vs node") {
                    row("phone", "\(model.phoneRadios) radios · \(model.phoneNamed) named")
                    row("node", "\(model.nodeRadios) radios · \(model.nodeNamed) named")
                    Text(model.nodeVerdict)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Walk the same route twice — once tagged phone only, once with the node powered up — then compare the two logs on the Mac with `nightjar-probe --ab`.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section("catalog") {
                    row("source", model.catalog.source)
                    row("fleets", "\(model.catalog.fleets)")
                    row("rules", "\(model.catalog.rules)")
                    row("usable phone-only", "\(model.catalog.iosUsableRules) of \(model.catalog.rules)")
                }
                Section("following me") {
                    Toggle("Alert me if something follows me", isOn: Binding(
                        get: { model.follow.enabled },
                        set: { on in Task { await model.setFollowAlerts(on) } }))
                    row("notifications", model.follow.summary)
                    row("travelling with you", "\(model.followers.count)")
                    row("muted devices", "\(model.mutedCount)")
                    if model.mutedCount > 0 {
                        Text(model.mutedSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Unmute everything") { model.unmuteAll() }
                    }
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
