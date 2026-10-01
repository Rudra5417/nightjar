import Foundation
import CoreLocation
import NightjarCore

/// Append-only session log, one JSON object per line, in the app's Documents folder.
///
/// Deliberately boring: newline JSON means a session is greppable, diffable, and can be
/// replayed into `nightjar-probe` on a Mac without any export tooling.
///
/// Every line carries the session mode ("phone" or "node") so an A/B — the same walk with and
/// without the sensor node — is self-describing months later, without anyone having to remember
/// which file was which.
@MainActor
final class SessionLog: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case phoneOnly = "phone"
        case withNode = "node"

        var id: String { rawValue }
        var label: String { self == .phoneOnly ? "Phone only" : "Phone + node" }
        var blurb: String {
            self == .phoneOnly
                ? "For the baseline walk. BLE only, no Wi-Fi, no hardware addresses."
                : "For the comparison walk with the sensor node powered up."
        }
    }

    @Published private(set) var sessionName: String
    @Published private(set) var lines = 0
    @Published private(set) var mode: Mode

    private var handle: FileHandle?
    private var wroteHeader = false
    private let url: URL

    init(mode: Mode = .phoneOnly) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "sit-\(stamp)-\(mode.rawValue)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent("\(name).jsonl")
        sessionName = name
        self.mode = mode
        url = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    var path: String { url.path }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        // Written as its own line so a session that switched modes mid-walk says so, rather than
        // silently relabelling everything that came before it.
        write(["t": "mode", "mode": new.rawValue, "ms": Self.nowMs])
    }

    func append(_ obs: Observation, hits: [FleetHit], coordinate: CLLocationCoordinate2D? = nil) {
        writeHeaderIfNeeded()
        write([
            "t": obs.kind == .wifi ? "ap" : "ble",
            "node": obs.sourceNodeId ?? "phone",
            "mode": mode.rawValue,
            "addr": obs.mac ?? obs.platformId ?? "",
            "mac": obs.mac ?? NSNull(),
            "name": obs.name,
            "rssi": obs.rssiIsKnown ? obs.rssi as Any : NSNull(),
            "lat": coordinate?.latitude ?? NSNull(),
            "lon": coordinate?.longitude ?? NSNull(),
            "band": obs.band ?? NSNull(),
            "ch": obs.channel ?? NSNull(),
            "addr_type": obs.addressType ?? NSNull(),
            "mfg_id": obs.manufacturerId ?? NSNull(),
            "uuids": obs.serviceUuids,
            "count": obs.heardCount,
            "ms": obs.lastSeenMs ?? Self.nowMs,
            "signatures": hits.map { $0.fleet.name },
            "classes": hits.compactMap { $0.fleet.kind?.label },
        ])
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    // MARK: - writing

    private func writeHeaderIfNeeded() {
        guard !wroteHeader else { return }
        wroteHeader = true
        write(["t": "session", "name": sessionName, "mode": mode.rawValue, "ms": Self.nowMs])
    }

    private func write(_ object: [String: Any]) {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: object),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        handle.write(Data(text.utf8))
        lines += 1
    }

    private static var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }
}
