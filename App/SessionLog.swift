import Foundation
import NightjarCore

/// Append-only session log, one JSON object per line, in the app's Documents folder.
///
/// Deliberately boring: newline JSON means a session is greppable, diffable, and can be
/// replayed into `nightjar-probe` on a Mac without any export tooling.
@MainActor
final class SessionLog: ObservableObject {

    @Published private(set) var sessionName: String
    @Published private(set) var lines = 0

    private var handle: FileHandle?
    private let url: URL

    init() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "sit-\(stamp)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent("\(name).jsonl")
        sessionName = name
        url = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    var path: String { url.path }

    func append(_ obs: Observation, hits: [FleetHit]) {
        guard let handle else { return }
        let object: [String: Any] = [
            "t": obs.kind == .wifi ? "ap" : "ble",
            "node": obs.sourceNodeId ?? "phone",
            "addr": obs.mac ?? obs.platformId ?? "",
            "mac": obs.mac ?? NSNull(),
            "name": obs.name,
            "rssi": obs.rssi,
            "band": obs.band ?? NSNull(),
            "ch": obs.channel ?? NSNull(),
            "addr_type": obs.addressType ?? NSNull(),
            "mfg_id": obs.manufacturerId ?? NSNull(),
            "uuids": obs.serviceUuids,
            "count": obs.heardCount,
            "ms": obs.lastSeenMs ?? Int(Date().timeIntervalSince1970 * 1000),
            "signatures": hits.map { $0.fleet.name },
            "classes": hits.compactMap { $0.fleet.kind?.label },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        handle.write(Data(text.utf8))
        lines += 1
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
