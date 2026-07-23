import Foundation

#if DEBUG
/// Loads the bundled diagnostic contract fixtures exported by AHG. These are the
/// only inputs the internal diagnostic screen renders, there is no live AHG
/// integration in the app.
///
/// DEBUG-only: no release code path reads the bundled fixture JSON. Load failures
/// are never swallowed, a malformed or wrong-version fixture is reported, not
/// silently omitted, so a drifted contract fails visibly.
public enum DiagnosticFixtures {
    public struct LoadResult: Sendable {
        public let contracts: [DiagnosticContract]
        /// One entry per fixture that could not be loaded: "<file>: <reason>".
        public let failures: [String]
    }

    public static func load() -> LoadResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let root = Bundle.module.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: nil) else {
            return LoadResult(contracts: [], failures: ["resource bundle not found"])
        }

        var contracts: [DiagnosticContract] = []
        var failures: [String] = []
        for url in urls.filter({ $0.pathExtension == "json" })
                       .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                failures.append("\(name): unreadable"); continue
            }
            do {
                let contract = try decoder.decode(DiagnosticContract.self, from: data)
                guard contract.schemaVersion == DiagnosticContract.supportedSchemaVersion else {
                    failures.append("\(name): unsupported schema version \(contract.schemaVersion)")
                    continue
                }
                contracts.append(contract)
            } catch {
                failures.append("\(name): decode failed (\(error))")
            }
        }
        return LoadResult(contracts: contracts, failures: failures)
    }

    /// Convenience for callers that only want the successfully-loaded contracts.
    public static func all() -> [DiagnosticContract] { load().contracts }
}
#endif
