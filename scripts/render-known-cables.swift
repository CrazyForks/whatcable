#!/usr/bin/env swift

// Render the fingerprint table from data/known-cables.md as a Nunjucks
// partial at src/_includes/cables-table.njk. Eleventy's src/cables.njk
// wraps this with the chrome, intro, search UI, and JS.
//
// Run from the repo root:
//   swift scripts/render-known-cables.swift
//
// Run before Eleventy:
//   swift scripts/render-known-cables.swift && bun run site:build
//
// Exits non-zero if the markdown table is malformed (missing columns,
// no rows, etc) so the build fails loudly rather than emitting a
// broken partial.

import Foundation

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let inputURL = URL(fileURLWithPath: "\(repoRoot)/data/known-cables.md")
let outputURL = URL(fileURLWithPath: "\(repoRoot)/src/_includes/cables-table.njk")

guard let markdown = try? String(contentsOf: inputURL, encoding: .utf8) else {
    fputs("error: could not read \(inputURL.path)\n", stderr)
    exit(2)
}

// MARK: - Inline markdown helpers

/// HTML-escape <, >, &, " in a string.
func escapeHTML(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
}

/// Replace all matches of `pattern` in `s` with the NSRegularExpression
/// template `tmpl` ($1 / $2 backreferences).
func regexReplace(_ s: String, pattern: String, with tmpl: String) -> String {
    let re = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(s.startIndex..., in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: tmpl)
}

/// Apply the small subset of inline markdown the source file uses:
///   `code`, [text](url), **bold**.
/// Order matters: code spans first so their inner content is left alone,
/// then links, then bold.
func renderInline(_ s: String) -> String {
    var text = escapeHTML(s)
    text = regexReplace(text, pattern: "`([^`]+)`",                with: "<code>$1</code>")
    text = regexReplace(text, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>")
    text = regexReplace(text, pattern: "\\*\\*([^*]+)\\*\\*",      with: "<strong>$1</strong>")
    return text
}

/// If `line` looks like "<digits>. <text>", return <text>; else nil.
func numberedListLeader(_ line: String) -> String? {
    let re = try! NSRegularExpression(pattern: "^\\d+\\.\\s+(.*)$")
    let range = NSRange(line.startIndex..., in: line)
    guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges >= 2 else { return nil }
    guard let r = Range(m.range(at: 1), in: line) else { return nil }
    return String(line[r])
}

// MARK: - Table parsing

struct CableRow {
    let cells: [String]
}

let lines = markdown.components(separatedBy: "\n")

// Find the first markdown table after the "## Table" heading. We
// expect the header row, the separator row (|---|---|...), then data
// rows until a non-table line.
var tableStart: Int?
for (i, line) in lines.enumerated() {
    if line.hasPrefix("## Table") {
        // First table line after this heading.
        for j in (i + 1) ..< lines.count where lines[j].hasPrefix("|") {
            tableStart = j
            break
        }
        break
    }
}
guard let headerIdx = tableStart else {
    fputs("error: could not locate the cables table under '## Table'\n", stderr)
    exit(3)
}

func splitRow(_ line: String) -> [String] {
    // Markdown rows look like: | a | b | c |
    // Trim outer pipes, then split on |, then trim each cell.
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    return trimmed
        .components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

let headerCells = splitRow(lines[headerIdx])
let separatorIdx = headerIdx + 1
guard separatorIdx < lines.count, lines[separatorIdx].contains("---") else {
    fputs("error: expected separator row at line \(separatorIdx + 1)\n", stderr)
    exit(4)
}

var rows: [CableRow] = []
var i = separatorIdx + 1
while i < lines.count, lines[i].hasPrefix("|") {
    let cells = splitRow(lines[i])
    guard cells.count == headerCells.count else {
        fputs("error: row \(i + 1) has \(cells.count) cells, expected \(headerCells.count)\n", stderr)
        exit(5)
    }
    // Skip "(needs review)" rows, matching build-cable-db.swift. They have no
    // usable product name, so publishing one puts the literal text
    // "(needs review)" in the site's no-JS table as if it were a cable name.
    // Skipping here keeps this fallback table in agreement with cables.json,
    // which the JS table reads and which excludes the same rows.
    if cells.first != "(needs review)" {
        rows.append(CableRow(cells: cells))
    }
    i += 1
}

guard !rows.isEmpty else {
    fputs("error: no data rows found in cables table\n", stderr)
    exit(6)
}

// MARK: - Patterns parsing

// Find the "## Patterns worth flagging" section and grab its numbered
// list items. Each item is multi-line in the markdown; we collect
// lines until the next blank line or top-level heading.
struct Pattern {
    let body: String  // raw markdown; rendered with renderInline
}

var patterns: [Pattern] = []
if let patternsHeader = lines.firstIndex(where: { $0.hasPrefix("## Patterns") }) {
    var current: String? = nil
    for j in (patternsHeader + 1) ..< lines.count {
        let line = lines[j]
        if line.hasPrefix("## ") { break }  // next section
        if let head = numberedListLeader(line) {
            // Flush previous, start new.
            if let prev = current { patterns.append(Pattern(body: prev)) }
            current = head
        } else if line.hasPrefix("   ") {
            // Continuation of current item (markdown soft-wrap).
            let cont = line.trimmingCharacters(in: .whitespaces)
            if !cont.isEmpty {
                current = (current ?? "") + " " + cont
            }
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let prev = current {
                patterns.append(Pattern(body: prev))
                current = nil
            }
        }
    }
    if let last = current { patterns.append(Pattern(body: last)) }
}

// MARK: - Build HTML

let dateFormatter = ISO8601DateFormatter()
dateFormatter.formatOptions = [.withFullDate]
let today = dateFormatter.string(from: Date())

let cellClasses: [String] = [
    "context", "vid", "pid", "cable-vdo", "vendor", "xid", "speed", "power", "type", "source",
]

func renderHeaderCell(_ s: String, cls: String) -> String {
    "<th class=\"col-\(cls)\">\(escapeHTML(s))</th>"
}

func renderBodyCell(_ s: String, cls: String) -> String {
    "<td class=\"col-\(cls)\">\(renderInline(s))</td>"
}

let headerHTML = zip(headerCells, cellClasses)
    .map { renderHeaderCell($0.0, cls: $0.1) }
    .joined(separator: "\n            ")

let rowsHTML = rows.map { row in
    let cells = zip(row.cells, cellClasses)
        .map { renderBodyCell($0.0, cls: $0.1) }
        .joined(separator: "\n            ")
    return "          <tr>\n            \(cells)\n          </tr>"
}.joined(separator: "\n")

// Partial contents: just the table HTML. The Eleventy template
// (src/cables.njk) provides the chrome, the intro, the patterns
// list, the search UI, and the JS that loads cables.json for
// client-side filtering. This partial is the noscript fallback
// table only.

let html = """
{# Generated by scripts/render-known-cables.swift from data/known-cables.md.
   Do not edit by hand. Last regenerated: \(today). #}
<table class="cables">
  <thead>
    <tr>
      \(headerHTML)
    </tr>
  </thead>
  <tbody>
\(rowsHTML)
  </tbody>
</table>
"""

do {
    try html.write(to: outputURL, atomically: true, encoding: .utf8)
    print("wrote \(outputURL.path) (\(rows.count) rows, \(patterns.count) patterns parsed)")
} catch {
    fputs("error: could not write \(outputURL.path): \(error)\n", stderr)
    exit(7)
}

