#!/usr/bin/env swift

// Build the bundled SQLite database from vendor and cable sources.
//
// Reads:
//   - Sources/WhatCableCore/Resources/usbif-vendors.tsv (USB-IF vendor list)
//   - https://usb-ids.gowdy.us/usb.ids (community vendor list, fetched live)
//
// Writes:
//   - Sources/WhatCableCore/Resources/whatcable.db (bundled in the app)
//   - docs/whatcable.db (served on the website)
//
// Run from the repo root:
//   swift scripts/build-cable-db.swift
//
// Flags:
//   --refresh-certs   refetch every USB-IF per-XID record instead of reusing
//                     the .cert-cache (picks up cables that changed, e.g.
//                     Pass -> Obsolete, or gained listings).
//   --test-parser     run the manual-vendors parser self-tests and exit.
// Env:
//   ALLOW_EMPTY_CERTS=1   permit a build with zero certifications (otherwise a
//                         collapsed cert table fails the build; see below).
//
// Requires: macOS (uses system SQLite3 via libsqlite3).

import Foundation
import SQLite3

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let vendorTSV = "\(repoRoot)/Sources/WhatCableCore/Resources/usbif-vendors.tsv"
let manualVendorTSV = "\(repoRoot)/data/manual-vendors.tsv"
let dbOutput = "\(repoRoot)/Sources/WhatCableCore/Resources/whatcable.db"
let dbWebCopy = "\(repoRoot)/docs/whatcable.db"
let cablesJSON = "\(repoRoot)/docs/cables.json"
let manualCablesMD = "\(repoRoot)/data/known-cables.md"
// The "Last updated" date the /cables page shows. Written here and committed,
// rather than worked out at site-build time, because the only two signals
// available then are both wrong on the public side: a git checkout resets file
// mtimes to checkout time, and the public Pages workflow clones at depth 1 so
// `git log` has no per-file history to read. Baking it in at generation time
// means the date travels with the data it describes.
let cablesUpdatedJSON = "\(repoRoot)/src/_data/cablesmeta.json"

// Per-XID USB-IF responses are cached here so a rebuild only fetches XIDs
// it hasn't seen before. Gitignored: the compiled cable_certs table in
// whatcable.db is what ships, not this cache.
let certCacheDir = "\(repoRoot)/.cert-cache"

// `--refresh-certs` bypasses the per-XID cache and refetches every XID, so a
// cable that has since changed (e.g. Pass -> Obsolete, or gained listings)
// is picked up. Without it, cached responses (including cached empties) are
// reused indefinitely. A successful refetch overwrites its cache entry.
let refreshCerts = CommandLine.arguments.contains("--refresh-certs")

// MARK: - SQLite helpers

var db: OpaquePointer?

func openDB() {
    // Remove existing DB so we always start fresh.
    try? FileManager.default.removeItem(atPath: dbOutput)

    let rc = sqlite3_open(dbOutput, &db)
    guard rc == SQLITE_OK else {
        fputs("error: sqlite3_open failed: \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        exit(1)
    }
    // WAL mode and synchronous=OFF for build-time speed (we're writing
    // once and the file is read-only at runtime).
    runSQL("PRAGMA journal_mode = WAL")
    runSQL("PRAGMA synchronous = OFF")
}

func runSQL(_ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &err)
    if rc != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(err)
        fputs("error: SQL failed: \(msg)\n  statement: \(sql)\n", stderr)
        exit(2)
    }
}

func closeDB() {
    // Switch out of WAL mode before shipping. The bundled .db is read-only
    // at runtime; WAL mode requires creating -shm/-wal sidecars, which
    // fails in read-only bundle directories.
    runSQL("PRAGMA journal_mode = DELETE")
    sqlite3_close(db)
    db = nil
    try? FileManager.default.removeItem(atPath: dbOutput + "-shm")
    try? FileManager.default.removeItem(atPath: dbOutput + "-wal")
}

// MARK: - Schema

func createSchema() {
    runSQL("""
        CREATE TABLE vendors (
            vid    INTEGER PRIMARY KEY,
            name   TEXT NOT NULL,
            source TEXT NOT NULL CHECK(source IN ('usbif', 'usbids', 'manual'))
        )
        """)

    runSQL("""
        CREATE TABLE cables (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            vid       INTEGER NOT NULL,
            pid       INTEGER NOT NULL,
            cable_vdo INTEGER NOT NULL DEFAULT 0,
            brand     TEXT NOT NULL,
            speed     TEXT NOT NULL DEFAULT '',
            power     TEXT NOT NULL DEFAULT '',
            type      TEXT NOT NULL DEFAULT 'passive',
            xid       TEXT NOT NULL DEFAULT 'none',
            issue_url TEXT NOT NULL DEFAULT ''
        )
        """)

    runSQL("CREATE INDEX idx_cables_fingerprint ON cables(vid, pid, cable_vdo)")

    // One (VID, PID) can legitimately cover several rows: the same OEM
    // silicon sold under different retail brands (#505, ACON 0x0522/0x0A33
    // as both Anker Prime and UGREEN), and one PID covering several
    // capability tiers told apart only by Cable VDO (#239, e.g. Chant
    // Sincere 0x0C62/0xC8F1's 3A and 5A variants). So identity is no longer
    // (VID, PID) alone; every parsed markdown row becomes a DB row.
    //
    // What's never legitimate is an EXACT duplicate: the same brand curated
    // twice for the same (VID, PID, Cable VDO). That is a data-entry error
    // (a row pasted twice, or two issues for the same cable never merged),
    // so the full key stays unique and a violation fails the build. See
    // `findExactDuplicateRow` below, which reports this with a clear message
    // before the DB insert can hit the constraint.
    runSQL("CREATE UNIQUE INDEX idx_cables_identity ON cables(vid, pid, cable_vdo, brand)")

    // USB-IF certification listings, keyed by the cable's Cert Stat XID.
    // One row per listing: a single XID can carry several (rebrands and
    // related models share it). This is neutral provenance, never a fraud
    // signal (see research/usb-if-registry.md): vendor_id is a mild
    // confirming match at most, absence is normal, and product_id is
    // deliberately NOT stored because USB-IF's is an internal row counter,
    // not a USB PID.
    runSQL("""
        CREATE TABLE cable_certs (
            xid       INTEGER NOT NULL,
            vendor_id INTEGER,
            company   TEXT NOT NULL DEFAULT '',
            model     TEXT NOT NULL DEFAULT '',
            status    TEXT NOT NULL DEFAULT '',
            cert_date TEXT NOT NULL DEFAULT '',
            source    TEXT NOT NULL DEFAULT 'per_xid' CHECK(source IN ('per_xid', 'bulk'))
        )
        """)
    runSQL("CREATE INDEX idx_cable_certs_xid ON cable_certs(xid)")
}

// MARK: - USB-IF vendor import

func importUSBIFVendors() -> Int {
    guard let text = try? String(contentsOfFile: vendorTSV, encoding: .utf8) else {
        fputs("error: could not read \(vendorTSV)\n", stderr)
        exit(3)
    }

    let insertSQL = "INSERT INTO vendors (vid, name, source) VALUES (?, ?, 'usbif')"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("error: prepare failed for vendor insert\n", stderr)
        exit(4)
    }

    runSQL("BEGIN TRANSACTION")
    var count = 0

    for line in text.components(separatedBy: "\n") {
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2, let vid = Int(parts[0]) else { continue }
        var name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        // Strip the " ‐ OBSOLETE" suffix from obsolete vendor entries so
        // users see clean names. The raw suffix is preserved in the TSV.
        let obsoleteSuffix = " \u{2010} OBSOLETE"
        if name.hasSuffix(obsoleteSuffix) {
            name = String(name.dropLast(obsoleteSuffix.count))
        }
        name = strippingContactEmail(from: name)

        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(vid))
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("warn: failed to insert VID \(vid): \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        }
        count += 1
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)
    return count
}

// MARK: - usb.ids community vendor import

// Mirrors of the same file, maintained by Stephen J. Gowdy. Tried in order.
// gowdy.us is the canonical primary; linux-usb.org serves an identical copy
// over plain HTTP. If both Gowdy-hosted mirrors are unreachable (cert expiry,
// DNS, etc.) we fall back to the Red Hat hwdata copy on GitHub, which lags
// upstream by a few months but is stable.
let usbidsMirrors: [URL] = [
    URL(string: "https://usb-ids.gowdy.us/usb.ids")!,
    URL(string: "http://www.linux-usb.org/usb.ids")!,
    URL(string: "https://raw.githubusercontent.com/vcrhonek/hwdata/master/usb.ids")!,
]

func fetchUSBIDs() -> String? {
    for url in usbidsMirrors {
        do {
            let data = try Data(contentsOf: url)
            // The file is mostly UTF-8 but contains a few invalid bytes.
            // Fall back to Latin-1 (which always succeeds) if strict UTF-8 fails.
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            if text != nil {
                fputs("usb.ids: fetched from \(url.host ?? url.absoluteString)\n", stderr)
                return text
            }
        } catch {
            fputs("warn: usb.ids fetch failed from \(url.host ?? url.absoluteString): \(error)\n", stderr)
        }
    }
    return nil
}

func importUSBIDsVendors() -> (inserted: Int, skipped: Int) {
    guard let text = fetchUSBIDs() else {
        fputs("warn: skipping usb.ids (fetch failed)\n", stderr)
        return (0, 0)
    }

    // INSERT OR IGNORE: USB-IF entries take priority (already loaded).
    let insertSQL = "INSERT OR IGNORE INTO vendors (vid, name, source) VALUES (?, ?, 'usbids')"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for usb.ids insert\n", stderr)
        return (0, 0)
    }

    runSQL("BEGIN TRANSACTION")
    var inserted = 0
    var skipped = 0

    // Format: lines starting with 4 hex digits + 2 spaces + name are
    // vendor entries. Lines with leading tabs are device/interface
    // entries (ignored). The vendor section ends at "C xx  class_name".
    let re = try! NSRegularExpression(pattern: "^([0-9a-fA-F]{4})  (.+)$")

    for line in text.components(separatedBy: "\n") {
        // Stop at the device class section.
        if line.hasPrefix("C ") { break }
        if line.hasPrefix("#") || line.hasPrefix("\t") || line.isEmpty { continue }

        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: range),
              m.numberOfRanges >= 3,
              let vidRange = Range(m.range(at: 1), in: line),
              let nameRange = Range(m.range(at: 2), in: line) else { continue }

        guard let vid = Int(String(line[vidRange]), radix: 16) else { continue }
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }

        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(vid))
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            // sqlite3_changes returns 0 for INSERT OR IGNORE when the
            // row already existed.
            if sqlite3_changes(db) > 0 {
                inserted += 1
            } else {
                skipped += 1
            }
        } else {
            skipped += 1
        }
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)
    return (inserted, skipped)
}

// MARK: - Manual vendor import (editorial additions)

struct ManualVendorEntry: Equatable {
    let vid: Int
    let name: String
}

/// Pure parser for manual-vendors.tsv. Returns parsed entries plus any
/// warnings the build script should print. Kept side-effect free so the
/// `--test-parser` mode can exercise it directly.
///
/// Validation rules:
/// - Comment lines (starting with `#`) and blank lines are ignored.
/// - Each data line must have exactly 2 tab-separated fields. Lines with
///   the wrong number of fields are warned and skipped.
/// - VID must be hex (with or without `0x`/`0X` prefix), within 0...0xFFFF.
/// - Name must be non-empty after trimming.
/// - Duplicate VIDs are warned and skipped (first occurrence wins).
func parseManualVendorsText(_ text: String) -> (entries: [ManualVendorEntry], warnings: [String]) {
    var entries: [ManualVendorEntry] = []
    var warnings: [String] = []
    var seen: Set<Int> = []

    for (zeroBasedIndex, rawLine) in text.components(separatedBy: "\n").enumerated() {
        let lineNum = zeroBasedIndex + 1
        // Trim only newlines and carriage returns at the line level so a
        // trailing tab (which is a real field separator) is not silently
        // collapsed into a single-field line. Per-field trimming below
        // still uses full whitespace.
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let visible = line.trimmingCharacters(in: .whitespaces)
        if visible.isEmpty || visible.hasPrefix("#") { continue }

        let parts = line.components(separatedBy: "\t")
        guard parts.count == 2 else {
            warnings.append("manual-vendors.tsv line \(lineNum): expected exactly 2 tab-separated fields, got \(parts.count); skipping")
            continue
        }

        let vidToken = parts[0].trimmingCharacters(in: .whitespaces)
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            warnings.append("manual-vendors.tsv line \(lineNum): empty vendor name; skipping")
            continue
        }

        let hexPart: String
        if vidToken.hasPrefix("0x") || vidToken.hasPrefix("0X") {
            hexPart = String(vidToken.dropFirst(2))
        } else {
            hexPart = vidToken
        }
        guard !hexPart.isEmpty, let vid = Int(hexPart, radix: 16) else {
            warnings.append("manual-vendors.tsv line \(lineNum): cannot parse VID '\(vidToken)' as hex; skipping")
            continue
        }
        guard (0...0xFFFF).contains(vid) else {
            warnings.append("manual-vendors.tsv line \(lineNum): VID '\(vidToken)' out of range (0...0xFFFF); skipping")
            continue
        }

        if !seen.insert(vid).inserted {
            warnings.append(String(format: "manual-vendors.tsv line %d: duplicate VID 0x%04X; keeping first occurrence", lineNum, vid))
            continue
        }

        entries.append(ManualVendorEntry(vid: vid, name: name))
    }

    return (entries, warnings)
}

func importManualVendors() -> (inserted: Int, skipped: Int) {
    guard let text = try? String(contentsOfFile: manualVendorTSV, encoding: .utf8) else {
        // The file is optional; an empty manual list is a valid state.
        return (0, 0)
    }

    let parsed = parseManualVendorsText(text)
    for warning in parsed.warnings {
        fputs("warn: \(warning)\n", stderr)
    }

    // INSERT OR IGNORE: USB-IF and usb.ids entries take priority, so a
    // manual row never silently overwrites either authoritative source.
    let insertSQL = "INSERT OR IGNORE INTO vendors (vid, name, source) VALUES (?, ?, 'manual')"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for manual vendor insert\n", stderr)
        return (0, 0)
    }

    runSQL("BEGIN TRANSACTION")
    var inserted = 0
    var skipped = 0

    for entry in parsed.entries {
        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(entry.vid))
        sqlite3_bind_text(stmt, 2, (entry.name as NSString).utf8String, -1, nil)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            if sqlite3_changes(db) > 0 {
                inserted += 1
            } else {
                skipped += 1
            }
        } else {
            skipped += 1
        }
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)
    return (inserted, skipped)
}

// MARK: - Self-test mode (--test-parser)

/// Returns a tuple (failures, output). Failures is the number of failed
/// assertions; output is the formatted test report.
func runManualVendorParserSelfTests() -> (failures: Int, output: String) {
    struct Case {
        let label: String
        let input: String
        let expectedEntries: [ManualVendorEntry]
        let expectedWarningSubstrings: [String]
    }

    let cases: [Case] = [
        Case(
            label: "happy path: single entry with 0x prefix",
            input: "0x01B6\tCalDigit, Inc.\n",
            expectedEntries: [ManualVendorEntry(vid: 0x01B6, name: "CalDigit, Inc.")],
            expectedWarningSubstrings: []
        ),
        Case(
            label: "happy path: hex without prefix, lowercase, uppercase",
            input: "01b6\tlower\n0X02A2\tupper-prefix\nFFFF\tmax\n",
            expectedEntries: [
                ManualVendorEntry(vid: 0x01B6, name: "lower"),
                ManualVendorEntry(vid: 0x02A2, name: "upper-prefix"),
                ManualVendorEntry(vid: 0xFFFF, name: "max"),
            ],
            expectedWarningSubstrings: []
        ),
        Case(
            label: "comments and blank lines are ignored",
            input: "# header comment\n\n# another\n0x01B6\tCalDigit, Inc.\n\n",
            expectedEntries: [ManualVendorEntry(vid: 0x01B6, name: "CalDigit, Inc.")],
            expectedWarningSubstrings: []
        ),
        Case(
            label: "extra fields are rejected",
            input: "0x01B6\tCalDigit, Inc.\textra\n",
            expectedEntries: [],
            expectedWarningSubstrings: ["expected exactly 2 tab-separated fields"]
        ),
        Case(
            label: "single field is rejected",
            input: "0x01B6\n",
            expectedEntries: [],
            expectedWarningSubstrings: ["expected exactly 2 tab-separated fields"]
        ),
        Case(
            label: "empty name is rejected",
            input: "0x01B6\t   \n",
            expectedEntries: [],
            expectedWarningSubstrings: ["empty vendor name"]
        ),
        Case(
            label: "non-hex VID is rejected",
            input: "0xZZZZ\tBogus\n",
            expectedEntries: [],
            expectedWarningSubstrings: ["cannot parse VID"]
        ),
        Case(
            label: "VID out of 16-bit range is rejected",
            input: "0x10000\tToo big\n",
            expectedEntries: [],
            expectedWarningSubstrings: ["out of range"]
        ),
        Case(
            label: "duplicate VID: first wins, second warned",
            input: "0x01B6\tFirst\n0x01B6\tSecond\n",
            expectedEntries: [ManualVendorEntry(vid: 0x01B6, name: "First")],
            expectedWarningSubstrings: ["duplicate VID 0x01B6"]
        ),
        Case(
            label: "VID 0 is allowed (lower bound)",
            input: "0x0000\tBoundary low\n",
            expectedEntries: [ManualVendorEntry(vid: 0, name: "Boundary low")],
            expectedWarningSubstrings: []
        ),
    ]

    var output = "Manual vendor parser self-tests\n"
    output += "================================\n"
    var failures = 0

    for c in cases {
        let result = parseManualVendorsText(c.input)
        var caseFailed = false
        var detail = ""

        if result.entries != c.expectedEntries {
            caseFailed = true
            detail += "  entries: expected \(c.expectedEntries), got \(result.entries)\n"
        }
        for substring in c.expectedWarningSubstrings {
            if !result.warnings.contains(where: { $0.contains(substring) }) {
                caseFailed = true
                detail += "  warnings missing '\(substring)'; got \(result.warnings)\n"
            }
        }
        if c.expectedWarningSubstrings.isEmpty && !result.warnings.isEmpty {
            caseFailed = true
            detail += "  unexpected warnings: \(result.warnings)\n"
        }

        if caseFailed {
            failures += 1
            output += "FAIL  \(c.label)\n"
            output += detail
        } else {
            output += "ok    \(c.label)\n"
        }
    }

    output += "\n\(cases.count - failures)/\(cases.count) passed"
    if failures > 0 {
        output += ", \(failures) FAILED"
    }
    output += "\n"
    return (failures, output)
}

/// Self-tests for `strippingContactEmail`. A vendor name legitimately
/// containing an `@` must survive untouched; only an actual address goes.
func runContactEmailSelfTests() -> (failures: Int, output: String) {
    let cases: [(label: String, input: String, expected: String)] = [
        // Fabricated addresses on purpose. An earlier version of these tests
        // used the real row from the registry, which would have written the
        // very address being stripped from the database into this file, which
        // ships publicly and keeps it in git history forever. Exactly the leak
        // the function exists to prevent, one layer up.
        ("a contact address is removed, company kept",
         "Example Instruments Inc. , firstname@example.com", "Example Instruments Inc."),
        ("an @ inside a company name survives",
         "M@inNet Communication", "M@inNet Communication"),
        ("a company name that IS an @-domain survives",
         "@pos.com", "@pos.com"),
        ("a plain name is untouched",
         "CalDigit, Inc.", "CalDigit, Inc."),
        ("an address with no comma is still removed",
         "Acme Ltd info@example.co.uk", "Acme Ltd"),
        ("a name that is only an address is kept rather than emptied",
         "firstname@example.com", "firstname@example.com"),
    ]
    var failures = 0
    var output = ""
    for c in cases {
        let got = strippingContactEmail(from: c.input)
        if got == c.expected {
            output += "ok    \(c.label)\n"
        } else {
            failures += 1
            output += "FAIL  \(c.label)\n        input:    \(c.input)\n"
            output += "        expected: \(c.expected)\n        got:      \(got)\n"
        }
    }
    output += "\n\(cases.count - failures)/\(cases.count) passed"
    if failures > 0 { output += ", \(failures) FAILED" }
    output += "\n"
    return (failures, output)
}

// --test-parser runs all self-test suites (manual-vendors, contact-email
// stripping, and the known-cables row parser below) and exits; see the
// bottom of the "Known cables import" section for the actual invocation,
// after `runKnownCablesParserSelfTests` is defined.

// MARK: - Known cables import (from data/known-cables.md)

let knownCablesMD = "\(repoRoot)/data/known-cables.md"

/// Parsed cable row from the markdown table, before DB insert.
private struct CableRow: Equatable {
    let vid: Int
    let pid: Int
    let cableVDO: Int
    let brand: String
    let speed: String
    let power: String
    let type: String
    let xid: String
    let issueURL: String
}

/// Parse "`0xABCD`" or "`0x01234567`" into an integer.
func parseHex(_ s: String) -> Int? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "`", with: "")
    guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") else { return nil }
    return Int(trimmed.dropFirst(2), radix: 16)
}

/// Pure parser for the known-cables markdown table: turns the "## Table"
/// block into flat `CableRow`s, applying the same skip rules the build uses.
/// No I/O beyond the text passed in, no sqlite, no `exit()`, so `--test-parser`
/// can exercise it directly and prove each rule actually does something.
///
/// Skip rules:
/// - `(needs review)` brand: no usable brand context yet.
/// - all-zero fingerprint (vid == 0 && pid == 0 && cableVDO == 0): carries no
///   identifying bits; `CableDB.curatedCables` refuses it at lookup time too.
private func parseCableRowsText(_ text: String) -> (
    rows: [CableRow], totalDataRows: Int, skippedNeedsReview: Int, skippedAllZero: Int
) {
    var parsed: [CableRow] = []
    var totalDataRows = 0
    var skippedNeedsReview = 0
    var skippedAllZero = 0
    var inTable = false

    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## Table") { inTable = true; continue }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|"), !line.contains("---") else { continue }

        let parts = line.dropFirst().dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 10 columns: Brand, VID, PID, Cable VDO, Vendor, XID, Speed, Power, Type, Source
        guard parts.count == 10 else { continue }
        // Skip header row
        guard parts[1].hasPrefix("`0x") else { continue }

        totalDataRows += 1
        let brand = parts[0]
        // Skip "(needs review)" rows - they have no usable brand context yet.
        if brand == "(needs review)" {
            skippedNeedsReview += 1
            continue
        }

        guard let vid = parseHex(parts[1]),
              let pid = parseHex(parts[2]) else { continue }
        let cableVDO = parseHex(parts[3]) ?? 0

        // All-zero fingerprint carries no identifying bits; CableDB.curatedCable
        // refuses it at lookup time, so there's no point storing it.
        if vid == 0 && pid == 0 && cableVDO == 0 {
            skippedAllZero += 1
            continue
        }

        let xid = parts[5].replacingOccurrences(of: "`", with: "")
        let speed = parts[6]
        let power = parts[7]
        let type = parts[8]
        // Source cell holds a markdown link "[#NN](url)", possibly with prose
        // around it. Anchor on "](" rather than the first "(" in the cell: a
        // source note like "Test-kit corpus (7 machines), see [#478](url)"
        // would otherwise yield "7 machines" as the link target.
        let issueURL: String
        if let linkStart = parts[9].range(of: "]("),
           let urlEnd = parts[9].range(of: ")", range: linkStart.upperBound..<parts[9].endIndex) {
            issueURL = String(parts[9][linkStart.upperBound..<urlEnd.lowerBound])
        } else {
            issueURL = ""
        }

        parsed.append(CableRow(
            vid: vid, pid: pid, cableVDO: cableVDO,
            brand: brand, speed: speed, power: power, type: type,
            xid: xid, issueURL: issueURL
        ))
    }

    return (parsed, totalDataRows, skippedNeedsReview, skippedAllZero)
}

/// Hex-formatted (VID, PID, Cable VDO) triple, for error messages.
private func fingerprintLabel(vid: Int, pid: Int, cableVDO: Int) -> String {
    String(format: "0x%04X:0x%04X:0x%08X", vid, pid, UInt32(bitPattern: Int32(cableVDO)))
}

/// Finds rows that share a real (VID, PID, Cable VDO) fingerprint but
/// disagree on Speed, Power, or Type, and returns a description of the
/// first one found (or nil if every shared fingerprint agrees).
///
/// "Real" excludes vid == 0 or pid == 0: a zeroed identity is not a product
/// identity (many unrelated cables legitimately share it), so consistency
/// isn't meaningful there. Two rows with different brands but the same real
/// fingerprint (the #505 case: the same OEM cable sold as Anker and UGREEN)
/// are expected to agree on capability even though the brand differs, because
/// they are the same physical cable; if they don't agree, that's a
/// data-entry mistake in one of the rows, not two different cables.
private func findFingerprintInconsistency(_ rows: [CableRow]) -> String? {
    var seenByKey: [String: CableRow] = [:]
    for row in rows {
        guard row.vid != 0, row.pid != 0 else { continue }
        let key = "\(row.vid):\(row.pid):\(row.cableVDO)"
        guard let existing = seenByKey[key] else {
            seenByKey[key] = row
            continue
        }
        if existing.speed != row.speed || existing.power != row.power || existing.type != row.type {
            let fp = fingerprintLabel(vid: row.vid, pid: row.pid, cableVDO: row.cableVDO)
            return """
                data/known-cables.md has inconsistent Speed/Power/Type for the same \
                (VID, PID, Cable VDO) fingerprint \(fp):
                  '\(existing.brand)': speed='\(existing.speed)' power='\(existing.power)' type='\(existing.type)'
                  '\(row.brand)': speed='\(row.speed)' power='\(row.power)' type='\(row.type)'
                Fix the markdown row(s) before rebuilding.
                """
        }
    }
    return nil
}

/// Finds an exact duplicate row (same VID, PID, Cable VDO, AND brand) and
/// returns a description of the first one found, or nil if every row's full
/// key is unique. Mirrors the `UNIQUE(vid, pid, cable_vdo, brand)` index the
/// build enforces in sqlite; checking it here first gives a clearer message
/// than a raw sqlite constraint error.
private func findExactDuplicateRow(_ rows: [CableRow]) -> String? {
    var seen: Set<String> = []
    for row in rows {
        let key = "\(row.vid):\(row.pid):\(row.cableVDO):\(row.brand)"
        if !seen.insert(key).inserted {
            let fp = fingerprintLabel(vid: row.vid, pid: row.pid, cableVDO: row.cableVDO)
            return """
                data/known-cables.md has an exact duplicate row for \(fp) '\(row.brand)'. \
                Merge the two rows (keep every issue link in the Source cell) rather than \
                curating the same product twice.
                """
        }
    }
    return nil
}

/// Drops a contact email address from a USB-IF vendor name, keeping the
/// organisation.
///
/// The upstream registry occasionally carries a person's work email in the
/// company field, in the shape `Some Company Inc. , firstname@example.com`. We
/// redistribute that list inside `whatcable.db`, so it ships in the app and on
/// the website. The company name is the useful part and the only part the app
/// displays; the individual's address is not ours to publish.
///
/// Deliberately narrow. It removes an email-shaped token and any comma left
/// stranded in front of it, and nothing else. Vendor names that legitimately
/// contain an `@` are common (`M@inNet Communication`, `@pos.com` are both real
/// entries) and must survive untouched, so this only fires on a token that
/// actually looks like `local@domain.tld`.
func strippingContactEmail(from name: String) -> String {
    guard name.contains("@") else { return name }
    let pattern = #"\s*,?\s*\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return name }
    let range = NSRange(name.startIndex..., in: name)
    let stripped = re.stringByReplacingMatches(in: name, range: range, withTemplate: "")
    let cleaned = stripped
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: ","))
        .trimmingCharacters(in: .whitespaces)
    // Never return an empty name: if the whole field was an address, the
    // original is more useful than nothing and the caller's guard expects
    // non-empty.
    return cleaned.isEmpty ? name : cleaned
}

/// Validates `data/known-cables.md` and fails the build loudly on a data
/// error, before `openDB()` touches anything.
///
/// Three checks, all fatal:
/// - **Brand column provenance text.** The app prints this column verbatim
///   as "Cable identified as `<brand>`", so provenance prose here is read
///   out to users as the cable's name. Two rows once carried corpus
///   working-notes and a beta tester was told his Apple cable was "seen with
///   CalDigit devices (test-kit corpus)". A cable we cannot name is
///   `(needs review)`, not a description of where we found it. Provenance
///   belongs in the Source column.
/// - **Fingerprint inconsistency** (`findFingerprintInconsistency`): two rows
///   sharing a real (VID, PID, Cable VDO) fingerprint must agree on
///   Speed/Power/Type.
/// - **Exact duplicate row** (`findExactDuplicateRow`): the same brand
///   curated twice for the same fingerprint.
///
/// `openDB()` deletes the bundled database before writing a fresh one, so
/// all three checks run here, on the raw markdown text, before that happens.
/// A rejected row stops the build while every generated artifact (the
/// bundled db, the docs copy, the website JSON) is still untouched. This
/// used to be true only of the first check; the other two ran inside
/// `importKnownCables()`, after `openDB()` had already truncated the
/// bundled db to a vendors-only shell, so a failure there left a corrupt
/// `whatcable.db` in the tree. Moved here so a failure anywhere in this
/// function never touches the db at all.
func validateKnownCablesMarkdown() {
    guard let text = try? String(contentsOfFile: knownCablesMD, encoding: .utf8) else { return }

    var inTable = false
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## Table") { inTable = true; continue }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|"), !line.contains("---") else { continue }

        let parts = line.dropFirst().dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 10, parts[1].hasPrefix("`0x") else { continue }

        let brand = parts[0]
        if brand == "(needs review)" { continue }

        for phrase in ["corpus", "seen with", "seen alongside"] where brand.lowercased().contains(phrase) {
            fputs("""
            error: brand column contains provenance text ("\(phrase)"), not a product name:
              \(brand)
              Move it to the Source column, or use (needs review) if the cable can't be named.

            """, stderr)
            exit(1)
        }
    }

    // Same pure parse importKnownCables() uses later, run here purely to
    // feed the two invariant checks before any db write happens. The parsed
    // rows aren't reused for the actual import: importKnownCables() re-reads
    // and re-parses the file itself, same as this function already re-reads
    // it separately from the brand-column check above.
    let parsed = parseCableRowsText(text).rows
    if let message = findFingerprintInconsistency(parsed) {
        fputs("error: \(message)\n", stderr)
        exit(9)
    }
    if let message = findExactDuplicateRow(parsed) {
        fputs("error: \(message)\n", stderr)
        exit(10)
    }
}

/// Self-tests for the known-cables row parser and the two build-time
/// invariants (`findFingerprintInconsistency`, `findExactDuplicateRow`).
/// Each "should fail" case proves the check actually catches the bad
/// fixture, not just that it stays quiet on good data.
private func tableFixture(_ rows: String) -> String {
    """
    ## Table

    | Brand / model context | VID | PID | Cable VDO | Vendor | XID | Speed | Power | Type | Source |
    |---|---|---|---|---|---|---|---|---|---|
    \(rows)

    ## Next section
    """
}

func runKnownCablesParserSelfTests() -> (failures: Int, output: String) {
    var output = "Known-cables row parser self-tests\n"
    output += "===================================\n"
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String, _ detail: String = "") {
        if condition() {
            output += "ok    \(label)\n"
        } else {
            failures += 1
            output += "FAIL  \(label)\n"
            if !detail.isEmpty { output += "  \(detail)\n" }
        }
    }

    // Two brands sharing one (vid, pid, vdo), agreeing on capability: both
    // should parse and both should insert (no inconsistency, no duplicate).
    // This is the #505 shape (Anker Prime + UGREEN on the same ACON silicon).
    do {
        let md = tableFixture("""
            | Anker Prime | `0x0522` | `0x0A33` | `0x110A2644` | ACON | `0x943` | USB4 Gen 4 (80 Gbps, Thunderbolt 5 class) | 5 A / 50 V (240 W) | passive | [#418](url) |
            | UGREEN | `0x0522` | `0x0A33` | `0x110A2644` | ACON | `0x943` | USB4 Gen 4 (80 Gbps, Thunderbolt 5 class) | 5 A / 50 V (240 W) | passive | [#505](url) |
            """)
        let parsed = parseCableRowsText(md)
        check(parsed.rows.count == 2, "two brands sharing one fingerprint: both parsed",
            "got \(parsed.rows.count) rows")
        check(findFingerprintInconsistency(parsed.rows) == nil, "two brands sharing one fingerprint: no inconsistency flagged",
            findFingerprintInconsistency(parsed.rows) ?? "")
        check(findExactDuplicateRow(parsed.rows) == nil, "two brands sharing one fingerprint: no duplicate flagged",
            findExactDuplicateRow(parsed.rows) ?? "")
    }

    // Variant rows: same (vid, pid), different Cable VDO. Both should insert;
    // this is the Chant Sincere 3A/5A shape (#239).
    do {
        let md = tableFixture("""
            | Lenovo 3A | `0x0C62` | `0xC8F1` | `0x00082022` | Chant Sincere | `0x573` | USB 3.2 Gen 2 (10 Gbps) | 3 A / 20 V (60 W) | passive | [#402](url) |
            | Lenovo 5A | `0x0C62` | `0xC8F1` | `0x00082042` | Chant Sincere | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#403](url) |
            """)
        let parsed = parseCableRowsText(md)
        check(parsed.rows.count == 2, "variant rows, different VDO: both parsed",
            "got \(parsed.rows.count) rows")
        check(findFingerprintInconsistency(parsed.rows) == nil, "variant rows, different VDO: no inconsistency flagged (different fingerprints)",
            findFingerprintInconsistency(parsed.rows) ?? "")
        check(findExactDuplicateRow(parsed.rows) == nil, "variant rows, different VDO: no duplicate flagged",
            findExactDuplicateRow(parsed.rows) ?? "")
    }

    // Speed mismatch within the same (vid, pid, vdo): must fail. Proves the
    // check can actually fire, not just pass silently on good data.
    do {
        let md = tableFixture("""
            | Brand A | `0x1234` | `0x0001` | `0x00082042` | Vendor | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#1](url) |
            | Brand B | `0x1234` | `0x0001` | `0x00082042` | Vendor | none | USB4 Gen 3 (40 Gbps, Thunderbolt 4 class) | 5 A / 20 V (100 W) | passive | [#2](url) |
            """)
        let parsed = parseCableRowsText(md)
        let result = findFingerprintInconsistency(parsed.rows)
        check(result != nil, "speed mismatch within one fingerprint: flagged as inconsistent")
        if let result {
            output += "  observed failure: \(result.split(separator: "\n").first ?? "")\n"
        }
    }

    // Exact full-key duplicate (same vid, pid, vdo, AND brand): must fail.
    do {
        let md = tableFixture("""
            | Same Brand | `0x1234` | `0x0002` | `0x00082042` | Vendor | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#3](url) |
            | Same Brand | `0x1234` | `0x0002` | `0x00082042` | Vendor | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#4](url) |
            """)
        let parsed = parseCableRowsText(md)
        let result = findExactDuplicateRow(parsed.rows)
        check(result != nil, "exact full-key duplicate: flagged")
        if let result {
            output += "  observed failure: \(result.split(separator: "\n").first ?? "")\n"
        }
    }

    // Row-count bookkeeping: (needs review) and all-zero rows are excluded
    // from `rows` but counted in totalDataRows/skipped*, so
    // totalDataRows - skippedNeedsReview - skippedAllZero == rows.count.
    do {
        let md = tableFixture("""
            | Real cable | `0x1234` | `0x0003` | `0x00082042` | Vendor | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#5](url) |
            | (needs review) | `0x1234` | `0x0004` | `0x00082042` | Vendor | none | USB 3.2 Gen 2 (10 Gbps) | 5 A / 20 V (100 W) | passive | [#6](url) |
            | All zero | `0x0000` | `0x0000` |  | (zeroed) | none | (none advertised) | (not advertised) | passive | [#7](url) |
            """)
        let parsed = parseCableRowsText(md)
        check(parsed.rows.count == 1, "row-count bookkeeping: only the real cable parses into rows",
            "got \(parsed.rows.count) rows")
        check(parsed.totalDataRows == 3, "row-count bookkeeping: totalDataRows counts every data row",
            "got \(parsed.totalDataRows)")
        check(parsed.skippedNeedsReview == 1 && parsed.skippedAllZero == 1,
            "row-count bookkeeping: skip counts match",
            "needsReview=\(parsed.skippedNeedsReview) allZero=\(parsed.skippedAllZero)")
        check(parsed.rows.count == parsed.totalDataRows - parsed.skippedNeedsReview - parsed.skippedAllZero,
            "row-count bookkeeping: rows.count == totalDataRows - skippedNeedsReview - skippedAllZero")
    }

    output += "\n\(failures == 0 ? "all passed" : "\(failures) FAILED")\n"
    return (failures, output)
}

if CommandLine.arguments.contains("--test-parser") {
    let (vendorFailures, vendorReport) = runManualVendorParserSelfTests()
    let (emailFailures, emailReport) = runContactEmailSelfTests()
    let (cableFailures, cableReport) = runKnownCablesParserSelfTests()
    FileHandle.standardOutput.write(vendorReport.data(using: .utf8) ?? Data())
    FileHandle.standardOutput.write("\ncontact-email stripping:\n".data(using: .utf8) ?? Data())
    FileHandle.standardOutput.write(emailReport.data(using: .utf8) ?? Data())
    FileHandle.standardOutput.write("\n".data(using: .utf8) ?? Data())
    FileHandle.standardOutput.write(cableReport.data(using: .utf8) ?? Data())
    exit((vendorFailures + emailFailures + cableFailures) == 0 ? 0 : 1)
}

func importKnownCables() -> Int {
    guard let text = try? String(contentsOfFile: knownCablesMD, encoding: .utf8) else {
        fputs("warn: could not read \(knownCablesMD), skipping cables\n", stderr)
        return 0
    }

    // Parse all valid markdown rows into a flat list. No merging: each row
    // from the markdown becomes one DB row. The fingerprint index
    // (idx_cables_fingerprint) lets CableDB look up all rows for a given
    // (vid, pid, cable_vdo).
    let (parsed, totalDataRows, skippedNeedsReview, skippedAllZero) = parseCableRowsText(text)

    if skippedNeedsReview > 0 {
        print("warn: skipped \(skippedNeedsReview) row(s) with '(needs review)' brand - hand-edit before next build")
    }
    if skippedAllZero > 0 {
        print("Skipped \(skippedAllZero) all-zero-fingerprint markdown row(s) (cannot identify a cable)")
    }

    // Count shared fingerprints for informational output only.
    var fingerprintCounts: [String: Int] = [:]
    for row in parsed {
        let key = "\(row.vid):\(row.pid):\(row.cableVDO)"
        fingerprintCounts[key, default: 0] += 1
    }
    let sharedCount = fingerprintCounts.values.filter { $0 > 1 }.count
    if sharedCount > 0 {
        print("note: \(sharedCount) fingerprint(s) shared by multiple rows (same OEM cable under different brands, or a capability variant told apart by Cable VDO)")
    }

    // Build-time invariants (fingerprint consistency, exact duplicates)
    // already ran in validateKnownCablesMarkdown(), on the same parse, before
    // openDB() touched anything. Not re-run here: this function runs after
    // the db has already been truncated, so a failure here can no longer
    // stop a bad row before some artifact gets written. Every parsed row is
    // inserted directly; the UNIQUE(vid, pid, cable_vdo, brand) index is a
    // belt-and-braces backstop in case a future code path bypasses the
    // pre-openDB check (see the SQLITE_CONSTRAINT branch below).
    let insertSQL = """
        INSERT INTO cables (vid, pid, cable_vdo, brand, speed, power, type, xid, issue_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for cable insert\n", stderr)
        return 0
    }

    runSQL("BEGIN TRANSACTION")
    var count = 0

    for row in parsed {
        sqlite3_reset(stmt)
        sqlite3_bind_int(stmt, 1, Int32(row.vid))
        sqlite3_bind_int(stmt, 2, Int32(row.pid))
        sqlite3_bind_int(stmt, 3, Int32(bitPattern: UInt32(row.cableVDO)))
        sqlite3_bind_text(stmt, 4, (row.brand as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (row.speed as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (row.power as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (row.type as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (row.xid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (row.issueURL as NSString).utf8String, -1, nil)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_CONSTRAINT {
            // Should be unreachable: findExactDuplicateRow already checked
            // this. If it fires anyway, something upstream disagrees with
            // that check, which is itself a bug worth failing loudly for.
            fputs("error: sqlite rejected cable VID=\(row.vid) PID=\(row.pid) '\(row.brand)' as a duplicate of the UNIQUE(vid, pid, cable_vdo, brand) index, but findExactDuplicateRow did not catch it. This is a bug in the duplicate check.\n", stderr)
            exit(12)
        } else if rc != SQLITE_DONE {
            fputs("warn: failed to insert cable VID=\(row.vid) PID=\(row.pid): \(String(cString: sqlite3_errmsg(db)))\n", stderr)
        } else {
            count += 1
        }
    }

    runSQL("COMMIT")
    sqlite3_finalize(stmt)

    // Row-count assertion: every parsed row must have inserted. totalDataRows
    // is every row the parser looked at, including the ones it skipped
    // ((needs review), all-zero), so this also proves the skip counts are
    // accurate.
    let expected = totalDataRows - skippedNeedsReview - skippedAllZero
    if count != expected {
        fputs("""
            error: cable row-count mismatch: inserted \(count) rows but expected \(expected) \
            (totalDataRows=\(totalDataRows) - skippedNeedsReview=\(skippedNeedsReview) - skippedAllZero=\(skippedAllZero)). \
            A row was silently dropped somewhere between parsing and insert.

            """, stderr)
        exit(13)
    }

    return count
}

// MARK: - JSON export for website search

func exportCablesJSON() -> Int {
    let query = """
        SELECT c.vid, c.pid, c.cable_vdo, c.brand, c.speed, c.power,
               c.type, c.xid, c.issue_url, COALESCE(v.name, '') as vendor_name,
               COALESCE(v.source, '') as vendor_source
        FROM cables c
        LEFT JOIN vendors v ON c.vid = v.vid
        ORDER BY c.vid, c.pid
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for JSON export\n", stderr)
        return 0
    }
    defer { sqlite3_finalize(stmt) }

    var entries: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let vid = Int(sqlite3_column_int(stmt, 0))
        let pid = Int(sqlite3_column_int(stmt, 1))
        let cableVDO = UInt32(bitPattern: sqlite3_column_int(stmt, 2))
        let brand = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let speed = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let power = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let type = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
        let xid = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "none"
        let issueURL = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
        let vendorName = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let vendorSource = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""

        // 0x0000 and 0xFFFF are USB-PD "no vendor identity" sentinels,
        // not vendors. Both happen to sit in the USB-IF list (as "USB
        // Implementers Forum" and a stale "Taiwan OEM" respectively), so
        // a plain vendors-table join badges the most identity-less
        // cables in the catalogue as coming from a registered vendor.
        // VendorDB.name(for:) / .isRegistered already short-circuit both
        // in the app; mirror that here so the website agrees with it.
        let isSentinelVID = (vid == 0 || vid == 0xFFFF)

        let vendor: String
        if vid == 0 {
            vendor = "(zeroed)"
        } else if vid == 0xFFFF {
            vendor = "No vendor ID assigned (USB-PD spec sentinel)"
        } else if vendorName.isEmpty {
            vendor = "Unregistered"
        } else {
            vendor = vendorName
        }

        let vidHex = String(format: "0x%04X", vid)
        let pidHex = String(format: "0x%04X", pid)
        let vdoHex = cableVDO == 0 ? "" : String(format: "0x%08X", cableVDO)

        let issueNum: String
        if let hashIdx = issueURL.lastIndex(of: "/") {
            issueNum = "#" + issueURL[issueURL.index(after: hashIdx)...]
        } else {
            issueNum = ""
        }

        let entry: [String: Any] = [
            "brand": brand,
            "vid": vidHex,
            "pid": pidHex,
            "cableVDO": vdoHex,
            "vendor": vendor,
            "registered": !isSentinelVID && vendorSource == "usbif",
            "xid": xid,
            "speed": speed,
            "power": power,
            "type": type,
            "issueURL": issueURL,
            "issueNum": issueNum,
        ]
        entries.append(entry)
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]
    ) else {
        fputs("warn: JSON serialization failed\n", stderr)
        return 0
    }

    let url = URL(fileURLWithPath: cablesJSON)
    do {
        try data.write(to: url)
    } catch {
        fputs("warn: could not write \(cablesJSON): \(error)\n", stderr)
        return 0
    }

    return entries.count
}

// MARK: - USB-IF certification import

// Two public, unauthenticated USB-IF endpoints (both undocumented Drupal
// routes, hence compiled offline, never called at runtime):
//   - bulk list: the whole certified-products catalogue in one GET. Carries
//     the cert date but NO vendor_id.
//   - per-XID:   one XID's listings, WITH vendor_id but no cert date.
// We union them by XID to get both. See research/usb-if-registry.md.
let usbifBulkURL = URL(string: "https://www.usb.org/vtm-products/v1/all")!
func usbifPerXIDURL(_ xid: Int) -> URL {
    // The XID goes in the path in DECIMAL, not hex.
    URL(string: "https://cms.usb.org/usb_device/get_status_by_xid/\(xid)")!
}

/// Synchronous HTTP GET with a real timeout. `Data(contentsOf:)` has no
/// timeout control, which matters across ~1,000 sequential per-XID calls.
func httpGet(_ url: URL, timeout: TimeInterval = 30) -> Data? {
    let sem = DispatchSemaphore(value: 0)
    // The completion handler runs on URLSession's delegate queue while the
    // caller waits on this thread, so all access to `result` is guarded by a
    // lock. On the (near-never) backstop timeout we cancel the task and read
    // whatever is there under the same lock, so there is no unsynchronised
    // read/write race.
    let lock = NSLock()
    var result: Data?
    var done = false
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        lock.lock()
        if !done {
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            done = true
        }
        lock.unlock()
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
    }
    lock.lock()
    let out = result
    lock.unlock()
    return out
}

/// Minimal HTML-entity unescape. The bulk list HTML-encodes a few
/// characters in text fields (company names with `&amp;`, categories with
/// `&gt;`). Per-XID text is clean JSON, so this only touches bulk fallbacks.
func htmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&#039;", with: "'")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct BulkListing {
    let company: String
    let model: String
    let status: String
    let certDate: String
}

/// Fetch the bulk catalogue and index the XID-bearing rows by XID.
/// Returns nil on fetch/parse failure so the caller can skip cert import
/// without aborting the whole DB build.
func fetchBulkListings() -> [Int: [BulkListing]]? {
    guard let data = httpGet(usbifBulkURL, timeout: 120) else {
        fputs("warn: usb-if bulk list fetch failed\n", stderr)
        return nil
    }
    // The response is a JSON object keyed by stringified index ("0","1",...),
    // not an array.
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        fputs("warn: usb-if bulk list did not parse as a JSON object\n", stderr)
        return nil
    }
    var byXID: [Int: [BulkListing]] = [:]
    for value in dict.values {
        guard let row = value as? [String: Any],
              let xidStr = (row["field_usb_xid"] as? String)?
                .trimmingCharacters(in: .whitespaces),
              let xid = Int(xidStr), xid != 0 else { continue }
        let listing = BulkListing(
            company: htmlUnescape((row["device_company_view_field"] as? String) ?? ""),
            model: htmlUnescape((row["name"] as? String)
                ?? (row["field_usb_model_part_number"] as? String) ?? ""),
            status: htmlUnescape((row["field_device_status"] as? String) ?? ""),
            certDate: (row["global_pass_date"] as? String) ?? ""
        )
        byXID[xid, default: []].append(listing)
    }
    // Guard against a 200 response that is an error object, an empty object,
    // or a changed schema: any of those parse as a dictionary but yield few or
    // no XID rows. Real data is ~1,086 distinct XIDs. Treat an implausibly
    // small result as a failed fetch so cert import is skipped loudly (0
    // listings in the summary) rather than silently compiling a truncated
    // table that could get committed.
    if byXID.count < 500 {
        fputs("warn: usb-if bulk list returned only \(byXID.count) XID rows; treating as a failed or changed response and skipping cert import\n", stderr)
        return nil
    }
    return byXID
}

/// Fetch one XID's listings from the per-XID endpoint, caching the raw
/// response to disk. An empty array is a valid "not registered" result and
/// is cached too, so it is not re-fetched. Returns the parsed array (possibly
/// empty), or nil only when the network fetch itself failed.
func fetchPerXIDListings(_ xid: Int) -> [[String: Any]]? {
    let cachePath = "\(certCacheDir)/\(xid).json"
    let fm = FileManager.default
    if !refreshCerts,
       let cached = fm.contents(atPath: cachePath),
       let arr = (try? JSONSerialization.jsonObject(with: cached)) as? [[String: Any]] {
        return arr
    }
    // Be polite to USB-IF's undocumented per-XID endpoint: throttle to ~2
    // requests a second, but only on an actual network fetch (a warm cache
    // does no network and does not sleep). Matches the rate the research doc
    // describes for the one-time full fetch.
    Thread.sleep(forTimeInterval: 0.5)
    guard let data = httpGet(usbifPerXIDURL(xid)) else { return nil }
    // Validate it parses as an array before caching; a non-array response
    // is a transient error, not a "not registered" answer.
    guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return nil
    }
    try? data.write(to: URL(fileURLWithPath: cachePath))
    return arr
}

/// Read the distinct XIDs already recorded on curated cables (hex strings
/// like "0x5F5" in the cables table). Seeding the universe with these catches
/// registered XIDs the bulk catalogue omits (verified: the bulk list misses
/// some, e.g. the Anker sample 0x219C).
func curatedXIDs() -> Set<Int> {
    var out: Set<Int> = []
    var stmt: OpaquePointer?
    let sql = "SELECT DISTINCT xid FROM cables WHERE xid NOT IN ('none', '')"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let c = sqlite3_column_text(stmt, 0) else { continue }
        var s = String(cString: c)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        if let v = Int(s, radix: 16) { out.insert(v) }
    }
    return out
}

/// Read the distinct non-zero Cert Stat XIDs that real cables reported in the
/// probe corpus (`research/customer-probes/*/01_walk_pd_tree.json`).
///
/// Same motivation as `curatedXIDs()`, one step wider: the bulk catalogue is
/// NOT a superset of the per-XID endpoint. Measured on 2026-07-24, 41 distinct
/// corpus XIDs resolved to nothing in the compiled table, and 11 of them
/// returned real listings from the per-XID endpoint (Anker x4, Belkin,
/// Plugable, ZAGG, Richtek, Hynetek, Sunlike, SIP Simya). Those cables are
/// certified and were showing no certification line purely because the build
/// never asked about their XID.
///
/// Fails soft on purpose. `research/` is excluded from the public mirror while
/// this script is not, so a rebuild from the public repo finds no corpus
/// directory and simply gets the old (bulk + curated) universe.
func corpusXIDs() -> Set<Int> {
    let corpusRoot = "\(repoRoot)/research/customer-probes"
    guard let folders = try? FileManager.default.contentsOfDirectory(
        atPath: corpusRoot
    ) else {
        print("USB-IF certs: no probe corpus at research/customer-probes, " +
              "skipping corpus XID seeding")
        return []
    }

    var out: Set<Int> = []
    for folder in folders {
        let probe = "\(corpusRoot)/\(folder)/01_walk_pd_tree.json"
        guard let data = FileManager.default.contents(atPath: probe),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let text = obj["output"] as? String else { continue }

        // Probe 01 prints one "=== ClassName[n] ===" block per registry node.
        // Keep the blocks whose own Description ends in "/SOP'" (the cable
        // plug's e-marker) and read VDO[1], the Cert Stat XID.
        for block in text.components(separatedBy: "=== ") {
            // Both cable-plug addresses, matching what the app itself reads:
            // `USBPDSOP.certStatVDO` accepts .sopPrime and .sopDoublePrime.
            // No SOP'' block exists in the corpus today, so this changes
            // nothing now; it stops the seeder drifting from the app the day
            // a dual-e-marker cable turns up.
            guard let desc = blockDescription(block),
                  desc.hasSuffix("/SOP'") || desc.hasSuffix("/SOP''"),
                  let xid = blockCertStatXID(block), xid != 0 else { continue }
            out.insert(xid)
        }
    }
    return out
}

/// The first `Description = "..."` value on its own line within a probe block.
/// Requires the closing quote rather than blindly dropping the last character,
/// so a truncated line can't have its final character eaten and turn into a
/// value that matches something (`.../SOP'X` becoming `.../SOP'`).
func blockDescription(_ block: String) -> String? {
    let prefix = "Description = \""
    for line in block.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(prefix), t.hasSuffix("\""), t.count > prefix.count else { continue }
        return String(t.dropFirst(prefix.count).dropLast())
    }
    return nil
}

/// VDO[1] as a little-endian UInt32, mirroring `PDVDO.vdoFromData`'s byte
/// order (the app decodes the same bytes the same way).
///
/// Every token must be valid hex. Dropping unparseable tokens instead would
/// let a corrupt line still yield four bytes from the survivors and decode to
/// a plausible but wrong XID, which we would then fetch and store.
func blockCertStatXID(_ block: String) -> Int? {
    guard let range = block.range(of: "[1] <data 4 bytes: ") else { return nil }
    let after = block[range.upperBound...]
    guard let end = after.firstIndex(of: ">") else { return nil }
    let tokens = after[..<end].split(separator: " ")
    guard tokens.count == 4 else { return nil }
    var value = 0
    for (i, token) in tokens.enumerated() {
        guard let byte = UInt8(token, radix: 16) else { return nil }
        value |= Int(byte) << (8 * i)
    }
    return value
}

func importCertifications() -> (xids: Int, listings: Int) {
    try? FileManager.default.createDirectory(
        atPath: certCacheDir, withIntermediateDirectories: true)

    guard let bulk = fetchBulkListings() else {
        fputs("warn: skipping certification import (bulk fetch failed)\n", stderr)
        return (0, 0)
    }

    // Universe = every XID the catalogue lists, plus every XID our curated
    // cables carry, plus every XID real hardware reported in the probe corpus.
    // Sorted so progress logging and cache order are stable.
    let curated = curatedXIDs()
    let corpus = corpusXIDs()
    let universe = Set(bulk.keys).union(curated).union(corpus).sorted()
    print("USB-IF certs: \(universe.count) XIDs to resolve " +
          "(\(bulk.count) from bulk list, \(curated.count) from curated cables, " +
          "\(corpus.count) from the probe corpus)")

    let insertSQL = """
        INSERT INTO cable_certs (xid, vendor_id, company, model, status, cert_date, source)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fputs("warn: prepare failed for cable_certs insert\n", stderr)
        return (0, 0)
    }
    defer { sqlite3_finalize(stmt) }

    // SQLite keeps a pointer to bound text until the statement is stepped;
    // SQLITE_TRANSIENT tells it to copy immediately so our Swift strings can
    // go out of scope safely.
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    func bindText(_ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    /// Best cert date for a listing, matched conservatively against the bulk
    /// rows for this XID. Prefer an exact company+model match. Otherwise fall
    /// back to a company-only match ONLY when exactly one bulk row has that
    /// company; if several models share the company, we cannot tell which
    /// date belongs to this listing, so return empty rather than guess (an
    /// XID with several unrelated companies must never borrow another's date).
    func certDate(forXID xid: Int, company: String, model: String) -> String {
        let rows = bulk[xid] ?? []
        if let exact = rows.first(where: {
            $0.company.caseInsensitiveCompare(company) == .orderedSame
                && $0.model.caseInsensitiveCompare(model) == .orderedSame
        }) { return exact.certDate }
        let sameCompany = rows.filter {
            $0.company.caseInsensitiveCompare(company) == .orderedSame
        }
        return sameCompany.count == 1 ? sameCompany[0].certDate : ""
    }

    var xidsCovered = 0
    var listingsInserted = 0
    var fetchFailures = 0

    for (i, xid) in universe.enumerated() {
        if i > 0 && i % 100 == 0 {
            print("  ...\(i)/\(universe.count) XIDs resolved")
        }
        let perXID = fetchPerXIDListings(xid)
        if perXID == nil { fetchFailures += 1 }

        // Authoritative first: per-XID rows carry vendor_id. A row is only
        // usable if it has a non-empty company (an empty company would render
        // as a bogus "USB-IF certified. Manufacturer:" line, and signals a
        // garbage / schema-changed response). If a per-XID response yields no
        // usable row, we fall THROUGH to the bulk data via the single
        // if/else chain below, rather than trusting a malformed response.
        var insertedFromPerXID = false
        if let listings = perXID {
            for row in listings {
                let company = ((row["company"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                guard !company.isEmpty else { continue }
                let model = ((row["model_number"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                let status = ((row["status"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                let vid = (row["vendor_id"] as? String).flatMap { Int($0) }
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(xid))
                // Int32(exactly:) so a malformed out-of-range vendor_id binds
                // NULL (vendor unknown) instead of trapping the whole build.
                if let vid, let v32 = Int32(exactly: vid) { sqlite3_bind_int(stmt, 2, v32) }
                else { sqlite3_bind_null(stmt, 2) }
                bindText(3, company)
                bindText(4, model)
                bindText(5, status)
                bindText(6, certDate(forXID: xid, company: company, model: model))
                bindText(7, "per_xid")
                if sqlite3_step(stmt) == SQLITE_DONE {
                    listingsInserted += 1
                    insertedFromPerXID = true
                }
            }
        }

        if insertedFromPerXID {
            xidsCovered += 1
        } else if let bulkRows = bulk[xid] {
            // Fallback: per-XID gave nothing usable, or the catalogue lists
            // this XID only in the bulk source. No vendor_id here. Same
            // non-empty-company guard so no bogus row reaches the db.
            var any = false
            for b in bulkRows {
                guard !b.company.isEmpty else { continue }
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(xid))
                sqlite3_bind_null(stmt, 2)
                bindText(3, b.company)
                bindText(4, b.model)
                bindText(5, b.status)
                bindText(6, b.certDate)
                bindText(7, "bulk")
                if sqlite3_step(stmt) == SQLITE_DONE { listingsInserted += 1; any = true }
            }
            if any { xidsCovered += 1 }
        }
        // else: a curated XID that resolves nowhere -> genuinely unregistered.
    }

    if fetchFailures > 0 {
        fputs("warn: \(fetchFailures) per-XID fetches failed (left uncovered)\n", stderr)
    }
    return (xidsCovered, listingsInserted)
}

// MARK: - Main

// Validate the markdown before openDB() touches anything: openDB() deletes
// the bundled database, so a rejected row must fail the build while every
// generated artifact is still intact.
validateKnownCablesMarkdown()

openDB()
createSchema()

let vendorCount = importUSBIFVendors()
print("Imported \(vendorCount) USB-IF vendors")

let usbids = importUSBIDsVendors()
print("usb.ids: \(usbids.inserted) new vendors added, \(usbids.skipped) already in USB-IF list")

let manual = importManualVendors()
print("manual-vendors: \(manual.inserted) added, \(manual.skipped) skipped (already in USB-IF or usb.ids)")

let cableCount = importKnownCables()
print("Imported \(cableCount) known cables")

let certs = importCertifications()
print("USB-IF certs: \(certs.listings) listings across \(certs.xids) XIDs")

// Guard against silently shipping a cert-less db. With the per-XID -> bulk
// fallback and the bulk floor, zero listings can only mean the bulk fetch
// itself failed (a network outage), not a partial per-XID failure. Fail the
// build loudly at the end (after the db is written, so the message about
// restoring it is accurate), unless a cert-less build was asked for.
// A deliberate cert-less build requires ALLOW_EMPTY_CERTS set to a NON-empty
// value; an unset or empty var does not count as the override.
let allowEmptyCerts = !(ProcessInfo.processInfo.environment["ALLOW_EMPTY_CERTS"] ?? "").isEmpty
let certsCollapsed = certs.listings == 0 && !allowEmptyCerts

// Speed/Power/Type consistency and exact-duplicate checks already ran inside
// importKnownCables(), before any row was inserted (see
// findFingerprintInconsistency / findExactDuplicateRow): a violation exits
// the build there rather than reaching this point.

// Summary: total rows, unique fingerprints, shared fingerprints.
var totalRows = 0
var uniqueFingerprints = 0
var sharedFingerprints = 0
let summaryQuery = """
    SELECT COUNT(*) as total,
           COUNT(DISTINCT vid || ':' || pid || ':' || cable_vdo) as unique_fps
    FROM cables
    """
let sharedQuery = """
    SELECT COUNT(*) FROM (
        SELECT vid, pid, cable_vdo FROM cables
        GROUP BY vid, pid, cable_vdo
        HAVING COUNT(*) > 1
    )
    """
var sumStmt: OpaquePointer?
if sqlite3_prepare_v2(db, summaryQuery, -1, &sumStmt, nil) == SQLITE_OK {
    if sqlite3_step(sumStmt) == SQLITE_ROW {
        totalRows = Int(sqlite3_column_int(sumStmt, 0))
        uniqueFingerprints = Int(sqlite3_column_int(sumStmt, 1))
    }
    sqlite3_finalize(sumStmt)
}
var sharedStmt: OpaquePointer?
if sqlite3_prepare_v2(db, sharedQuery, -1, &sharedStmt, nil) == SQLITE_OK {
    if sqlite3_step(sharedStmt) == SQLITE_ROW {
        sharedFingerprints = Int(sqlite3_column_int(sharedStmt, 0))
    }
    sqlite3_finalize(sharedStmt)
}
print("Cable DB summary: \(totalRows) total rows, \(uniqueFingerprints) unique fingerprints, \(sharedFingerprints) shared fingerprints")

let jsonCount = exportCablesJSON()
print("Exported \(jsonCount) cables to \(cablesJSON)")

/// Runs a command and returns its trimmed stdout, or nil if it fails to launch
/// or exits non-zero.
func runCapturing(_ launchPath: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let out = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? nil : out
}

/// When the curated cable list was last actually changed.
///
/// Uncommitted edits count as "now", because the export we just wrote includes
/// them. Otherwise it is the commit date of the last change to the markdown,
/// which is the honest answer and does not move when nothing changed. Falls
/// back to the file's mtime outside a git checkout.
func lastCableDataChange() -> String {
    let git = "/usr/bin/git"
    let dirty = runCapturing(git, ["status", "--porcelain", "--", manualCablesMD])
    if dirty == nil, let committed = runCapturing(git, ["log", "-1", "--format=%cI", "--", manualCablesMD]) {
        return committed
    }
    if dirty != nil {
        // Working-tree edits are in this export, so stamp it now.
        return ISO8601DateFormatter().string(from: Date())
    }
    let mtime = (try? FileManager.default.attributesOfItem(atPath: manualCablesMD)[.modificationDate]) as? Date
    return ISO8601DateFormatter().string(from: mtime ?? Date())
}

do {
    let updated = lastCableDataChange()
    let payload = ["updated": updated]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: cablesUpdatedJSON, atomically: true, encoding: .utf8)
    print("Cable data last changed \(updated) -> \(cablesUpdatedJSON)")
} catch {
    fputs("warn: could not write \(cablesUpdatedJSON): \(error)\n", stderr)
}

// Copy to docs/ for the website.
closeDB()

do {
    let fm = FileManager.default
    if fm.fileExists(atPath: dbWebCopy) {
        try fm.removeItem(atPath: dbWebCopy)
    }
    try fm.copyItem(atPath: dbOutput, toPath: dbWebCopy)
    print("Copied to \(dbWebCopy)")
} catch {
    fputs("warn: could not copy to docs/: \(error)\n", stderr)
}

print("Done: \(dbOutput)")

if certsCollapsed {
    fputs("""
        error: the certification table is EMPTY (0 listings). The USB-IF bulk
        endpoint was most likely unreachable or changed during this build, so
        both bundled databases now have NO cable certifications. Restore them
        and re-run when the network is available:
          git checkout -- Sources/WhatCableCore/Resources/whatcable.db docs/whatcable.db
        Or set ALLOW_EMPTY_CERTS=1 to build deliberately without certifications.

        """, stderr)
    exit(5)
}
