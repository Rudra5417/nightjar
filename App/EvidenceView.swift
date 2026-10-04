import SwiftUI
import UIKit
import NightjarCore

/// Why the app says what it says about one radio.
///
/// Every claim on the live list is a rule from the catalog firing on an advertisement, and the
/// question that follows is always "which rule, and how much does that actually establish". This is
/// that answer: the matched fleets with their confidence tier, the rule that fired and what that
/// kind of rule can prove, the raw advertisement as it arrived, and where the device was heard.
struct EvidenceView: View {

    @ObservedObject var model: AppModel
    let row: RadioRow
    let onShowMap: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    verdict
                    matchedBy
                    advertisement
                    places
                    actions
                }
                .padding(16)
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("EVIDENCE")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(Palette.cyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Palette.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text(row.observation.kind == .wifi ? "WI-FI" : "BLE")
                Text(row.address)
                Text(row.rssiLabel == "—" ? "no reading" : "\(row.rssiLabel) dBm")
                Text(model.trend(for: row.id).label)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - verdict

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tier = row.confidence {
                HStack(spacing: 8) {
                    tierPill(tier)
                    Text(tier.claim)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Nothing in the catalog matched this radio. It is being heard, but not identified — which is the honest answer for most of what surrounds you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke((row.confidence.map { Palette.colour(for: $0) } ?? .white.opacity(0.2)).opacity(0.35),
                            lineWidth: 1))
        )
    }

    // MARK: - what matched

    @ViewBuilder
    private var matchedBy: some View {
        if !row.hits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("matched by")
                ForEach(row.hits, id: \.fleet.id) { hit in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(hit.fleet.name)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            if let cls = hit.fleet.kind?.label {
                                Text(cls.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            tierPill(hit.confidence)
                        }

                        if let note = hit.fleet.attentionNote ?? hit.fleet.notes, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(Array(hit.matchedRules.enumerated()), id: \.offset) { _, rule in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(rule.kind.rawValue)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Palette.colour(for: rule.kind.confidence))
                                    Text(rule.pattern)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                Text(rule.strengthNote)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !hit.decoded.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("DECODED")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.35))
                                ForEach(hit.decoded, id: \.id) { field in
                                    kv(field.label, field.note.map { "\(field.value) (\($0))" } ?? field.value)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
                }
            }
        }
    }

    // MARK: - the raw advertisement

    private var advertisement: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("what was heard")
            kv("first seen", "\(ago(row.observation.firstSeenMs)) · \(clock(row.observation.firstSeenMs))")
            kv("last seen", "\(ago(row.observation.lastSeenMs)) · \(clock(row.observation.lastSeenMs))")
            kv("advertisements", "\(row.observation.heardCount)")
            kv("address", row.address)
            if let type = row.observation.addressType { kv("address type", type) }
            kv("services", row.observation.serviceUuids.isEmpty ? "none advertised" : row.observation.serviceUuids.joined(separator: ", "))
            kv("company", company)
            if !row.observation.manufacturerDataHex.isEmpty {
                kv("company data", grouped(row.observation.manufacturerDataHex))
            }
            ForEach(Array(row.observation.serviceData.enumerated()), id: \.offset) { _, record in
                kv("service \(record.uuid)", grouped(record.hex))
            }
            if let band = row.observation.band { kv("band", "\(band) GHz") }
            if let channel = row.observation.channel { kv("channel", "\(channel)") }
            kv("heard by", row.observation.sourceNodeId.map { "sensor node \($0)" } ?? "this phone")
        }
    }

    // MARK: - where

    private var places: some View {
        let points = model.points(for: row.id)
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("where")
            kv("places heard", "\(points.count)")
            if let first = points.first {
                kv("first at", coordinate(first.coordinate))
            }
            if let last = points.last {
                kv("last at", coordinate(last.coordinate))
            }
            Text(points.isEmpty
                 ? "No positions yet: iOS only records where you were when the phone had a fix."
                 : "These are the positions the phone occupied, never a computed position for the device. One radio gives a range, not a bearing.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("actions")
            HStack(spacing: 10) {
                Button {
                    onShowMap()
                } label: {
                    Label("Show on map", systemImage: "map")
                }
                .buttonStyle(.bordered)
                .tint(Palette.cyan)

                Button {
                    UIPasteboard.general.string = rawJSON
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy raw", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(Palette.violet)

                Button(role: .destructive) {
                    model.muteDevice(row.id, title: row.title)
                    dismiss()
                } label: {
                    Label("Mute", systemImage: "bell.slash")
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    // MARK: - pieces

    private func tierPill(_ tier: Confidence) -> some View {
        Text(tier.label.uppercased())
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.colour(for: tier).opacity(0.20)))
            .foregroundStyle(Palette.colour(for: tier))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - formatting

    private var company: String {
        guard let id = row.observation.manufacturerId else { return "none advertised" }
        return String(format: "0x%04X (%d)", id, id)
    }

    private func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2)
            .map { start -> String in
                let from = hex.index(hex.startIndex, offsetBy: start)
                let to = hex.index(from, offsetBy: min(2, hex.count - start))
                return String(hex[from..<to])
            }
            .joined(separator: " ")
    }

    private func coordinate(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    private func ago(_ ms: Int?) -> String {
        guard let ms else { return "unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: Date())
    }

    private func clock(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The observation and the verdict together, for pasting into a report or an issue.
    private var rawJSON: String {
        var out: [String: Any] = [
            "kind": row.observation.kind.rawValue,
            "name": row.observation.name,
            "rssi": row.observation.rssi,
            "heardCount": row.observation.heardCount,
        ]
        if let mac = row.observation.mac { out["mac"] = mac }
        if let id = row.observation.manufacturerId { out["manufacturerId"] = id }
        if !row.observation.manufacturerDataHex.isEmpty { out["manufacturerData"] = row.observation.manufacturerDataHex }
        if !row.observation.serviceUuids.isEmpty { out["serviceUuids"] = row.observation.serviceUuids }
        if !row.observation.serviceData.isEmpty {
            out["serviceData"] = row.observation.serviceData.map { ["uuid": $0.uuid, "hex": $0.hex] }
        }
        if let node = row.observation.sourceNodeId { out["sourceNodeId"] = node }
        if let first = row.observation.firstSeenMs { out["firstSeenMs"] = first }
        if let last = row.observation.lastSeenMs { out["lastSeenMs"] = last }
        out["matched"] = row.hits.map { hit -> [String: Any] in
            [
                "fleet": hit.fleet.name,
                "class": hit.fleet.kind?.rawValue ?? "OTHER",
                "confidence": hit.confidence.label,
                "rules": hit.matchedRules.map { ["kind": $0.kind.rawValue, "pattern": $0.pattern] },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
