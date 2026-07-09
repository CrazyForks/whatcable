import Foundation
import Testing
@testable import WhatCableDarwinBackend
import WhatCableCore

// MARK: - HPMPortUUIDMapCorpusSweepTests
//
// Corpus-replay coverage for `HPMPortUUIDMap` (Reading/HPMPortUUIDMap.swift)
// over probe 35 (`35_hpm_port_uuid.json`), which had zero corpus coverage
// before this file (`WatcherCorpusSweepTests.swift` covers `.normalise` only).
//
// SEAM NOTE: `HPMPortUUIDMap.current()` is unreachable from a test -- it walks
// live `AppleHPMDeviceHALType3` IOKit services directly, with no `read`
// closure seam at all. `HPMPortUUIDMap.from(ports:)`, by contrast, is fully
// reachable: it takes a plain `[AppleHPMInterface]` array, and
// `AppleHPMInterface.from(...)` (the public factory already covered by
// `WatcherCorpusSweepTests.swift`'s HPM sweep) builds those from a `read`
// closure with no IOKit involved. This file drives `.from(ports:)` with
// `AppleHPMInterface` values built the same production way, fed from probe
// 35's ground-truth port/UUID pairs, so both the join (`.from`) and the
// normalisation (`.normalise`, exercised indirectly here too) run against
// real per-machine UUID sets.
//
// Probe 35 format (verified against the corpus, 2026-07):
//   [0] Port-USB-C@3        class=AppleHPMDeviceHALType3
//         UUID=ADF2210F-FA00-4D29-4EFE-0C0883783E56  RID=2  Address=12
//         ConnectionUUID=8F6F98E1-5276-4DC1-BF0B-6761BE6562EB
//   [1] Port-MagSafe 3@1    class=AppleHPMDeviceHALType3
//         UUID=...
//
// PRIVACY: UUIDs are an internal join key only (see HPMPortUUIDMap's own
// doc comment and MEMORY.md "UUID/UID is private research data"). Assertion
// messages below only ever print an 8-char truncated prefix, never the full
// value, matching that rule even in local test failure output.
@Suite("HPMPortUUIDMap corpus sweep - port/UUID join (probe 35)")
struct HPMPortUUIDMapCorpusSweepTests {

    // MARK: - Probe root (duplicated across sweep files by house convention)

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allProbeFolders() -> [String] {
        (try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path)
            .filter { entry in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: probeRoot.appendingPathComponent(entry).path,
                    isDirectory: &isDir
                )
                return isDir.boolValue
            }
            .sorted()
        ) ?? []
    }

    // MARK: - Probe-35 parsing

    /// One `[N] Port-...@M  class=...` record plus its `UUID=` line.
    private struct Probe35Record {
        let label: String       // e.g. "Port-USB-C@3" or "Port-MagSafe 3@1"
        let portNumber: Int     // parsed decimal suffix after "@"
        let isMagSafe: Bool
        let uuid: String        // raw, with dashes, as printed
    }

    private static func parseProbe35(_ text: String) -> [Probe35Record] {
        var results: [Probe35Record] = []
        var pendingLabel: String?
        var pendingPortNumber: Int?
        var pendingIsMagSafe = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let closeIdx = trimmed.firstIndex(of: "]") {
                let afterBracket = trimmed[trimmed.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)
                guard let classRange = afterBracket.range(of: "class=") else { continue }
                let label = String(afterBracket[..<classRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard let atIdx = label.lastIndex(of: "@") else { continue }
                let numDigits = label[label.index(after: atIdx)...].prefix { $0.isNumber }
                guard let num = Int(numDigits) else { continue }
                pendingLabel = label
                pendingPortNumber = num
                pendingIsMagSafe = label.contains("MagSafe")
            } else if trimmed.hasPrefix("UUID="), let label = pendingLabel, let num = pendingPortNumber {
                let afterEq = trimmed.dropFirst("UUID=".count)
                let uuid = String(afterEq.prefix { $0 != " " })
                guard !uuid.isEmpty else { continue }
                results.append(Probe35Record(label: label, portNumber: num, isMagSafe: pendingIsMagSafe, uuid: uuid))
                pendingLabel = nil
                pendingPortNumber = nil
            }
        }
        return results
    }

    private static func loadProbe35(folder: String) -> [Probe35Record] {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("35_hpm_port_uuid.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return [] }
        return parseProbe35(text)
    }

    /// Truncate a UUID to 8 chars for assertion messages (privacy rule: never
    /// print a full HPM/Connection UUID, even in local test output).
    private static func shortUUID(_ uuid: String) -> String {
        String(uuid.prefix(8))
    }

    /// Build a real `AppleHPMInterface` via the production factory, the same
    /// way `AppleHPMInterfaceWatcher` would from live IOKit data, using the
    /// fields probe 35's ground truth gives us plus the minimum
    /// `AppleHPMInterface.from` needs to accept the record as a real port.
    private static func makeHPMInterface(from record: Probe35Record, entryID: UInt64) -> AppleHPMInterface? {
        let props: [String: Any] = [
            "PortTypeDescription": record.isMagSafe ? "MagSafe 3" : "USB-C",
            "PortNumber": NSNumber(value: record.portNumber),
            "PortType": NSNumber(value: record.isMagSafe ? 0x11 : 0x2),
        ]
        return AppleHPMInterface.from(
            entryID: entryID,
            serviceName: record.label,
            className: "AppleHPMDeviceHALType3",
            read: { props[$0] },
            hpmControllerUUID: record.uuid
        )
    }

    /// Ground-truth expected portKey from probe 35's own label, matching the
    /// format `AppleHPMInterface.portKey` produces: "17/N" for MagSafe (0x11
    /// decimal), "2/N" for USB-C (0x2 decimal).
    private static func expectedPortKey(_ record: Probe35Record) -> String {
        "\(record.isMagSafe ? 17 : 2)/\(record.portNumber)"
    }

    // MARK: - Corpus sweep

    @Test("Probe-35 sweep: every port record joins to a UUID with no collisions, portKey matches the probe's own label")
    func probe35SweepJoinAndPortKey() {
        var foldersScanned = 0
        var recordsTotal = 0
        var joinedTotal = 0
        var portKeyMismatches = 0

        for folder in Self.allProbeFolders() {
            let records = Self.loadProbe35(folder: folder)
            guard !records.isEmpty else { continue }
            foldersScanned += 1
            recordsTotal += records.count

            // Build AppleHPMInterface ports the same way the watcher would,
            // one per probe-35 record, via the real public factory.
            let ports: [AppleHPMInterface] = records.enumerated().compactMap { index, record in
                Self.makeHPMInterface(from: record, entryID: UInt64(index + 1))
            }
            #expect(ports.count == records.count,
                "\(folder): AppleHPMInterface.from rejected \(records.count - ports.count) of \(records.count) probe-35 records")

            // Production join: HPMPortUUIDMap.from(ports:).
            let map = HPMPortUUIDMap.from(ports: ports)

            // Invariant 1: every port's UUID resolves to a portKey (UUID
            // present for every port record, per the task brief). A distinct
            // UUID per record is expected (each physical port has its own HPM
            // controller UUID), so map.count should equal the number of
            // distinct normalised UUIDs across this machine's records.
            let distinctUUIDs = Set(records.map { HPMPortUUIDMap.normalise($0.uuid) })
            #expect(map.count == distinctUUIDs.count,
                "\(folder): map has \(map.count) entries but \(distinctUUIDs.count) distinct UUIDs were present")

            // Invariant 2: no collisions within a machine -- every record's
            // own (normalised) UUID must be a key in the map, and it must map
            // back to that record's own portKey.
            for record in records {
                let normalised = HPMPortUUIDMap.normalise(record.uuid)
                guard let resolvedKey = map[normalised] else {
                    Issue.record("\(folder): UUID \(Self.shortUUID(normalised))... from \(record.label) did not resolve in the map")
                    continue
                }
                joinedTotal += 1
                let expected = Self.expectedPortKey(record)
                if resolvedKey != expected { portKeyMismatches += 1 }
                #expect(resolvedKey == expected,
                    "\(folder): \(record.label) resolved to portKey \(resolvedKey), expected \(expected) (UUID \(Self.shortUUID(normalised))...)")
            }

            // Invariant 3: normalise() always yields exactly 32 lowercase hex
            // chars for a well-formed UUID (the format HPMPortUUIDMap.from
            // requires internally to accept an entry at all).
            for record in records {
                let normalised = HPMPortUUIDMap.normalise(record.uuid)
                #expect(normalised.count == 32,
                    "\(folder): normalised UUID length \(normalised.count) != 32 for \(record.label)")
                #expect(normalised == normalised.lowercased(),
                    "\(folder): normalise() did not lowercase for \(record.label)")
            }
        }

        print("[HPMPortUUIDMapSweep] \(foldersScanned) folders, \(recordsTotal) port records, "
            + "\(joinedTotal) joined, \(portKeyMismatches) portKey mismatches")

        // Correctness invariant: run whenever there is ANY probe-35 data at
        // all. A portKey mismatch is a real bug regardless of corpus size.
        if foldersScanned > 0 {
            #expect(portKeyMismatches == 0,
                "Expected zero portKey mismatches between HPMPortUUIDMap.from(ports:) and probe-35's own labels")
        }

        // Coverage floor: actual 156 folders, 537 port records as of 2026-07
        // (see corpus.jsonl for the current probe-35 count; 537 total records
        // computed directly from the on-disk corpus during this pass). Floor
        // set to ~85% of actual for both (135 folders, 455 records).
        //
        // Two-tier reality: probe 35 has ZERO git-tracked files (all 156 are
        // on-disk-only), so `foldersScanned` is 0 on a fresh clone and this
        // already skips via the threshold below. Verified directly: a
        // fresh-clone simulation (scratch dir with only git-tracked corpus
        // files) produces foldersScanned == 0 here. The explicit 50 threshold
        // is defensive consistency with the other probes in this pass.
        if foldersScanned >= 50 {
            #expect(foldersScanned >= 135,
                "Expected at least 135 folders with probe-35 records; got \(foldersScanned)")
            #expect(recordsTotal >= 455,
                "Expected at least 455 probe-35 port records across the corpus; got \(recordsTotal)")
        }
    }

    // MARK: - MagSafe / USB-C same-@N collision fixture
    //
    // CLAUDE.md flags this explicitly: the `@N` socket suffix on a power-only
    // (MagSafe) port can collide with the first USB-C port on the same HPM
    // controller (issue #195). HPMPortUUIDMap must keep them apart because
    // MagSafe and USB-C use different rawType prefixes (17 vs 2) even when N
    // is identical. Restated here as a fixture because it is easy for a
    // future edit to `expectedPortKey`'s reasoning (or the production
    // `portKey` computed property it mirrors) to silently collapse this case,
    // and the real corpus may not always have a same-@N MagSafe/USB-C pair on
    // disk to catch it via the sweep alone.
    @Test("Fixture: MagSafe@1 and USB-C@1 on the same machine keep distinct portKeys")
    func fixtureMagSafeAndUSBCSameNumberDoNotCollide() {
        let usbC = Probe35Record(label: "Port-USB-C@1", portNumber: 1, isMagSafe: false,
                                  uuid: "11111111-1111-1111-1111-111111111111")
        let magSafe = Probe35Record(label: "Port-MagSafe 3@1", portNumber: 1, isMagSafe: true,
                                     uuid: "22222222-2222-2222-2222-222222222222")
        let ports = [usbC, magSafe].enumerated().compactMap { i, r in
            Self.makeHPMInterface(from: r, entryID: UInt64(i + 1))
        }
        #expect(ports.count == 2)
        let map = HPMPortUUIDMap.from(ports: ports)
        #expect(map.count == 2)
        #expect(map[HPMPortUUIDMap.normalise(usbC.uuid)] == "2/1")
        #expect(map[HPMPortUUIDMap.normalise(magSafe.uuid)] == "17/1")
    }

    @Test("Fixture: a port with no hpmControllerUUID is excluded from the map, not crashed on")
    func fixturePortWithoutUUIDIsExcluded() {
        let props: [String: Any] = [
            "PortTypeDescription": "USB-C",
            "PortNumber": NSNumber(value: 2),
            "PortType": NSNumber(value: 0x2),
        ]
        let port = AppleHPMInterface.from(
            entryID: 1, serviceName: "Port-USB-C@2", className: "AppleHPMInterfaceType10",
            read: { props[$0] }, hpmControllerUUID: nil
        )
        #expect(port != nil)
        let map = HPMPortUUIDMap.from(ports: [port!])
        #expect(map.isEmpty, "a port with no UUID must not appear in the join map")
    }
}
