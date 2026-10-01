import Foundation
import EarshotCore

/// Loads the signature catalog and turns raw observations into named hits.
///
/// The stock pack (244 fleets / ~7k rules) ships in the app bundle. It is Fieldwatch's
/// catalog — MIT, © Off Grid Pete LLC — see NOTICE. A pack the user imports later wins.
@MainActor
final class Catalog: ObservableObject {

    @Published private(set) var engine: SignatureEngine?
    @Published private(set) var source = "no catalog"
    @Published private(set) var fleets = 0
    @Published private(set) var rules = 0
    @Published private(set) var iosUsableRules = 0

    init() { load() }

    func load() {
        let candidates: [(String, URL?)] = [
            ("imported pack", importedPackURL()),
            ("stock pack", Bundle.main.url(forResource: "fieldwatch-signatures-v2", withExtension: "json")),
        ]
        for (label, url) in candidates {
            guard let url, let engine = try? SignatureEngine.load(url: url) else { continue }
            self.engine = engine
            self.source = label
            self.fleets = engine.catalog.fleets.count
            self.rules = engine.catalog.fleets.reduce(0) { $0 + $1.rules.count }
            self.iosUsableRules = engine.portabilityReport().iosUsableRules
            return
        }
    }

    /// A pack dropped into the app's Documents folder (Files app → On My iPhone → Earshot).
    private func importedPackURL() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("fieldwatch-signatures-v2.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func match(_ obs: Observation) -> [FleetHit] {
        engine?.match(obs) ?? []
    }
}
