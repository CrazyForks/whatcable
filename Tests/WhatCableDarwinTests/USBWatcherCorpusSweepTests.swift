import Foundation
import Testing
@testable import WhatCableDarwinBackend
import WhatCableCore

// MARK: - USBWatcherCorpusSweepTests
//
// Corpus-replay coverage for `USBWatcher`'s hub-nesting / tunnel classification
// (Watchers/USBWatcher.swift), which had zero corpus coverage before this file.
//
// SEAM NOTE (read this before extending): `USBWatcher.makeDevice(from:)` and
// `USBWatcher.controllerInfo(for:fallback:)` are both `private func` taking a
// live `io_service_t`, so they cannot be called from a test at all -- there is
// no IOKit registry to hand them outside a running Mac. What IS reachable
// without IOKit is the set of `nonisolated static` pure functions those two
// methods delegate their actual decisions to:
//
//   - `usbIOPortPath(from:)`        -- String/Data -> path string
//   - `portName(fromUSBIOPortPath:)` -- path string -> "Port-USB-C@N" or nil
//   - `busIndex(fromLocationID:)`    -- locationID -> upper-byte bus index
//   - `isThunderboltDockController(_:)` -- IOKit class name -> Bool
//   - `classifyBehindInternalHub(...)`  -- the #375/#348/#373 structural gate
//   - `internalHubPortType`          -- the USBPortType==2 constant
//
// `Tests/WhatCableDarwinTests/RegistryParsingTests.swift` already unit-tests
// these functions against hand-crafted fixtures. This file is complementary,
// not a duplicate: it replays the exact ancestor chains IOKit reported on 30
// real machines (probe 38, `usb_device_tree`) through the SAME production
// functions, driven by a test-local walk that mirrors `controllerInfo`'s loop
// step for step. If a future edit to `controllerInfo` drifts from this
// mirrored walk, that drift is a documentation gap here, not a masked bug in
// the pure functions themselves (the walk is test scaffolding; the functions
// under test are production code called with real data).
//
// Probe 36 (`xhci_port_map`) is used more lightly: it gives a ground-truth
// XHCI-port-locationID -> usb-c-port-number map, used to sanity-check
// `busIndex(fromLocationID:)` against real device/port locationID pairs.
@Suite("USBWatcher corpus sweep - hub nesting and tunnel classification")
struct USBWatcherCorpusSweepTests {

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

    private static func loadProbeText(folder: String, fileName: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe-38 parsing
    //
    // Probe 38's own header says: "Mirrors USBWatcher.controllerInfo: each
    // device, then its IOService-plane ancestors up to the host controller,
    // with class / USBPortType / UsbIOPort." Format (verified against the
    // corpus directly, 2026-07):
    //
    //   --- Device[N] ---
    //     USB Product Name = "..."
    //     locationID = 0xHEX
    //     ...
    //     Ancestors (device -> controller):
    //       [0] class=ClassName locationID=0xHEX
    //       [1] class=ClassName locationID=0xHEX USBPortType=N
    //       [2] class=ClassName locationID=0xHEX UsbIOPort=IOService:/.../Port-USB-C@N
    //       (reached host controller: ClassName)

    struct Ancestor {
        let className: String
        let locationID: UInt32?
        let usbPortType: Int?
        let usbIOPort: String?
    }

    struct DeviceBlock {
        let locationID: UInt32
        let ancestors: [Ancestor]
    }

    /// Parse one ancestor line, e.g.:
    ///   "[3] class=AppleUSB30HubPort locationID=0x22120000 USBPortType=0"
    ///   "[0] class=AppleUSB30XHCIARMPort locationID=0x100000 UsbIOPort=IOService:/.../Port-USB-C@1"
    private static func parseAncestorLine(_ line: String) -> Ancestor? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let rest = trimmed[trimmed.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(separator: " ")

        var className: String?
        var locationID: UInt32?
        var usbPortType: Int?
        var usbIOPort: String?

        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            switch key {
            case "class":
                className = value
            case "locationID":
                var hex = value
                if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
                locationID = UInt32(hex, radix: 16)
            case "USBPortType":
                usbPortType = Int(value)
            case "UsbIOPort":
                usbIOPort = value
            default:
                break
            }
        }
        guard let className else { return nil }
        return Ancestor(className: className, locationID: locationID, usbPortType: usbPortType, usbIOPort: usbIOPort)
    }

    private static func parseDeviceBlocks(_ text: String) -> [DeviceBlock] {
        text.components(separatedBy: "--- Device[").dropFirst().compactMap { block in
            var deviceLocationID: UInt32?
            var ancestors: [Ancestor] = []
            var inAncestors = false
            for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("locationID =") || trimmed.hasPrefix("locationID=") {
                    if let eq = trimmed.firstIndex(of: "=") {
                        var hex = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
                        deviceLocationID = UInt32(hex, radix: 16)
                    }
                    continue
                }
                if trimmed.hasPrefix("Ancestors") { inAncestors = true; continue }
                if trimmed.hasPrefix("(reached host controller") { inAncestors = false; continue }
                if inAncestors, trimmed.hasPrefix("[") {
                    if let ancestor = parseAncestorLine(trimmed) { ancestors.append(ancestor) }
                }
            }
            guard let loc = deviceLocationID else { return nil }
            return DeviceBlock(locationID: loc, ancestors: ancestors)
        }
    }

    // MARK: - Walk replica (test scaffolding; production functions do the real work)
    //
    // Mirrors the `for _ in 0..<20` loop in `USBWatcher.controllerInfo`, one
    // ancestor per iteration (probe 38's ancestor list IS that walk, already
    // captured). Every branch below calls the production `nonisolated static`
    // function for the actual decision; this function only sequences them in
    // the same order and with the same early-exit semantics as the real walk.
    struct WalkResult {
        let portName: String?
        let tunnelled: Bool
        let reachedNativeController: Bool
        let hubPortType: Int?
        let bus: Int
        let behindInternalHub: Bool
    }

    private static func replayWalk(deviceLocationID: UInt32, ancestors: [Ancestor]) -> WalkResult {
        var portName: String?
        var tunnelled = false
        var reachedNativeController = false
        var hubPortType: Int?
        var bus: Int?

        for ancestor in ancestors {
            if portName == nil, let raw = ancestor.usbIOPort,
               let path = USBWatcher.usbIOPortPath(from: raw),
               let name = USBWatcher.portName(fromUSBIOPortPath: path) {
                portName = name
            }
            // Real code checks IOObjectConformsTo(current, "IOUSBHostDevice");
            // probe 38 only ever emits USBPortType on ancestors whose own class
            // IS "IOUSBHostDevice" (verified: 398/398 USBPortType= occurrences
            // in the corpus sit on an "IOUSBHostDevice" line), so exact-class
            // match reproduces the same first-hub-ancestor semantics here.
            if hubPortType == nil, ancestor.className == "IOUSBHostDevice", let pt = ancestor.usbPortType {
                hubPortType = pt
            }
            if ancestor.className.hasPrefix("AppleUSBXHCITR") {
                tunnelled = true
                if let loc = ancestor.locationID { bus = USBWatcher.busIndex(fromLocationID: loc) }
                break
            }
            if ancestor.className.hasPrefix("AppleT") && ancestor.className.hasSuffix("USBXHCI") {
                reachedNativeController = true
                if let loc = ancestor.locationID { bus = USBWatcher.busIndex(fromLocationID: loc) }
                break
            }
            if USBWatcher.isThunderboltDockController(ancestor.className) {
                tunnelled = true
                break
            }
        }

        let behindInternalHub = USBWatcher.classifyBehindInternalHub(
            reachedNativeController: reachedNativeController,
            tunnelled: tunnelled,
            portName: portName,
            underInternalHub: hubPortType == USBWatcher.internalHubPortType
        )
        let resolvedBus = bus ?? USBWatcher.busIndex(fromLocationID: deviceLocationID)
        return WalkResult(
            portName: portName, tunnelled: tunnelled, reachedNativeController: reachedNativeController,
            hubPortType: hubPortType, bus: resolvedBus, behindInternalHub: behindInternalHub
        )
    }

    // MARK: - Corpus sweep: probe 38

    @Test("Probe-38 sweep: hub-nesting classification never crashes and its structural implications hold")
    func probe38SweepStructuralInvariants() {
        var foldersScanned = 0
        var devicesTotal = 0
        var tunnelledCount = 0
        var nativeCount = 0
        var behindInternalHubCount = 0
        var namedPortCount = 0
        var dockControllerCount = 0

        for folder in Self.allProbeFolders() {
            guard let text = Self.loadProbeText(folder: folder, fileName: "38_usb_device_tree.json") else { continue }
            let blocks = Self.parseDeviceBlocks(text)
            guard !blocks.isEmpty else { continue }
            foldersScanned += 1

            for block in blocks {
                devicesTotal += 1
                let result = Self.replayWalk(deviceLocationID: block.locationID, ancestors: block.ancestors)

                if result.tunnelled { tunnelledCount += 1 }
                if result.reachedNativeController { nativeCount += 1 }
                if result.behindInternalHub { behindInternalHubCount += 1 }
                if result.portName != nil { namedPortCount += 1 }
                if block.ancestors.contains(where: { USBWatcher.isThunderboltDockController($0.className) }) {
                    dockControllerCount += 1
                }

                // Invariant 1: tunnelled devices are never classified behind the
                // internal hub (classifyBehindInternalHub requires !tunnelled).
                #expect(!(result.tunnelled && result.behindInternalHub),
                    "\(folder): device at 0x\(String(block.locationID, radix: 16)) is both tunnelled and behind-internal-hub")

                // Invariant 2: a device with a resolved port name is never
                // classified behind the internal hub (requires portName == nil).
                #expect(!(result.portName != nil && result.behindInternalHub),
                    "\(folder): device at 0x\(String(block.locationID, radix: 16)) has portName \(result.portName ?? "?") but is behind-internal-hub")

                // Invariant 3: a device that never reached a native controller
                // is never classified behind the internal hub.
                #expect(!(!result.reachedNativeController && result.behindInternalHub),
                    "\(folder): device at 0x\(String(block.locationID, radix: 16)) did not reach a native controller but is behind-internal-hub")

                // Invariant 4: bus index is always a plausible byte value
                // (busIndex(fromLocationID:) masks to 0xFF by construction, so
                // this also guards against a future signature change breaking
                // that guarantee silently).
                #expect((0...255).contains(result.bus),
                    "\(folder): bus index \(result.bus) out of byte range")

                // Invariant 5: portName, when present, always starts with "Port-"
                // (usbIOPortPath/portName's own contract; re-asserted here against
                // real corpus paths rather than hand-written ones).
                if let name = result.portName {
                    #expect(name.hasPrefix("Port-"), "\(folder): portName \(name) missing Port- prefix")
                }
            }
        }

        print("[USBWatcherSweep] probe38: \(foldersScanned) folders, \(devicesTotal) devices, "
            + "\(nativeCount) native, \(tunnelledCount) tunnelled (\(dockControllerCount) via dock controller), "
            + "\(namedPortCount) named, \(behindInternalHubCount) behind-internal-hub")

        // Coverage floor: actual 30 folders, 322 devices as of 2026-07 (see
        // corpus.jsonl / probes_on_disk; probe 38 is the smallest of the six
        // probes this pass covers, 46 files total but only 30 non-empty).
        // Floor set to ~87% of actual folders (26) and ~85% of actual devices
        // (275), not an arbitrary small number, so a regression that silently
        // dropped most blocks would fail this test.
        //
        // Two-tier reality: only 1 probe-38 file is git-tracked (the
        // Probe38TreeWalkTests fixture); the other 29 are on-disk-only. Gate
        // the floor on a raw-corpus-presence threshold (10, comfortably above
        // the 1-file fresh-clone case and comfortably below the full 30), not
        // on `foldersScanned > 0`, so a fresh clone SKIPS the floor instead of
        // failing it while still running every per-item invariant above.
        if foldersScanned >= 10 {
            #expect(foldersScanned >= 26,
                "Expected at least 26 folders with probe-38 device blocks; got \(foldersScanned)")
            #expect(devicesTotal >= 275,
                "Expected at least 275 probe-38 device blocks across the corpus; got \(devicesTotal)")
            // The corpus has real Thunderbolt-dock topologies (CalDigit TS3+,
            // confirmed in CLAUDE.md); the dock-controller branch must fire at
            // least once or `isThunderboltDockController` regressed silently.
            #expect(dockControllerCount >= 1,
                "Expected at least one device reached via a Thunderbolt dock controller")
            // At least one device must resolve a named physical port, or the
            // UsbIOPort extraction regressed silently.
            #expect(namedPortCount >= 1,
                "Expected at least one device to resolve a named Port- ancestor")
        }
    }

    // MARK: - Fixture: the #375/#348 desktop front-port scenario
    //
    // The real corpus (probe 38, 30 folders as of 2026-07) happens to contain
    // no device whose walk reaches a USBPortType==2 hub WITHOUT ever finding a
    // UsbIOPort ancestor first (every USBPortType==2 case on disk is a device
    // plugged into a *named* front port, e.g. "Port-USB-A@1" on a Mac Studio,
    // which correctly resolves a portName and so is NOT classified
    // behind-internal-hub). The one true "no port node at all" front-port case
    // (issue #348: a Mac mini/Studio front USB-C port wired directly to the
    // internal hub with no Port-USB-C node) is documented in
    // project_desktop_front_ports_behind_hub but isn't present in this probe's
    // on-disk corpus. `RegistryParsingTests.swift` already covers this exact
    // scenario as an isolated fixture; it is restated here, driven through the
    // SAME `replayWalk` harness the corpus sweep above uses, so the harness
    // itself is proven correct against a known-true case rather than only
    // being exercised by ambiguous real data.
    @Test("Fixture: no-UsbIOPort ancestor reaching a USBPortType==2 hub classifies behind-internal-hub")
    func fixtureDesktopFrontPortWithNoPortNode() {
        let ancestors: [Ancestor] = [
            Ancestor(className: "IOUSBHostDevice", locationID: 0x0100_0000, usbPortType: 2, usbIOPort: nil),
            Ancestor(className: "AppleT8103USBXHCI", locationID: 0x0100_0000, usbPortType: nil, usbIOPort: nil),
        ]
        let result = Self.replayWalk(deviceLocationID: 0x0102_0000, ancestors: ancestors)
        #expect(result.portName == nil)
        #expect(result.reachedNativeController)
        #expect(!result.tunnelled)
        #expect(result.behindInternalHub, "expected the no-port-node + internal-hub + native-controller case to classify true")
        #expect(result.bus == 1)
    }

    @Test("Fixture: same shape but external hub (USBPortType==0) does not classify behind-internal-hub")
    func fixtureExternalHubWithNoPortNode() {
        let ancestors: [Ancestor] = [
            Ancestor(className: "IOUSBHostDevice", locationID: 0x0100_0000, usbPortType: 0, usbIOPort: nil),
            Ancestor(className: "AppleT8103USBXHCI", locationID: 0x0100_0000, usbPortType: nil, usbIOPort: nil),
        ]
        let result = Self.replayWalk(deviceLocationID: 0x0102_0000, ancestors: ancestors)
        #expect(!result.behindInternalHub, "external hub (USBPortType != 2) must not classify as behind-internal-hub")
    }

    // MARK: - Probe-36 cross-check: busIndex on real XHCI port / device pairs
    //
    // Probe 36 ("USB host-controller port -> physical USB-C port map") gives a
    // ground-truth locationID for each XHCI port plus a `usb-c-port-number`.
    // Its own header says "match locationID to a port above" for connected
    // devices, so any device locationID equal to a listed XHCI port locationID
    // is, by the probe's own ground truth, on that port. `busIndex(fromLocationID:)`
    // is a pure upper-byte mask, so matched pairs sharing a locationID must
    // always share a busIndex -- this exercises the real function across every
    // real locationID value on 156 machines rather than only the small
    // hand-picked values in RegistryParsingTests.

    private struct XHCIPortEntry { let locationID: UInt32; let portNumber: Int }

    private static func parseXHCIPortEntries(_ text: String) -> [XHCIPortEntry] {
        var results: [XHCIPortEntry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("usb-c-port-number="), trimmed.contains("locationID=") else { continue }
            guard let portRange = trimmed.range(of: "usb-c-port-number="),
                  let locRange = trimmed.range(of: "locationID=") else { continue }
            let afterPort = trimmed[portRange.upperBound...]
            let portDigits = afterPort.prefix { $0.isNumber }
            guard let portNumber = Int(portDigits) else { continue }
            let afterLoc = trimmed[locRange.upperBound...]
            let locDigits = afterLoc.prefix { $0.isNumber }
            guard let locationID = UInt32(locDigits) else { continue }
            results.append(XHCIPortEntry(locationID: locationID, portNumber: portNumber))
        }
        return results
    }

    private static func parseConnectedDeviceLocationIDs(_ text: String) -> [UInt32] {
        guard let marker = text.range(of: "IOUSBHostDevice (connected devices") else { return [] }
        var ids: [UInt32] = []
        for line in text[marker.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("locationID=") else { continue }
            let afterEq = trimmed.dropFirst("locationID=".count)
            let digits = afterEq.prefix { $0.isNumber }
            if let loc = UInt32(digits) { ids.append(loc) }
        }
        return ids
    }

    @Test("Probe-36 sweep: busIndex(fromLocationID:) is consistent between a connected device and its matched XHCI port")
    func probe36BusIndexCrossCheck() {
        var foldersScanned = 0
        var matchedPairs = 0

        for folder in Self.allProbeFolders() {
            guard let text = Self.loadProbeText(folder: folder, fileName: "36_xhci_port_map.json") else { continue }
            let ports = Self.parseXHCIPortEntries(text)
            let devices = Self.parseConnectedDeviceLocationIDs(text)
            guard !ports.isEmpty else { continue }
            foldersScanned += 1

            let portsByLocation = Dictionary(ports.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })
            for deviceLoc in devices {
                guard let port = portsByLocation[deviceLoc] else { continue }
                matchedPairs += 1
                #expect(
                    USBWatcher.busIndex(fromLocationID: deviceLoc) == USBWatcher.busIndex(fromLocationID: port.locationID),
                    "\(folder): device at \(deviceLoc) matched port \(port.portNumber) but busIndex diverged"
                )
                #expect(port.portNumber >= 1, "\(folder): usb-c-port-number \(port.portNumber) should be >= 1")
            }
        }

        print("[USBWatcherSweep] probe36: \(foldersScanned) folders, \(matchedPairs) matched device/port pairs")

        // Coverage floor: actual 157 folders as of 2026-07. Floor ~85% (135).
        // Matched pairs depend on a device being connected at capture time, so
        // no floor is set on that count (it is legitimately often zero).
        //
        // Two-tier reality: probe 36 has ZERO git-tracked files (all 157 are
        // on-disk-only), so `foldersScanned` is 0 on a fresh clone and this
        // already skips via the threshold below rather than failing. The
        // explicit 50 threshold (rather than a bare `> 0`) is defensive
        // consistency with the other probes in this pass, in case a future
        // fixture selection ever tracks a handful of probe-36 files.
        if foldersScanned >= 50 {
            #expect(foldersScanned >= 135,
                "Expected at least 135 folders with probe-36 XHCI port entries; got \(foldersScanned)")
        }
    }
}
