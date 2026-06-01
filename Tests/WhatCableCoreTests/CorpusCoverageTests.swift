import Foundation
import Testing

/// Guards the customer-probe corpus's queryable index (`corpus.jsonl`) so the
/// audit fixtures cannot silently vanish. The post-redesign diagnostic audit
/// (and the work it spawned: TRM/DAR-134, advanced-PD/DAR-136, cable-trust/
/// DAR-137) leans on these signals being present in the corpus. A bad
/// regeneration or an accidental edit that drops records or strips a signal
/// would quietly remove the fixtures those tasks and their regression tests
/// depend on. This catches that.
///
/// Reads the git-tracked `corpus.jsonl` (not the gitignored raw probes), so it
/// runs identically on a fresh clone. Thresholds sit comfortably below the
/// current counts: they flag a collapse, not normal growth.
@Suite("Customer-probe corpus coverage")
struct CorpusCoverageTests {
    private static let corpusURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes/corpus.jsonl")
    }()

    struct MalformedCorpusLine: Error { let line: Int }

    private static func records() throws -> [[String: Any]] {
        let text = try String(contentsOf: corpusURL, encoding: .utf8)
        // Fail fast on a malformed line rather than silently dropping it: a
        // corrupt regeneration must surface as a test failure, not a quietly
        // lower record count that still clears the thresholds.
        return try text
            .split(separator: "\n")
            .enumerated()
            .map { index, line in
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw MalformedCorpusLine(line: index + 1)
                }
                return obj
            }
    }

    private static func signals(_ r: [String: Any]) -> [String: Any] {
        (r["signals"] as? [String: Any]) ?? [:]
    }

    @Test("corpus has the expected total record count")
    func totalRecords() throws {
        let recs = try Self.records()
        #expect(recs.count >= 200,
            "corpus.jsonl should hold the full corpus (200+ folders); found \(recs.count). A drop means records were lost in regeneration.")
    }

    @Test("TRM-restriction fixtures present (DAR-134)")
    func trmFixtures() throws {
        let n = try Self.records().filter { ((Self.signals($0)["trm_restricted"] as? Int) ?? 0) > 0 }.count
        #expect(n >= 30, "expected 30+ TRM-restricted folders as fixtures for DAR-134; found \(n)")
    }

    @Test("CIO / connected-Thunderbolt fixtures present")
    func cioFixtures() throws {
        let n = try Self.records().filter { ((($0["cio_blocks"] as? Int)) ?? 0) > 0 }.count
        #expect(n >= 25, "expected 25+ CIO folders (mine-cio + port-key fixtures); found \(n)")
    }

    @Test("advanced-PD fixtures present (DAR-136)")
    func advancedPDFixtures() throws {
        let n = try Self.records().filter { ((Self.signals($0)["advanced_pd"] as? [Any]) ?? []).isEmpty == false }.count
        #expect(n >= 80, "expected 80+ advanced-PD folders as fixtures for DAR-136; found \(n)")
    }

    @Test("zeroed-VID cable-trust fixtures present (DAR-137)")
    func zeroedVIDFixtures() throws {
        let n = try Self.records().filter {
            (($0["trust"] as? [String: Any])?["zeroed_vid_cables"] as? [Any] ?? []).isEmpty == false
        }.count
        #expect(n >= 20, "expected 20+ zeroed-VID cable folders as fixtures for DAR-137; found \(n)")
    }

    @Test("Billboard fixtures present")
    func billboardFixtures() throws {
        let n = try Self.records().filter { ((Self.signals($0)["billboard"] as? Int) ?? 0) > 0 }.count
        #expect(n >= 30, "expected 30+ Billboard (bDeviceClass 0x11) folders; found \(n)")
    }
}
