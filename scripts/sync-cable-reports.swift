#!/usr/bin/env swift

// Sync data/known-cables.md from closed `cable-report` issues.
//
// Incremental by design: it lists closed `cable-report` issues via `gh`,
// then APPENDS a row only for cables not already in the table. Existing rows
// keep their hand-edited context and ordering; only their speed cell is
// canonicalized when a Raw Cable VDO value is present in the table.
//
// A report is skipped when either its issue number is already recorded, or
// its cable fingerprint (VID + PID + Cable VDO, the same key the database
// uses) already appears in the table. The fingerprint check means a cable
// re-reported under a new issue number (a duplicate) is not added again.
//
// New rows are appended at the end with "(needs review)" in the Brand /
// model context column, so you know to fill them in by hand.
//
// Run from the repo root:
//   swift scripts/sync-cable-reports.swift
//
// Then re-run scripts/render-known-cables.swift to update docs/cables.html.
//
// Requires:
//   - `gh` CLI authenticated for the repo
//   - Sources/WhatCableCore/Resources/usbif-vendors.tsv

import Foundation

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let mdURL = URL(fileURLWithPath: "\(repoRoot)/data/known-cables.md")
let vendorTSVURL = URL(fileURLWithPath: "\(repoRoot)/Sources/WhatCableCore/Resources/usbif-vendors.tsv")
let needsReview = "(needs review)"

// MARK: - Vendor TSV

func loadVendors() -> [Int: String] {
    guard let text = try? String(contentsOf: vendorTSVURL, encoding: .utf8) else {
        fputs("error: could not read \(vendorTSVURL.path)\n", stderr)
        exit(2)
    }
    var out: [Int: String] = [:]
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("#") || line.isEmpty { continue }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2, let vid = Int(parts[0]) else { continue }
        out[vid] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    return out
}

// MARK: - gh

func runGh() -> [[String: Any]] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [
        "gh", "issue", "list",
        "--repo", "darrylmorley/whatcable",
        "--label", "cable-report",
        "--state", "closed",
        "--json", "number,body,title",
        "--limit", "200",
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr
    do { try proc.run() } catch {
        fputs("error: could not run gh: \(error)\n", Darwin.stderr)
        exit(3)
    }
    // Drain both pipes BEFORE waitUntilExit. gh's JSON output for the full
    // closed-issue list now exceeds the OS pipe buffer (~64KB). If we wait
    // for exit before reading, gh blocks trying to write into a full pipe
    // and never exits, deadlocking the script. readDataToEndOfFile drains
    // the pipe as gh fills it, so gh can finish and close the descriptor.
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8) ?? ""
        fputs("error: gh exited \(proc.terminationStatus): \(err)\n", Darwin.stderr)
        exit(4)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        fputs("error: could not parse gh JSON output\n", Darwin.stderr)
        exit(5)
    }
    return json
}

// MARK: - Body parsing

struct Report {
    let issueNumber: Int
    let vid: Int           // 0 for zeroed
    let pid: Int           // 0 for zeroed
    let cableVDO: UInt32?  // VDO[3] from Raw VDOs table, nil if absent or invalid
    let xidCol: String     // "none" or formatted hex
    let speed: String      // empty for missing
    let power: String      // empty for missing
    let type: String       // "passive" / "active" / etc; empty for missing
}

/// Find the value cell of a "| <field> | <value> |" row.
func extractField(_ field: String, from body: String) -> String? {
    for raw in body.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|") else { continue }
        var trimmed = line
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { continue }
        if parts[0] == field { return parts[1] }
    }
    return nil
}

/// Pull `0xABCD` out of a string. Returns the integer value or nil.
func extractHex(_ s: String) -> Int? {
    let re = try! NSRegularExpression(pattern: "0x([0-9A-Fa-f]+)")
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 2 else { return nil }
    guard let r = Range(m.range(at: 1), in: s) else { return nil }
    return Int(String(s[r]), radix: 16)
}

/// Strictly parse a Cable VDO *cell* (optionally wrapped in backticks and
/// whitespace). Unlike `extractHex`, which matches a `0x…` prefix anywhere in
/// a string, this requires the WHOLE trimmed cell to be `0x` + 1...8 hex
/// digits within UInt32. A cell like `` `0x00000003oops` `` is therefore
/// treated as no evidence, not silently accepted as 0x00000003. This is what
/// lets the "malformed VDOs are left byte-for-byte unchanged" guarantee hold
/// for both report ingest and existing-row normalization.
func strictCableVDO(from cell: String) -> UInt32? {
    let trimmed = cell.trimmingCharacters(in: CharacterSet(charactersIn: " `\t"))
    let re = try! NSRegularExpression(pattern: "^0[xX]([0-9A-Fa-f]{1,8})$")
    let range = NSRange(trimmed.startIndex..., in: trimmed)
    guard let m = re.firstMatch(in: trimmed, range: range),
          let r = Range(m.range(at: 1), in: trimmed),
          let val = UInt64(String(trimmed[r]), radix: 16) else { return nil }
    return UInt32(exactly: val)
}

/// Extract VDO[3] (Cable VDO) from the "Raw VDOs" table in the issue body.
/// Returns nil if the table/value is missing, malformed, or outside UInt32.
func extractCableVDO(from body: String) -> UInt32? {
    let lines = body.components(separatedBy: "\n")
    var inVDOTable = false
    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.contains("Raw VDOs") { inVDOTable = true; continue }
        if inVDOTable, line.hasPrefix("|"), !line.contains("---"), !line.contains("Index") {
            var tableRow = line
            tableRow.removeFirst()
            if tableRow.hasSuffix("|") { tableRow.removeLast() }
            let parts = tableRow.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            if let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)), idx == 3 {
                return strictCableVDO(from: parts[2])
            }
        }
        if inVDOTable, line.hasPrefix("###"), !line.contains("Raw VDOs") { break }
    }
    return nil
}

let canonicalCableSpeedLabels: [Int: String] = [
    0: "USB 2.0 (480 Mbps)",
    1: "USB 3.2 Gen 1 (5 Gbps)",
    2: "USB 3.2 Gen 2 (10 Gbps)",
    3: "USB4 Gen 3 (40 Gbps, Thunderbolt 4 class)",
    4: "USB4 Gen 4 (80 Gbps, Thunderbolt 5 class)",
]

/// Derive a canonical report speed from Cable VDO bits 2...0. Reserved
/// encodings 5...7 return the stable "Reserved cable speed encoding (N)"
/// string, matching the app's `USBPDVDO.CableVDO.reportSpeedLabel` (the
/// source of truth for the exact wording). N is the masked 3-bit value, not
/// the raw VDO, so the two paths agree byte-for-byte. Only a nil VDO (missing
/// or malformed evidence) returns nil so the caller preserves report text.
func canonicalCableSpeed(from cableVDO: UInt32?) -> String? {
    guard let cableVDO else { return nil }
    let bits = Int(cableVDO & 0b111)
    return canonicalCableSpeedLabels[bits] ?? "Reserved cable speed encoding (\(bits))"
}

func resolvedCableSpeed(fallback: String, cableVDO: UInt32?) -> String {
    canonicalCableSpeed(from: cableVDO) ?? fallback
}

func parse(body: String, issueNumber: Int) -> Report? {
    guard let vidCell = extractField("Vendor ID", from: body),
          let vid = extractHex(vidCell) else {
        fputs("warn: issue #\(issueNumber): no Vendor ID, skipping\n", Darwin.stderr)
        return nil
    }
    let pid = extractField("Product ID", from: body).flatMap { extractHex($0) } ?? 0
    let cableVDO = extractCableVDO(from: body)

    // XID: "USB-IF certification ID" cell. May be missing entirely on
    // older reports. May contain "none (XID = 0)" or a hex value.
    let xidCol: String
    if let xidCell = extractField("USB-IF certification ID", from: body) {
        if xidCell.lowercased().contains("none") || xidCell.contains("XID = 0") {
            xidCol = "none"
        } else if let xid = extractHex(xidCell), xid != 0 {
            xidCol = String(format: "`0x%X`", xid)
        } else {
            xidCol = "none"
        }
    } else {
        xidCol = "none"
    }

    // Cable speed / current rating / type are plain text in the template.
    // Strip backticks if present, leave wording verbatim.
    func stripCode(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
    }

    let fallbackSpeed = extractField("Cable speed", from: body).map(stripCode) ?? ""
    let speed = resolvedCableSpeed(fallback: fallbackSpeed, cableVDO: cableVDO)
    let power = extractField("Current rating", from: body).map(humanisePower) ?? ""
    let type = extractField("Type", from: body).map(stripCode) ?? ""

    return Report(
        issueNumber: issueNumber,
        vid: vid,
        pid: pid,
        cableVDO: cableVDO,
        xidCol: xidCol,
        speed: speed,
        power: power,
        type: type
    )
}

/// Reformat "5 A at up to 20V (~100W)" as "5 A / 20 V (100 W)" to match
/// the existing table convention. Falls back to the raw string if it
/// doesn't match.
///
/// The wattage is recomputed from amps and volts rather than copied from
/// the issue body, with the voltage clamped to 48 V first. USB-PD never
/// delivers above 48 V (the fixed EPR power levels top out at 48 V and EPR
/// adjustable voltage caps there too), so a 50 V e-marker rating is
/// insulation headroom, not a delivery voltage. Older app versions filed
/// reports that multiplied 50 V x 5 A into 250 W, a figure no cable can
/// carry; clamping here corrects those at the source so a re-sync can't
/// reintroduce them. Mirrors the clamp in PDVDO.decodeCableVDO.
func humanisePower(_ raw: String) -> String {
    let re = try! NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*A\\s+at\\s+up\\s+to\\s+(\\d+(?:\\.\\d+)?)\\s*V\\s*\\(~?(\\d+(?:\\.\\d+)?)\\s*W\\)",
        options: [.caseInsensitive]
    )
    let range = NSRange(raw.startIndex..., in: raw)
    guard let m = re.firstMatch(in: raw, range: range), m.numberOfRanges >= 4,
          let amps = Range(m.range(at: 1), in: raw),
          let volts = Range(m.range(at: 2), in: raw),
          Range(m.range(at: 3), in: raw) != nil,
          let ampsVal = Double(raw[amps]),
          let voltsVal = Double(raw[volts])
    else {
        return raw
    }
    let deliverableVolts = min(voltsVal, 48)
    let watts = Int((deliverableVolts * ampsVal).rounded())
    return "\(raw[amps]) A / \(raw[volts]) V (\(watts) W)"
}

// MARK: - Existing-row extraction

/// Cable identity key: VID + PID + Cable VDO. Mirrors the database's
/// `(vid, pid, cable_vdo)` primary key, so "already in the table" means the
/// same thing here as it does in whatcable.db.
func fingerprintKey(vid: Int, pid: Int, vdo: UInt32) -> String {
    "\(vid):\(pid):\(vdo)"
}

/// Walk the existing data/known-cables.md table once and collect what we
/// already have: the set of issue numbers recorded, the set of cable
/// fingerprints present, and which brand curates each fingerprint. A report
/// matching either the issue set or the fingerprint set is skipped, so a
/// re-sync only appends genuinely new cables and never rewrites existing
/// rows. The brand map lets the caller print a useful note instead of a bare
/// skip when a fingerprint match might actually be a rebrand (#505: the same
/// OEM cable sold under a different sleeve brand) rather than a true
/// re-report of a cable already in the table.
func loadExisting() -> (issues: Set<Int>, fingerprints: Set<String>, brandByFingerprint: [String: String]) {
    guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return ([], [], [:]) }
    let lines = md.components(separatedBy: "\n")
    var issues: Set<Int> = []
    var fingerprints: Set<String> = []
    var brandByFingerprint: [String: String] = [:]

    var inTable = false
    for line in lines {
        if line.hasPrefix("## Table") { inTable = true; continue }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|"), !line.contains("---") else { continue }
        let parts = line.dropFirst().dropLast().components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Data rows have a code span like `0xABCD` in column 1 (the VID).
        // Header row has plain text "VID" there. We use that as the
        // discriminator so we skip the header without a name match.
        // Column count is 10 (context | VID | PID | VDO | vendor | xid |
        // speed | power | type | source) or 9 (legacy rows without the VDO
        // column). On legacy rows column 3 is the vendor name, which has no
        // 0x literal, so the VDO reads as 0, matching renderRow's empty cell.
        guard parts.count >= 9, parts[1].hasPrefix("`0x") else { continue }
        let vid = extractHex(parts[1]) ?? 0
        let pid = extractHex(parts[2]) ?? 0
        let vdo: UInt32 = parts.count >= 10 ? UInt32(extractHex(parts[3]) ?? 0) : 0
        let key = fingerprintKey(vid: vid, pid: pid, vdo: vdo)
        fingerprints.insert(key)
        // First row for a fingerprint wins the brand shown in the note; a
        // fingerprint legitimately shared by two brands (#505) still gets a
        // useful (if not exhaustive) hint rather than nothing.
        if brandByFingerprint[key] == nil {
            brandByFingerprint[key] = parts[0]
        }
        let source = parts[parts.count - 1]
        // Source cell is "[#NN](url)", possibly several of them on a merged
        // row (e.g. "[#89](url), [#90](url), [#211](url), [#243](url),
        // [#254](url)" for the merged CalDigit row). Enumerate every match,
        // not just the first: a merged row's later issue numbers must also
        // count as "already recorded", or every future sync prints a
        // spurious "possible rebrand" note for them.
        let re = try! NSRegularExpression(pattern: "#(\\d+)")
        let range = NSRange(source.startIndex..., in: source)
        for m in re.matches(in: source, range: range) {
            guard m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: source),
                  let n = Int(String(source[r])) else { continue }
            issues.insert(n)
        }
    }
    return (issues, fingerprints, brandByFingerprint)
}

// MARK: - Row rendering

func renderRow(_ report: Report, context: String, vendors: [Int: String]) -> String {
    let vidCol = String(format: "`0x%04X`", report.vid)
    let pidCol = String(format: "`0x%04X`", report.pid)
    let vdoCol = report.cableVDO.map { String(format: "`0x%08X`", $0) } ?? ""
    let vendor: String
    if report.vid == 0 {
        vendor = "(zeroed)"
    } else if report.vid == 0xFFFF {
        // 0xFFFF is the USB-PD "no vendor ID assigned" sentinel, not a
        // real vendor. The community usb.ids list carries a stale entry
        // at this VID ("Taiwan OEM"), so without this branch the table
        // would attribute a sentinel cable to a vendor that never made
        // it. Mirrors VendorDB.name(for:), which the app already does.
        vendor = "No vendor ID assigned (USB-PD spec sentinel)"
    } else if let name = vendors[report.vid] {
        vendor = name
    } else {
        vendor = "Unregistered"
    }
    let speed = report.speed.isEmpty ? "(none advertised)" : report.speed
    let power = report.power.isEmpty ? "(not advertised)" : report.power
    let type = report.type.isEmpty ? "passive" : report.type
    let source = "[#\(report.issueNumber)](https://github.com/darrylmorley/whatcable/issues/\(report.issueNumber))"
    return "| \(context) | \(vidCol) | \(pidCol) | \(vdoCol) | \(vendor) | \(report.xidCol) | \(speed) | \(power) | \(type) | \(source) |"
}

// MARK: - Existing-row speed normalization

/// Return a copy of the Markdown with only speed cells backed by a usable
/// Cable VDO canonicalized. This includes reserved speed encodings (bits
/// 5-7), which canonicalize to the stable "Reserved cable speed encoding (N)"
/// label. Rows without VDO evidence and malformed VDOs are byte-for-byte
/// unchanged.
func normalizingExistingSpeeds(in markdown: String) -> (markdown: String, count: Int) {
    var lines = markdown.components(separatedBy: "\n")
    var inTable = false
    var changed = 0

    for index in lines.indices {
        let line = lines[index]
        if line.hasPrefix("## Table") {
            inTable = true
            continue
        }
        if inTable, line.hasPrefix("## ") { break }
        guard inTable, line.hasPrefix("|") else { continue }

        var cells = line.components(separatedBy: "|")
        // Leading/trailing pipes produce 12 cells for the 10-column table.
        guard cells.count == 12,
              let cableVDO = strictCableVDO(from: cells[4]),
              let canonical = canonicalCableSpeed(from: cableVDO)
        else { continue }

        let current = cells[7].trimmingCharacters(in: .whitespaces)
        guard current != canonical else { continue }
        cells[7] = " \(canonical) "
        lines[index] = cells.joined(separator: "|")
        changed += 1
    }

    return (lines.joined(separator: "\n"), changed)
}

func normalizeExistingSpeeds() -> Int {
    guard let markdown = try? String(contentsOf: mdURL, encoding: .utf8) else {
        fputs("error: could not read \(mdURL.path)\n", Darwin.stderr)
        exit(6)
    }
    let result = normalizingExistingSpeeds(in: markdown)
    guard result.count > 0 else { return 0 }
    do {
        try result.markdown.write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        fputs("error: could not write \(mdURL.path): \(error)\n", Darwin.stderr)
        exit(8)
    }
    return result.count
}

// MARK: - Speed derivation self-tests

func runSpeedSelfTests() -> Int {
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", Darwin.stderr)
        }
    }

    func reportBody(vdo: String?, fallback: String, trailingVDOPipe: Bool = true) -> String {
        var body = """
        | Field | Value |
        |---|---|
        | Vendor ID | `0x1234` |
        | Product ID | `0x5678` |
        | Cable speed | \(fallback) |
        """
        if let vdo {
            let vdoRow = trailingVDOPipe
                ? "| 3 | Cable | `\(vdo)` |"
                : "| 3 | Cable | `\(vdo)`"
            body += """

            ### Raw VDOs

            | Index | Role | Value |
            |---|---|---|
            \(vdoRow)
            """
        }
        return body
    }

    for bits in 0...4 {
        let body = reportBody(vdo: String(format: "0x%08X", bits), fallback: "localized fallback")
        let report = parse(body: body, issueNumber: bits)
        check(report?.cableVDO == UInt32(bits), "speed bits \(bits) should preserve Raw Cable VDO evidence")
        check(report?.speed == canonicalCableSpeedLabels[bits], "speed bits \(bits) should map to the canonical label")
    }

    let noTrailingPipe = parse(
        body: reportBody(vdo: "0x00000004", fallback: "must not be used", trailingVDOPipe: false),
        issueNumber: 9
    )
    check(
        noTrailingPipe?.cableVDO == 4,
        "Raw Cable VDO rows without a trailing pipe should preserve the full value"
    )
    check(
        noTrailingPipe?.speed == canonicalCableSpeedLabels[4],
        "Raw Cable VDO rows without a trailing pipe should derive the canonical speed"
    )

    let missing = parse(body: reportBody(vdo: nil, fallback: "legacy localized speed"), issueNumber: 10)
    check(missing?.cableVDO == nil, "missing Raw Cable VDO should remain absent")
    check(missing?.speed == "legacy localized speed", "missing Raw Cable VDO should use report text")

    let malformed = parse(body: reportBody(vdo: "not-hex", fallback: "malformed fallback"), issueNumber: 11)
    check(malformed?.cableVDO == nil, "malformed Raw Cable VDO should not parse")
    check(malformed?.speed == "malformed fallback", "malformed Raw Cable VDO should use report text")

    // A hex prefix with trailing garbage must be rejected as evidence, not
    // silently truncated to the leading valid hex (would misreport speed).
    let trailingGarbage = parse(
        body: reportBody(vdo: "0x00000003oops", fallback: "trailing garbage fallback"),
        issueNumber: 12
    )
    check(trailingGarbage?.cableVDO == nil, "Raw Cable VDO with trailing garbage should not parse")
    check(trailingGarbage?.speed == "trailing garbage fallback", "trailing-garbage VDO should use report text")

    for bits in 5...7 {
        // Use a VDO with high bits set (not just the bare reserved value) so
        // the raw 32-bit VDO differs from the masked 3 bits. This catches a
        // regression that interpolated the whole VDO instead of `vdo & 0b111`.
        let rawVDO = UInt32(0xABCD_E000) | UInt32(bits)
        let body = reportBody(vdo: String(format: "0x%08X", rawVDO), fallback: "reserved fallback \(bits)")
        let report = parse(body: body, issueNumber: bits + 20)
        check(report?.cableVDO == rawVDO, "reserved speed bits \(bits) should preserve the full Raw Cable VDO")
        check(
            report?.speed == "Reserved cable speed encoding (\(bits))",
            "reserved speed bits \(bits) should derive the stable reserved label from the masked bits, matching the app"
        )
        check(report?.speed != canonicalCableSpeedLabels[0], "reserved speed bits \(bits) must not become USB 2.0")
    }

    let migrationInput = """
    ## Table
    | Brand / model context | VID | PID | Cable VDO | Vendor | USB-IF XID | Speed | Power | Type | Source |
    |---|---|---|---|---|---|---|---|---|---|
    | With evidence | `0x1234` | `0x0001` | `0x00000003` | Vendor | none | localized | power | passive | source |
    | No evidence | `0x1234` | `0x0002` |  | Vendor | none | keep no VDO | power | passive | source |
    | Reserved | `0x1234` | `0x0003` | `0xABCDE005` | Vendor | none | keep reserved | power | passive | source |
    | Malformed | `0x1234` | `0x0004` | `0x00000003oops` | Vendor | none | keep malformed | power | passive | source |
    """
    let migrated = normalizingExistingSpeeds(in: migrationInput)
    check(migrated.count == 2, "rows with any valid Raw Cable VDO evidence (defined or reserved) should migrate")
    check(migrated.markdown.contains("| USB4 Gen 3 (40 Gbps, Thunderbolt 4 class) |"), "valid VDO row should use canonical speed")
    check(migrated.markdown.contains("| keep no VDO |"), "row without VDO evidence should stay unchanged")
    check(migrated.markdown.contains("| Reserved cable speed encoding (5) |"), "row with reserved VDO encoding should migrate to the stable reserved label")
    check(!migrated.markdown.contains("| keep reserved |"), "reserved row's hand-typed speed text should be replaced")
    check(migrated.markdown.contains("| keep malformed |"), "row with trailing-garbage VDO should stay unchanged")

    // Dedicated reserved-row migration: a row already carrying the stable
    // reserved label must NOT be counted as a change (idempotent re-runs).
    let reservedStableInput = """
    ## Table
    | Brand / model context | VID | PID | Cable VDO | Vendor | USB-IF XID | Speed | Power | Type | Source |
    |---|---|---|---|---|---|---|---|---|---|
    | Reserved 6 | `0x1234` | `0x0005` | `0xABCDE006` | Vendor | none | old text | power | passive | source |
    | Reserved 7 already stable | `0x1234` | `0x0006` | `0xABCDE007` | Vendor | none | Reserved cable speed encoding (7) | power | passive | source |
    """
    let reservedMigrated = normalizingExistingSpeeds(in: reservedStableInput)
    check(reservedMigrated.count == 1, "only the reserved row whose speed text differs should migrate")
    check(reservedMigrated.markdown.contains("| Reserved cable speed encoding (6) |"), "reserved bits 6 should migrate to its stable label")
    check(reservedMigrated.markdown.contains("| Reserved cable speed encoding (7) |"), "already-stable reserved row should be preserved unchanged")

    if failures == 0 { print("Cable report speed self-tests passed") }
    return failures
}

if CommandLine.arguments.contains("--test-speed") {
    exit(runSpeedSelfTests() == 0 ? 0 : 1)
}

// MARK: - Update markdown

/// Append new rows after the last existing data row, leaving every existing
/// row byte-for-byte intact. We never regenerate rows we already have, so
/// hand edits and ordering are preserved. No-op when there is nothing new.
func appendRows(_ rows: [String]) {
    if rows.isEmpty { return }
    guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else {
        fputs("error: could not read \(mdURL.path)\n", Darwin.stderr)
        exit(6)
    }
    let lines = md.components(separatedBy: "\n")

    // Find the header row and the first non-table line after it.
    var headerIdx: Int?
    for (i, line) in lines.enumerated() where line.hasPrefix("## Table") {
        for j in (i + 1) ..< lines.count where lines[j].hasPrefix("|") {
            headerIdx = j
            break
        }
        break
    }
    guard let h = headerIdx, h + 1 < lines.count, lines[h + 1].contains("---") else {
        fputs("error: could not find table header in \(mdURL.path)\n", Darwin.stderr)
        exit(7)
    }

    // Walk forward past the existing data rows to the end of the table block.
    var endIdx = h + 2
    while endIdx < lines.count, lines[endIdx].hasPrefix("|") { endIdx += 1 }

    // Keep header + separator + all existing rows, then insert the new rows.
    var newLines = Array(lines[..<endIdx])
    newLines.append(contentsOf: rows)
    newLines.append(contentsOf: lines[endIdx...])

    do {
        try newLines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        fputs("error: could not write \(mdURL.path): \(error)\n", Darwin.stderr)
        exit(8)
    }
}

// MARK: - Main

let vendors = loadVendors()
let issues = runGh()
let normalizedCount = normalizeExistingSpeeds()
let existing = loadExisting()

// Collect only cables we do not already have. Skip a report if its issue is
// already recorded, or if its fingerprint already appears in the table (a
// duplicate cable re-reported under a new issue number). Dedup within this
// batch too, so two new issues for the same cable add one row.
var seenFingerprints = existing.fingerprints
var newReports: [Report] = []
for issue in issues {
    guard let n = issue["number"] as? Int,
          let body = issue["body"] as? String else { continue }
    if existing.issues.contains(n) { continue }
    guard let r = parse(body: body, issueNumber: n) else { continue }
    let key = fingerprintKey(vid: r.vid, pid: r.pid, vdo: r.cableVDO ?? 0)
    if seenFingerprints.contains(key) {
        // A silent skip here would lose exactly the #505 case: the same
        // e-marker fingerprint sold under a different sleeve brand is a real
        // finding (shared OEM silicon), not just a duplicate report. We
        // still never auto-append a row for it (that decision needs the
        // reporter's actual brand/model context), but a loud note means the
        // possible rebrand doesn't get lost the way #505 briefly could have.
        let existingBrand = existing.brandByFingerprint[key] ?? "(unknown)"
        fputs("note: issue #\(n): fingerprint matches existing row '\(existingBrand)' - possible rebrand; add a row by hand if the sleeve brand differs\n", Darwin.stderr)
        continue
    }
    seenFingerprints.insert(key)
    newReports.append(r)
}

// Sort the new rows: VID ascending, zeroed last, then by issue number.
// Existing rows are never reordered.
newReports.sort { a, b in
    let aZero = a.vid == 0
    let bZero = b.vid == 0
    if aZero != bZero { return !aZero }  // non-zero first
    if a.vid != b.vid { return a.vid < b.vid }
    return a.issueNumber < b.issueNumber
}

let rendered = newReports.map { renderRow($0, context: needsReview, vendors: vendors) }
appendRows(rendered)

if newReports.isEmpty {
    print("nothing new to add; the table is already up to date")
} else {
    let nums = newReports.map { "#\($0.issueNumber)" }.joined(separator: ", ")
    print("appended \(newReports.count) new cable(s): \(nums)")
    print("fill the '\(needsReview)' rows by hand")
}
if normalizedCount > 0 {
    print("canonicalized \(normalizedCount) existing speed value(s) from Raw Cable VDO evidence")
}
if !newReports.isEmpty || normalizedCount > 0 {
    print("then run: swift scripts/build-cable-db.swift && swift scripts/render-known-cables.swift")
}
