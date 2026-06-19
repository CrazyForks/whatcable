import Foundation
import WhatCableCore
import WhatCableDarwinBackend
import WhatCableAppKit
import WhatCablePlugins

@main
struct WhatCableCLI {
    @MainActor
    static func main() async {
        bootstrapPlugins(registry: .shared)

        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("-h") || args.contains("--help") {
            print(helpText)
            return
        }
        if args.contains("--version") {
            print(AppInfo.version)
            return
        }

        if args.contains("--tb-debug") {
            print(ThunderboltProbe.dump(), terminator: "")
            return
        }

        let wantsDesktop = args.contains("--desktop")
        let wantsPopover = args.contains("--popover")
        if wantsDesktop || wantsPopover {
            if wantsDesktop && wantsPopover {
                FileHandle.standardError.write(Data("whatcable: --desktop and --popover are mutually exclusive\n".utf8))
                exit(2)
            }
            launchApp(menuBarMode: wantsPopover)
            return
        }

        // Validate unknown flags BEFORE dispatching plugin commands. Otherwise
        // a typo alongside a plugin flag (e.g. `whatcable --pro --bogus`) would
        // silently run the plugin instead of complaining about the typo.
        var knownFlags: Set<String> = ["--raw", "--json", "--watch", "--report", "--tb-debug", "--desktop", "--popover", "-h", "--help", "--version"]
        for cmd in PluginRegistry.shared.cliCommands {
            knownFlags.formUnion(cmd.flagNames)
        }
        for arg in args where arg.hasPrefix("-") && arg != "--" && !knownFlags.contains(arg) {
            FileHandle.standardError.write(Data("whatcable: unknown option \(arg)\n".utf8))
            FileHandle.standardError.write(Data(helpText.utf8))
            exit(2)
        }

        // Plugin commands are program-modes, not flags that combine. If the
        // user typed two at once (e.g. `--activate KEY --silence-pro-hints`)
        // their intent is ambiguous, so refuse rather than silently picking
        // the first one in registration order.
        let matchingCommands = PluginRegistry.shared.cliCommands.filter { $0.matches(args) }
        if matchingCommands.count > 1 {
            let names = matchingCommands.flatMap { $0.flagNames }.joined(separator: ", ")
            FileHandle.standardError.write(Data("whatcable: multiple commands matched (\(names)). Run one at a time.\n".utf8))
            exit(2)
        }
        if let cmd = matchingCommands.first {
            await cmd.run(args)
            return
        }

        let showRaw = args.contains("--raw")
        let asJSON = args.contains("--json")
        let watch = args.contains("--watch")
        let report = args.contains("--report")

        let provider = makeDefaultSnapshotProvider()

        if watch {
            await runWatch(provider: provider, asJSON: asJSON, showRaw: showRaw)
            return
        }

        do {
            let snapshot = try await provider.snapshot()

            if report {
                printCableReports(identities: snapshot.identities, cioCapabilities: snapshot.cioCapabilities)
                return
            }

            try printSnapshot(snapshot, asJSON: asJSON, showRaw: showRaw)

            // Plain text one-shot output gets a footer hint from any plugin
            // that wants one (e.g. the unlicensed-Pro hint). Suppressed for
            // --json (machine-readable) and not reached for --watch / --report.
            if !asJSON {
                for contributor in PluginRegistry.shared.cliOutputFooterContributors {
                    if let line = contributor() {
                        print("")
                        print(line)
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("whatcable: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static var helpText: String {
        var text = """
        whatcable \(AppInfo.version) -- \(AppInfo.tagline)

        Usage: whatcable [options]

        Options:
          --watch        Continuously monitor for changes (Ctrl+C to exit)
          --json         Output as JSON instead of human-readable text
          --raw          Include raw IOKit properties for each port
          --report       Print a cable report (markdown + GitHub URL) and exit
          --desktop      Open WhatCable as a Dock app with a window
          --popover      Open WhatCable in the menu bar (popover mode)
          --tb-debug     Dump the IOThunderboltSwitch tree (for contributors helping
                         us design the Thunderbolt fabric feature). See issue tracker.
          --version      Print version and exit
          -h, --help     Show this help and exit

        """
        for cmd in PluginRegistry.shared.cliCommands {
            text += cmd.helpLines + "\n"
        }
        return text
    }
}

private func printSnapshot(_ snapshot: CableSnapshot, asJSON: Bool, showRaw: Bool) throws {
    if asJSON {
        let json = try JSONFormatter.render(
            ports: snapshot.ports,
            sources: snapshot.powerSources,
            identities: snapshot.identities,
            showRaw: showRaw,
            adapter: snapshot.adapter,
            thunderboltSwitches: snapshot.thunderboltSwitches,
            isDesktopMac: snapshot.isDesktopMac,
            batteryFullyCharged: snapshot.batteryFullyCharged,
            batteryIsCharging: snapshot.batteryIsCharging,
            federatedIdentities: snapshot.federatedIdentities,
            usb3Transports: snapshot.usb3Transports,
            trmTransports: snapshot.trmTransports,
            cioCapabilities: snapshot.cioCapabilities,
            usbDevices: snapshot.usbDevices,
            displayPorts: snapshot.displayPorts,
            builtInDisplayPorts: BuiltInDisplayPort.group(from: snapshot.displayPorts)
        )
        print(json)
    } else {
        // trmTransports intentionally omitted: text mode does not render TRM data yet.
        // Wire it in here when TextFormatter gains TRM rendering.
        let output = TextFormatter.render(
            ports: snapshot.ports,
            sources: snapshot.powerSources,
            identities: snapshot.identities,
            showRaw: showRaw,
            adapter: snapshot.adapter,
            thunderboltSwitches: snapshot.thunderboltSwitches,
            isDesktopMac: snapshot.isDesktopMac,
            batteryFullyCharged: snapshot.batteryFullyCharged,
            batteryIsCharging: snapshot.batteryIsCharging,
            federatedIdentities: snapshot.federatedIdentities,
            usb3Transports: snapshot.usb3Transports,
            cioCapabilities: snapshot.cioCapabilities,
            usbDevices: snapshot.usbDevices,
            displayPorts: snapshot.displayPorts,
            builtInDisplayPorts: BuiltInDisplayPort.group(from: snapshot.displayPorts)
        )
        print(output, terminator: "")
    }
}

private func runWatch(provider: any CableSnapshotProvider, asJSON: Bool, showRaw: Bool) async {
    let watchTask = Task {
        await consumeWatchStream(provider: provider, asJSON: asJSON, showRaw: showRaw)
    }

    // Default SIGINT / SIGTERM kill the process abruptly. Take them over so
    // the watch task can cancel cleanly, the provider's onTermination tears
    // down its internal task, and stdout flushes before exit.
    // Track which signal fired so we can exit with the POSIX convention
    // 128+signal (130 for SIGINT, 143 for SIGTERM).
    var caughtSignal: Int32 = 0
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSrc.setEventHandler {
        caughtSignal = SIGINT
        watchTask.cancel()
    }
    intSrc.resume()

    let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSrc.setEventHandler {
        caughtSignal = SIGTERM
        watchTask.cancel()
    }
    termSrc.resume()

    await watchTask.value

    intSrc.cancel()
    termSrc.cancel()
    fflush(stdout)

    if caughtSignal != 0 {
        exit(128 + caughtSignal)
    }
}

private func consumeWatchStream(provider: any CableSnapshotProvider, asJSON: Bool, showRaw: Bool) async {
    var lastOutput = ""
    do {
        for try await snapshot in provider.watch() {
            if Task.isCancelled { return }

            let output: String
            if asJSON {
                do {
                    output = try JSONFormatter.render(
                        ports: snapshot.ports,
                        sources: snapshot.powerSources,
                        identities: snapshot.identities,
                        showRaw: showRaw,
                        adapter: snapshot.adapter,
                        thunderboltSwitches: snapshot.thunderboltSwitches,
                        isDesktopMac: snapshot.isDesktopMac,
                        batteryFullyCharged: snapshot.batteryFullyCharged,
                        batteryIsCharging: snapshot.batteryIsCharging,
                        federatedIdentities: snapshot.federatedIdentities,
                        usb3Transports: snapshot.usb3Transports,
                        trmTransports: snapshot.trmTransports,
                        cioCapabilities: snapshot.cioCapabilities,
                        usbDevices: snapshot.usbDevices,
                        displayPorts: snapshot.displayPorts,
                        builtInDisplayPorts: BuiltInDisplayPort.group(from: snapshot.displayPorts)
                    )
                } catch {
                    FileHandle.standardError.write(Data("whatcable: json encoding failed: \(error)\n".utf8))
                    continue
                }
            } else {
                // trmTransports intentionally omitted: text mode does not render TRM data yet.
                // Wire it in here when TextFormatter gains TRM rendering.
                output = TextFormatter.render(
                    ports: snapshot.ports,
                    sources: snapshot.powerSources,
                    identities: snapshot.identities,
                    showRaw: showRaw,
                    adapter: snapshot.adapter,
                    thunderboltSwitches: snapshot.thunderboltSwitches,
                    isDesktopMac: snapshot.isDesktopMac,
                    batteryFullyCharged: snapshot.batteryFullyCharged,
                    batteryIsCharging: snapshot.batteryIsCharging,
                    federatedIdentities: snapshot.federatedIdentities,
                    usb3Transports: snapshot.usb3Transports,
                    cioCapabilities: snapshot.cioCapabilities,
                    usbDevices: snapshot.usbDevices,
                    displayPorts: snapshot.displayPorts,
                    builtInDisplayPorts: BuiltInDisplayPort.group(from: snapshot.displayPorts)
                )
            }

            guard output != lastOutput else { continue }
            lastOutput = output

            if asJSON {
                // Newline-delimited JSON: one self-contained object per change.
                print(output)
            } else {
                // Clear screen + home cursor, then redraw.
                print("\u{1B}[2J\u{1B}[H", terminator: "")
                print(timestampHeader())
                print(output, terminator: "")
            }
            fflush(stdout)
        }
    } catch is CancellationError {
        return
    } catch {
        FileHandle.standardError.write(Data("whatcable: \(error)\n".utf8))
        fflush(stdout)
        exit(1)
    }
}

private let watchTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

private func timestampHeader() -> String {
    return "whatcable --watch · \(watchTimestampFormatter.string(from: Date()))\n\n"
}

private func launchApp(menuBarMode: Bool) {
    let suiteName = "uk.whatcable.whatcable"
    if let defaults = UserDefaults(suiteName: suiteName) {
        defaults.set(menuBarMode, forKey: "useMenuBarMode")
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    // If running from inside the .app bundle (Contents/Helpers/whatcable),
    // open that specific bundle. Otherwise fall back to Spotlight lookup.
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidate = execURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if candidate.pathExtension == "app" {
        task.arguments = [candidate.path]
    } else {
        task.arguments = ["-a", "WhatCable"]
    }
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            FileHandle.standardError.write(Data("whatcable: could not open WhatCable.app\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("whatcable: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

private func printCableReports(identities: [USBPDSOP], cioCapabilities: [CIOCableCapability]) {
    let cables = identities.filter {
        $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
    }
    if cables.isEmpty {
        print("No cable e-markers detected. Plug in an e-marked USB-C cable and try again.")
        print("(Most cables under 60W don't carry an e-marker, so there's nothing to report on those.)")
        return
    }
    for (i, identity) in cables.enumerated() {
        if cables.count > 1 {
            print("=== Cable \(i + 1) of \(cables.count) ===")
            print("")
        }
        // Match by canonicalJoinKey: UUID-keyed on M3+, portKey fallback on M1/M2.
        let cio = cioCapabilities.first { $0.canonicalJoinKey == identity.canonicalJoinKey }
        guard let payload = CableReport.payload(
            for: identity,
            includeSystemInfo: true,
            cioCapability: cio
        ) else { continue }
        print(payload.markdown)
        print("")
        print("Open in GitHub to file a report:")
        print(payload.githubURL.absoluteString)
        print("")
    }
}
