import Foundation
@testable import NightjarCore

/// Locates the stock catalog pack inside the repository, so the engine tests run for anyone who
/// clones this repo rather than only on a machine where a copy happens to exist elsewhere.
enum TestCatalog {
    static var packURL: URL {
        if let override = ProcessInfo.processInfo.environment["FIELDWATCH_CATALOG"] {
            return URL(fileURLWithPath: override)
        }
        // Tests/NightjarCoreTests/TestCatalog.swift -> repository root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("App/Resources/fieldwatch-signatures-v2.json")
    }

    static func load() -> SignatureEngine? {
        guard FileManager.default.fileExists(atPath: packURL.path) else { return nil }
        return try? SignatureEngine.load(url: packURL)
    }
}
