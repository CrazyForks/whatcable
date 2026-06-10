// In-process installer for the self-update path.
import Foundation
import AppKit
import os.log

/// Downloads a new release zip from GitHub, validates its code signature
/// matches the currently running app, and swaps the bundles via a small
/// shell script that waits for this process to exit before doing the move.
@MainActor
final class Installer: ObservableObject {
    static let shared = Installer()
    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "installer")
    private static let expectedBundleID = "uk.whatcable.whatcable"

    enum State: Equatable {
        case idle
        case downloading
        case verifying
        case installing
        case failed(String)
        /// The update can't be applied here (e.g. a non-admin account that
        /// can't write to /Applications). Distinct from `failed` so the UI can
        /// show the guidance verbatim, without the "Install failed:" prefix.
        case blocked(String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    func install(_ update: AvailableUpdate) {
        guard case .idle = state else { return }
        guard let downloadURL = update.downloadURL else {
            state = .failed("No download asset for this release")
            return
        }

        // A standard (non-admin) account can't write to /Applications, so the
        // in-place bundle swap at the end would fail. That swap runs in a
        // detached script after we quit, with its output sent to /dev/null, so
        // the failure used to be completely invisible (issue #287). Catch the
        // unwritable location up front and tell the user how to update instead.
        let installDir = Bundle.main.bundleURL.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: installDir.path) {
            state = .blocked(String(localized: "This account can't update apps in this location. Download the new version from whatcable.uk, or update with Homebrew.", bundle: _appLocalizedBundle))
            return
        }

        state = .downloading

        Task {
            var workDir: URL?
            do {
                workDir = try makeWorkDir()
                let zipURL = try await download(from: downloadURL, into: workDir!)

                state = .verifying
                let extractedApp = try await unzipAndLocate(zip: zipURL, in: workDir!)
                try await verifySignatureMatches(new: extractedApp, current: Bundle.main.bundleURL)

                state = .installing
                try launchSwapScript(newApp: extractedApp, currentApp: Bundle.main.bundleURL)

                // Give the script a moment to start before we quit.
                try await Task.sleep(nanoseconds: 250_000_000)
                NSApp.terminate(nil)
            } catch {
                if let workDir {
                    try? FileManager.default.removeItem(at: workDir)
                }
                Self.log.error("Install failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Steps

    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatcable-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func download(from url: URL, into dir: URL) async throws -> URL {
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError("Download failed with HTTP \(http.statusCode)")
        }
        let dest = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    private func unzipAndLocate(zip: URL, in dir: URL) async throws -> URL {
        try await validateZipEntries(zip)
        try await run("/usr/bin/unzip", ["-q", zip.path, "-d", dir.path])

        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, apps[0].lastPathComponent == "WhatCable.app" else {
            throw InstallError("Expected exactly one WhatCable.app in the downloaded zip")
        }
        return apps[0]
    }

    // Check zip entries for path traversal or absolute paths before extracting.
    private func validateZipEntries(_ zip: URL) async throws {
        let output = try await run("/usr/bin/unzip", ["-Z1", zip.path])
        for entry in output.split(separator: "\n") {
            let path = String(entry)
            if path.hasPrefix("/") || path.contains("../") || path.contains("/..") {
                throw InstallError("Zip contains unsafe path: \(path)")
            }
        }
    }

    private func verifySignatureMatches(new: URL, current: URL) async throws {
        // Check team identifier matches.
        let newTeam = try await teamIdentifier(of: new)
        let currentTeam = try await teamIdentifier(of: current)
        if newTeam != currentTeam {
            throw InstallError("Signature mismatch: refusing to install (current \(currentTeam), new \(newTeam))")
        }
        // Check bundle ID is exactly what we expect.
        let bundleID = Bundle(url: new)?.bundleIdentifier ?? ""
        if bundleID != Self.expectedBundleID {
            throw InstallError("Unexpected bundle identifier: \(bundleID)")
        }
        // Verify signature structure is valid.
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path])
        // Verify Gatekeeper / notarization acceptance.
        try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", new.path])
        // Strip quarantine only after all checks pass.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", new.path])
    }

    private func teamIdentifier(of app: URL) async throws -> String {
        let result = try await runProcess("/usr/bin/codesign", ["-dvv", app.path])
        if result.exitCode != 0 {
            throw InstallError("codesign failed (\(result.exitCode)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // codesign writes its `-dvv` report to stderr, not stdout. Search both
        // so the parse is robust to that (and to any future change in which
        // stream it uses).
        let combined = result.stderr + "\n" + result.stdout
        for line in combined.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                return String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        throw InstallError("Could not read TeamIdentifier from \(app.lastPathComponent)")
    }

    private func launchSwapScript(newApp: URL, currentApp: URL) throws {
        let script = """
        #!/bin/bash
        set -e
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW=\(shellQuote(newApp.path))
        OLD=\(shellQuote(currentApp.path))
        BACKUP="${OLD}.backup"

        # Wait up to 30s for the running app to exit
        for _ in $(seq 1 60); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 0.5
        done

        # Move old bundle to backup instead of deleting it.
        # If the swap fails, the user can rename .backup back.
        rm -rf "$BACKUP"
        mv "$OLD" "$BACKUP"

        if mv "$NEW" "$OLD"; then
            open "$OLD"
            sleep 2
            rm -rf "$BACKUP"
        else
            # Swap failed; remove any partial destination before restoring.
            rm -rf "$OLD"
            mv "$BACKUP" "$OLD"
            open "$OLD"
        fi

        # Clean up this script and the temp directory.
        rm -rf "$(dirname "$0")"
        rm -f "$0"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatcable-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        // Detach stdio so the child survives our exit cleanly.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        try task.run()
    }

    // MARK: - Process helpers

    /// The outcome of a finished subprocess, with stdout and stderr kept apart.
    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a subprocess on a background queue and return its captured output.
    ///
    /// This is async and hops off the main actor (via the global queue), so the
    /// install UI never freezes while `codesign` / `spctl` / `unzip` run. stdout
    /// and stderr get their own pipes, each drained concurrently while the child
    /// is still alive: a child that writes more than the ~64KB pipe buffer would
    /// otherwise stall on `write()` while we sat in `waitUntilExit()`, deadlocking.
    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) async throws -> String {
        let result = try await runProcess(launchPath, arguments)
        if result.exitCode != 0 {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw InstallError("\(launchPath) failed (\(result.exitCode)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: launchPath)
                task.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                task.standardInput = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr on its own queue while we drain stdout inline, so
                // neither pipe's buffer can fill and stall the child. Both reads
                // return at EOF (the child closing the pipe), and `group.wait()`
                // gives the happens-before that makes `errData` safe to read.
                let errQueue = DispatchQueue(label: "uk.whatcable.installer.stderr")
                let group = DispatchGroup()
                var errData = Data()
                group.enter()
                errQueue.async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                task.waitUntilExit()

                continuation.resume(returning: ProcessResult(
                    exitCode: task.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct InstallError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}



