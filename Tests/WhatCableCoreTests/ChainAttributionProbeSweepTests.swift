import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for `ChainDeviceAttribution`.
///
/// The attribution is inference over two IOKit surfaces that share no join key,
/// so the thing worth testing is not "does it place devices" but "does it ever
/// place one WRONGLY". Fixtures cannot answer that: they only contain the cases
/// somebody thought of. This replays the real corpus instead.
///
/// **Both inputs come from probes, and the fabric one was thought unavailable.**
/// `research/corpus-test-coverage.md` recorded that per-port fabric topology
/// could not be replayed from probe 29 because it lists switches and ports as
/// FLAT sections with no nesting. True, but incomplete: each switch block
/// carries `RegistryEntryID` and `ParentSwitchEntryID`, which is the same parent
/// link the live watcher uses, so the graph reconstructs exactly. That turns 30
/// daisy-chained machines into replay material where there were 4 tb-debug
/// dumps.
///
/// **Machines with more than one Thunderbolt chain are skipped**, and the count
/// is asserted so the skip cannot quietly become "all of them". Attribution runs
/// per port, and nothing in probe 29 or 38 says which port a tunnelled USB
/// device arrived on, so pairing a chain with the right devices is not possible
/// from this data. Sweeping them anyway would mean feeding the resolver one
/// port's chain and another port's devices, which is a fabricated input, and any
/// result from it would be meaningless.
///
/// Skips the full-corpus floors (not a fail) when too little of the corpus is
/// on disk to make a full-corpus claim: a fresh clone or worktree only has the
/// tracked fixtures, currently two folders
/// (`m3pro_macos27.0_l` / `_m`, added for the #493 regression below), which is
/// nowhere near the 40-chain floor. Per-folder correctness invariants still
/// run against whatever IS present, because those hold regardless of corpus
/// size.
@Suite("ChainDeviceAttribution corpus sweep")
struct ChainAttributionProbeSweepTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Probe loading

    private static func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path))?.sorted() ?? []
    }

    private static func probeText(_ folder: String, _ file: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 29: the fabric graph

    private struct RawSwitch {
        let entryID: Int64
        let parentEntryID: Int64
        let depth: Int
        let model: String
        let vendor: String
        let className: String
        /// Numeric DROM identity, read independently from the same probe
        /// text (own `intValue` parser, not production's `read(...)`
        /// closure): `Device Vendor ID` / `Device Model ID`. Distinct keys
        /// from the registry's plain `Vendor ID` / `Device ID` (the
        /// PCIe/controller chip identity), which this re-derivation does not
        /// read at all, matching production's `IOThunderboltSwitch.from`.
        let dromVendorID: Int?
        let dromModelID: Int?
    }

    /// Instance blocks for one IOKit class. Probe 29 writes
    /// `--- ClassName[N] "name" ---` headers inside `=== ClassName ===`
    /// sections, and a block ends at the next header or section.
    private static func blocks(_ text: String, className: String) -> [(name: String, body: String)] {
        var out: [(name: String, body: String)] = []
        var header: String?
        var body: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--- \(className)["), trimmed.hasSuffix("---") {
                if let h = header { out.append((h, body.joined(separator: "\n"))) }
                header = trimmed
                body = []
            } else if trimmed.hasPrefix("=== "), trimmed.hasSuffix(" ==="), header != nil {
                out.append((header!, body.joined(separator: "\n")))
                header = nil
                body = []
            } else if header != nil {
                body.append(line)
            }
        }
        if let h = header { out.append((h, body.joined(separator: "\n"))) }
        return out
    }

    private static func intValue(_ body: String, _ key: String) -> Int64? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key) = ") else { continue }
            let after = trimmed.dropFirst(key.count + 3).drop(while: { $0 == " " })
            let digits = after.prefix { $0.isNumber || $0 == "-" }
            if let v = Int64(digits) { return v }
        }
        return nil
    }

    private static func stringValue(_ body: String, _ key: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key) = ") else { continue }
            let after = trimmed.dropFirst(key.count + 3).drop(while: { $0 == " " })
            guard after.hasPrefix("\"") else { continue }
            let inner = after.dropFirst()
            if let close = inner.firstIndex(of: "\"") { return String(inner[..<close]) }
        }
        return nil
    }

    private static func rawSwitches(_ text: String) -> [RawSwitch] {
        var byEntry: [Int64: RawSwitch] = [:]
        for (name, body) in blocks(text, className: "IOThunderboltSwitch") {
            guard let entry = intValue(body, "RegistryEntryID"),
                  let depth = intValue(body, "Depth")
            else { continue }
            // Probe 29 can list the same node twice (once per host-root walk).
            byEntry[entry] = RawSwitch(
                entryID: entry,
                parentEntryID: intValue(body, "ParentSwitchEntryID") ?? 0,
                depth: Int(depth),
                model: stringValue(body, "Device Model Name") ?? "",
                vendor: stringValue(body, "Device Vendor Name") ?? "",
                className: name.replacingOccurrences(of: "--- IOThunderboltSwitch", with: ""),
                dromVendorID: intValue(body, "Device Vendor ID").map(Int.init),
                dromModelID: intValue(body, "Device Model ID").map(Int.init)
            )
        }
        return byEntry.values.sorted { $0.entryID < $1.entryID }
    }

    private static func model(_ raw: RawSwitch) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: raw.entryID,
            className: "IOThunderboltSwitch",
            vendorID: 0,
            vendorName: raw.vendor,
            modelName: raw.model,
            routerID: raw.depth,
            depth: raw.depth,
            routeString: 0,
            upstreamPortNumber: 1,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),
            ports: [],
            // Entry IDs stand in for UIDs here: the graph only needs the parent
            // link to be internally consistent, which it is.
            parentSwitchUID: raw.parentEntryID == 0 ? nil : raw.parentEntryID,
            dromVendorID: raw.dromVendorID,
            dromModelID: raw.dromModelID
        )
    }

    /// Downstream chains, one per host root that has anything below it.
    private static func chains(_ raws: [RawSwitch]) -> [[IOThunderboltSwitchNode]] {
        let switches = raws.map(model)
        return raws
            .filter { $0.depth == 0 }
            .map { ThunderboltTopology.tree(from: model($0), in: switches) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Probe 38: the USB forest

    /// Probe 38 writes `--- Device[N] ---` blocks with single-spaced
    /// `key = value` lines. Deliberately parsed here rather than reusing the
    /// copy in `ConnectedDeviceTreeTests`: an independent parser is the point.
    private static func usbDevices(_ text: String) -> [USBDevice] {
        var devices: [USBDevice] = []
        var body: [String] = []
        var index: UInt64 = 0

        func flush() {
            defer { body = [] }
            guard !body.isEmpty else { return }
            let joined = body.joined(separator: "\n")
            func hex(_ key: String) -> UInt32? {
                for line in body {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("\(key) = ") else { continue }
                    let v = t.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("0x") { return UInt32(v.dropFirst(2), radix: 16) }
                    return UInt32(v)
                }
                return nil
            }
            guard let loc = hex("locationID") else { return }
            index += 1
            devices.append(USBDevice(
                id: index,
                locationID: loc,
                vendorID: hex("idVendor").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                productID: hex("idProduct").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                vendorName: stringLine(joined, "USB Vendor Name"),
                productName: stringLine(joined, "USB Product Name"),
                serialNumber: nil,
                usbVersion: nil,
                speedRaw: hex("Device Speed").map { UInt8(truncatingIfNeeded: $0) },
                busPowerMA: nil,
                currentMA: nil,
                busIndex: Int(loc >> 24),
                deviceClass: hex("bDeviceClass").map { UInt8(truncatingIfNeeded: $0) },
                rawProperties: [:]
            ))
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("--- Device[") {
                flush()
            } else {
                body.append(line)
            }
        }
        flush()
        return devices
    }

    private static func stringLine(_ text: String, _ key: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\(key) = \"") else { continue }
            let inner = t.dropFirst(key.count + 4)
            if let close = inner.firstIndex(of: "\"") { return String(inner[..<close]) }
        }
        return nil
    }

    // MARK: - Independent re-derivations

    private static func normalise(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Independent re-derivation of the structural passes: exact name matches
    /// settle regions, then word-run matches fill gaps they do not contradict, a
    /// hub claimed by two different chain devices is claimed by neither.
    ///
    /// **Deliberately shares no code with production, including the word-run
    /// matcher.** An earlier version of this called
    /// `ChainDeviceAttribution.affiliated(product:model:)` directly, which meant
    /// a false positive in that function produced the identical wrong answer on
    /// both sides and every comparison below agreed with itself. Flagged in
    /// review, and it is the project's own rule: a check that reads the same
    /// source as the thing it checks certifies bugs rather than catching them.
    ///
    /// Returns the marks AND the set of chain devices that actually hold a
    /// region, which are different from the set that merely matched a name: where
    /// two chain devices name endpoints on one shared hub, both matched and
    /// neither holds a region. The vendor-continuity gate keys on regions, so the
    /// test has to re-derive that rather than read `allAnchored` back off the
    /// result. It read the result at first, which made the check agree with a
    /// mutation that removed the gate.
    /// Independent word-matching floor, mirroring the length-gate discipline
    /// `ChainDeviceAttribution` uses everywhere it compares two names
    /// (`key.count >= 3`, "two characters is not a name, it is a chance
    /// collision"): a name shorter than 3 characters after normalising is
    /// never treated as evidence, in either position.
    private static func vendorNamesMatch(_ a: String, _ b: String) -> Bool {
        guard normalise(a).count >= 3, normalise(b).count >= 3 else { return false }
        return wordRunMatch(a, b)
    }

    /// Chain device whose DROM (Device Vendor ID, Device Model ID) exactly
    /// equals a USB device's own (idVendor, idProduct), if any. Own
    /// re-derivation, reading the same `dromVendorID`/`dromModelID` fields
    /// `RawSwitch`/`model()` parsed independently above.
    ///
    /// Own re-derivation of production's two defensive rules (#493 round 5):
    /// zero never counts (a failed USB descriptor read defaults
    /// idVendor/idProduct to 0, and a fixture-constructed DROM pair could
    /// carry a raw 0 too), and the match SET is checked for ambiguity, not
    /// just existence, mirroring the file's duplicate-name rule: more than
    /// one chain device sharing an identical DROM VID+PID pair is refused,
    /// not resolved to "whichever comes first".
    private static func numericIdentity(of device: USBDevice, chain: [IOThunderboltSwitchNode]) -> IOThunderboltSwitchNode? {
        guard device.vendorID != 0, device.productID != 0 else { return nil }
        let matches = chain.filter {
            guard let dvid = $0.sw.dromVendorID, dvid != 0,
                  let dmid = $0.sw.dromModelID, dmid != 0
            else { return false }
            return dvid == Int(device.vendorID) && dmid == Int(device.productID)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Set of chain devices whose DROM vendor id equals `vid`, zero-guarded.
    /// Own re-derivation of production's `chainDevicesWithDROMVendorID`.
    private static func chainDevicesWithDROMVendorID(_ vid: Int, chain: [IOThunderboltSwitchNode]) -> [IOThunderboltSwitchNode] {
        guard vid != 0 else { return [] }
        return chain.filter { $0.sw.dromVendorID == vid }
    }

    /// Independent re-derivation of `ChainDeviceAttribution.claimTarget`'s
    /// #493 fix (round 4, numeric-first), shared between `structuralMarks`
    /// and the conflict-guard recheck in `sweep()` (both need the SAME
    /// redirection decision, and duplicating it risked the two drifting apart
    /// the way the original unconditional-promotion assumption did). Own
    /// function, own word-matching (`wordRunMatch` via `vendorNamesMatch`)
    /// and own numeric lookup (`numericIdentity` above), nothing shared with
    /// production.
    ///
    /// Same four tiers as production, in the same order: (a)/(b) the hub's
    /// OWN idVendor/idProduct exactly identifies it as a chain device,
    /// decisive either way; (c) the claiming endpoint is numerically
    /// identified but the hub is not, so VID-only decides (the multi-chip
    /// dock pattern) when it can, else falls through; (d) no numeric
    /// evidence at all: the ORIGINAL (round 2) string rule, a hub vendor name
    /// match to the claimer winning over a match to a different chain device.
    /// Returns the redirection target AND the switch id the claim is now
    /// recorded against, since numeric identity can override the NAME
    /// match's switch id when the two disagree.
    private static func claimTarget(
        _ device: USBDevice,
        claimedBy switchID: Int64,
        chain: [IOThunderboltSwitchNode],
        byLocation: [UInt32: USBDevice]
    ) -> (target: UInt64, switchID: Int64) {
        // Computed FIRST, before any early return, and used on every return
        // path, including the hub-claimant and no-hub-parent ones below.
        // Own re-derivation of production's round-5 fix: an earlier version
        // (matching production's own earlier bug) only computed this on the
        // has-a-hub-parent path.
        let endpointIdentity = numericIdentity(of: device, chain: chain)
        let effectiveSwitchID = endpointIdentity?.sw.id ?? switchID

        if device.isHub { return (device.id, effectiveSwitchID) }
        guard let parentLoc = USBDevice.parentLocationID(device.locationID),
              let parent = byLocation[parentLoc], parent.isHub
        else { return (device.id, effectiveSwitchID) }

        if let hubIdentity = numericIdentity(of: parent, chain: chain) {
            return hubIdentity.sw.id == effectiveSwitchID
                ? (parent.id, effectiveSwitchID)
                : (device.id, effectiveSwitchID)
        }

        if let endpointIdentity {
            // Set-based, mirroring `numericIdentity`'s own ambiguity rule:
            // ANY different chain device sharing the hub's VID refuses, even
            // if the claimer is also in the set; only an EXACT {claimer} set
            // promotes; an empty set falls through.
            let hubVID = Int(parent.vendorID)
            let matchingChainDevices = chainDevicesWithDROMVendorID(hubVID, chain: chain)
            if matchingChainDevices.contains(where: { $0.sw.id != endpointIdentity.sw.id }) {
                return (device.id, effectiveSwitchID)
            }
            if matchingChainDevices.count == 1 {
                return (parent.id, effectiveSwitchID)
            }
            // Falls through: VID-only inconclusive, string tier decides.
        }

        // Tier (d): round-2 string ordering, unchanged. A hub vendor name
        // match to the claimer, its own vendor or its chain device's DROM
        // vendor, wins over a match to a different chain device.
        guard let hubVendor = parent.vendorName else { return (parent.id, effectiveSwitchID) }
        var chainVendorByID: [Int64: String] = [:]
        for node in chain { chainVendorByID[node.sw.id] = node.sw.vendorName }
        let matchesClaimingDevice = device.vendorName.map { vendorNamesMatch(hubVendor, $0) } ?? false
        let matchesClaimingChain = chainVendorByID[effectiveSwitchID].map { vendorNamesMatch(hubVendor, $0) } ?? false
        if matchesClaimingDevice || matchesClaimingChain { return (parent.id, effectiveSwitchID) }
        let namesADifferentChainDevice = chain.contains { other in
            other.sw.id != effectiveSwitchID && vendorNamesMatch(hubVendor, other.sw.vendorName)
        }
        return namesADifferentChainDevice ? (device.id, effectiveSwitchID) : (parent.id, effectiveSwitchID)
    }

    private static func structuralMarks(
        chain: [IOThunderboltSwitchNode],
        devices: [USBDevice]
    ) -> (marks: [UInt64: Int64], resolvedSwitches: Set<Int64>, affiliateMarksRefused: Int) {
        let byLocation = Dictionary(devices.map { ($0.locationID, $0) }, uniquingKeysWith: { a, _ in a })
        let forest = USBDeviceNode.buildTree(from: devices)

        func marks(_ matches: [(device: USBDevice, switchID: Int64)]) -> [UInt64: Int64] {
            var claims: [UInt64: Set<Int64>] = [:]
            for match in matches {
                let (target, effectiveSwitchID) = Self.claimTarget(
                    match.device, claimedBy: match.switchID,
                    chain: chain, byLocation: byLocation
                )
                claims[target, default: []].insert(effectiveSwitchID)
            }
            return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
        }

        func ownership(_ current: [UInt64: Int64]) -> [UInt64: Int64] {
            var owner: [UInt64: Int64] = [:]
            func walk(_ node: USBDeviceNode, _ inherited: Int64?) {
                let mine = current[node.device.id] ?? inherited
                if let mine { owner[node.device.id] = mine }
                for child in node.children { walk(child, mine) }
            }
            for root in forest { walk(root, nil) }
            return owner
        }

        var exactMatches: [(device: USBDevice, switchID: Int64)] = []
        var softMatches: [(device: USBDevice, switchID: Int64)] = []
        for device in devices {
            guard let product = device.productName, normalise(product).count >= 3 else { continue }
            let named = chain.filter { normalise($0.sw.modelName).count >= 3 }
            let exact = named.filter { normalise($0.sw.modelName) == normalise(product) }
            if !exact.isEmpty {
                if exact.count == 1, let id = exact.first?.sw.id {
                    exactMatches.append((device, id))
                }
                continue
            }
            let soft = named.filter { wordRunMatch(product, $0.sw.modelName) }
            if soft.count == 1, let id = soft.first?.sw.id { softMatches.append((device, id)) }
        }

        var result = marks(exactMatches)
        let afterExact = ownership(result)
        var refused = 0
        for (id, switchID) in marks(softMatches) {
            if let established = afterExact[id], established != switchID {
                refused += 1
                continue
            }
            if result[id] == nil { result[id] = switchID }
        }
        return (result, Set(result.values), refused)
    }

    /// Word-run containment, either direction, written from the rule rather than
    /// from the production implementation: one name's words must appear as an
    /// unbroken run inside the other's.
    private static func wordRunMatch(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            var out: [String] = []
            var current = ""
            for character in s.lowercased() {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func run(_ needle: [String], in haystack: [String]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            var start = 0
            while start + needle.count <= haystack.count {
                var offset = 0
                while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
                start += 1
            }
            return false
        }
        let left = words(a)
        let right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return run(right, in: left) || run(left, in: right)
    }

    // MARK: - The sweep

    @Test("Corpus sweep: attribution never places a device wrongly, and degrades where it cannot tell")
    func sweep() throws {
        var swept = 0
        var skippedMultiChain = 0
        var withProbes = 0
        var chainDevices = 0
        var multiDeviceChains = 0
        var absorbedTotal = 0
        var marks = 0
        var vendorMarks = 0
        var conflictGuardFired = 0
        var affiliateMarksRefused = 0
        var allAnchoredChains = 0
        var multiDeviceAllAnchored = 0
        var placedEndpoints = 0
        var pins: [String: String] = [:]

        for folder in Self.folders() {
            guard let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
                  let text38 = Self.probeText(folder, "38_usb_device_tree.json")
            else { continue }
            let raws = Self.rawSwitches(text29)
            let allChains = Self.chains(raws)
            let devices = Self.usbDevices(text38)
            guard !allChains.isEmpty, !devices.isEmpty else { continue }
            withProbes += 1
            guard allChains.count == 1 else { skippedMultiChain += 1; continue }
            let chain = allChains[0]
            // Flattened, because a chain node carries its children: the chain's
            // DEVICES are the flattened list, and `chain` itself is only its
            // first hops. Getting this wrong made the first run of this sweep
            // fail on the code rather than on the data.
            let chainNodes = ThunderboltTopology.flatten(chain)
            swept += 1

            let forest = USBDeviceNode.buildTree(from: devices)
            let flat = USBDeviceNode.flatten(forest)
            let result = ChainDeviceAttribution.resolve(chain: chain, forest: forest)

            var parentOf: [UInt64: UInt64] = [:]
            for node in flat {
                for child in node.children { parentOf[child.device.id] = node.device.id }
            }
            let chainIDs = Set(chainNodes.map(\.sw.id))
            let deviceIDs = Set(devices.map(\.id))
            chainDevices += chainNodes.count
            if chainNodes.count > 1 { multiDeviceChains += 1 }
            if result.allAnchored {
                allAnchoredChains += 1
                if chainNodes.count > 1 { multiDeviceAllAnchored += 1 }
            }
            absorbedTotal += result.absorbed.count
            marks += result.regionRoots.count

            // 1. Every owner is a real chain device on THIS port, and every
            // marked or owned id is a real device.
            for (deviceID, switchID) in result.regionOwner {
                #expect(chainIDs.contains(switchID), "\(folder): owner \(switchID) is not a chain device on this port")
                #expect(deviceIDs.contains(deviceID), "\(folder): owned id \(deviceID) is not a device")
            }
            for (deviceID, switchID) in result.regionRoots {
                #expect(deviceIDs.contains(deviceID), "\(folder): marked id \(deviceID) is not a device")
                #expect(result.regionOwner[deviceID] == switchID,
                    "\(folder): device \(deviceID) is marked for \(switchID) but owned by \(String(describing: result.regionOwner[deviceID]))")
            }
            #expect(result.absorbed.isSubset(of: deviceIDs), "\(folder): absorbed an id that is not a device")

            // 2. Ownership is inheritance-consistent: a device's owner is its
            // nearest marked ancestor's mark, itself included. Walked here from
            // the forest, not read back off the result.
            for node in flat {
                var expected: Int64?
                var cursor: UInt64? = node.device.id
                while let id = cursor {
                    if let mark = result.regionRoots[id] { expected = mark; break }
                    cursor = parentOf[id]
                }
                #expect(result.regionOwner[node.device.id] == expected,
                    "\(folder): device \(node.device.id) owner \(String(describing: result.regionOwner[node.device.id])) is not its nearest mark \(String(describing: expected))")
            }

            // 3. Everything absorbed names a chain device exactly, and uniquely.
            // This re-checks the absorb rule against the raw strings rather than
            // trusting the resolver's own matching.
            for id in result.absorbed {
                guard let device = devices.first(where: { $0.id == id }),
                      let product = device.productName else {
                    Issue.record("\(folder): absorbed id \(id) has no product name")
                    continue
                }
                let matching = chainNodes.filter { Self.normalise($0.sw.modelName) == Self.normalise(product) }
                #expect(matching.count == 1,
                    "\(folder): absorbed '\(product)' which matches \(matching.count) chain devices, not 1")
            }

            // 4. Vendor continuity is off unless every chain device is matched,
            // and when it is off the marks are exactly the structural ones.
            let (structural, resolvedSwitches, refusedHere) = Self.structuralMarks(chain: chainNodes, devices: devices)
            affiliateMarksRefused += refusedHere
            // Counted as marks the structural pass did not produce, not as a
            // count difference: production collapses redundant nested marks, so
            // the two sets differ in both directions.
            vendorMarks += result.regionRoots.keys.filter { structural[$0] == nil }.count
            let everyChainDeviceResolved = resolvedSwitches.count == chainNodes.count
            #expect(result.allAnchored == everyChainDeviceResolved,
                "\(folder): the vendor-continuity gate says \(result.allAnchored) but \(resolvedSwitches.count) of \(chainNodes.count) chain devices hold a region")

            // Compared as OWNERSHIP, not as mark sets. The two are not the same
            // thing: production drops a mark whose nearest marked ancestor has
            // the same owner, because inheritance already covers that subtree and
            // keeping it would render the subtree twice. `m2max_macos26.5.2_f`
            // (a CalDigit TS5, which names itself twice at two nesting levels) is
            // the real case. Ownership is what the rows are built from, so
            // ownership is what has to agree.
            var expectedOwner: [UInt64: Int64] = [:]
            func inherit(_ node: USBDeviceNode, _ inherited: Int64?) {
                let owner = structural[node.device.id] ?? inherited
                if let owner { expectedOwner[node.device.id] = owner }
                for child in node.children { inherit(child, owner) }
            }
            for root in forest { inherit(root, nil) }

            if !everyChainDeviceResolved {
                #expect(result.regionOwner == expectedOwner,
                    "\(folder): ownership differs from the structural pass on a chain that is not fully matched, so vendor continuity ran when it should not have")
            } else {
                // Vendor continuity may place MORE devices, never move one the
                // structure already placed.
                for (id, owner) in expectedOwner {
                    #expect(result.regionOwner[id] == owner,
                        "\(folder): vendor continuity overrode structural ownership on device \(id)")
                }
            }

            // No mark may sit under another mark for the same chain device: that
            // is the duplicate-subtree bug above, and it is only detectable here
            // as an invariant on the result.
            for (id, owner) in result.regionRoots {
                var cursor = parentOf[id]
                while let ancestor = cursor {
                    if let ancestorOwner = result.regionRoots[ancestor] {
                        #expect(ancestorOwner != owner,
                            "\(folder): device \(id) is marked for the same chain device as its ancestor \(ancestor), so its subtree would render twice")
                        break
                    }
                    cursor = parentOf[ancestor]
                }
            }

            // 5. The conflict guard: a hub two chain devices both name is marked
            // for neither. Detected by finding a hub with two distinct claims.
            //
            // Claims are grouped by their `claimTarget` REDIRECTION, not
            // unconditionally against the parent hub: a device whose claim
            // stays on itself (the #493 block firing) was never a claim on
            // the hub to begin with, and grouping it there anyway is the same
            // unconditional-promotion assumption the #493 fix removed from
            // production, just reintroduced here. Two Codex-review findings
            // landed on this exact spot for that reason.
            //
            // The two match strengths are kept SEPARATE, not unioned into one
            // claim set: production runs the exact pass first and lets its
            // ownership stand, then folds affiliate matches in only where
            // they do NOT contradict what the exact pass already established
            // (see `marks(from:)`'s affiliate filter in production and in
            // `structuralMarks` above). Unioning the two here (an earlier
            // version of this oracle did, with a comment claiming production
            // "unions them", which is wrong) asserted a hub unowned whenever
            // ANY exact claim disagreed with ANY affiliate claim on it, even
            // though production keeps the exact owner and silently drops the
            // conflicting affiliate one in that case. A conflict WITHIN the
            // exact pass (two distinct exact-matched chain devices naming the
            // same hub) always leaves it unowned, matching the original
            // shared-hub guard. A conflict WITHIN the affiliate pass only
            // leaves it unowned when no exact claim already won there first.
            let byLocation = Dictionary(devices.map { ($0.locationID, $0) }, uniquingKeysWith: { a, _ in a })
            var exactClaimsPerHub: [UInt64: Set<Int64>] = [:]
            var affiliateClaimsPerHub: [UInt64: Set<Int64>] = [:]
            for device in devices {
                guard let product = device.productName, Self.normalise(product).count >= 3 else { continue }
                let named = chainNodes.filter { Self.normalise($0.sw.modelName).count >= 3 }
                let exact = named.filter { Self.normalise($0.sw.modelName) == Self.normalise(product) }
                let isExact = !exact.isEmpty
                let matching = isExact ? exact : named.filter { Self.wordRunMatch(product, $0.sw.modelName) }
                guard matching.count == 1, let switchID = matching.first?.sw.id else { continue }
                let (target, effectiveSwitchID) = Self.claimTarget(
                    device, claimedBy: switchID,
                    chain: chainNodes, byLocation: byLocation
                )
                guard target != device.id else { continue }
                if isExact {
                    exactClaimsPerHub[target, default: []].insert(effectiveSwitchID)
                } else {
                    affiliateClaimsPerHub[target, default: []].insert(effectiveSwitchID)
                }
            }

            func assertUnowned(_ hubID: UInt64, claimCount: Int) {
                conflictGuardFired += 1
                #expect(result.regionRoots[hubID] == nil,
                    "\(folder): hub \(hubID) is named by \(claimCount) chain devices and must belong to none of them")
                // And nothing under it may be claimed either. The test for that
                // is deliberately "unowned, or owned via a mark the STRUCTURAL
                // re-derivation also produced": accepting any mark at all would
                // let a vendor-derived one satisfy it, which is the very thing
                // being guarded against, since a device under a disputed hub is
                // inside one of the two contenders and nothing says which.
                for node in flat where node.device.id == hubID {
                    for child in USBDeviceNode.flatten(node.children) {
                        #expect(result.regionOwner[child.device.id] == nil
                                || structural[child.device.id] != nil,
                            "\(folder): device \(child.device.id) was claimed under a hub that belongs to nobody")
                    }
                }
            }

            for (hubID, claims) in exactClaimsPerHub where claims.count > 1 {
                assertUnowned(hubID, claimCount: claims.count)
            }
            for (hubID, claims) in affiliateClaimsPerHub where claims.count > 1 {
                // Skip when a single (uncontested) exact claim already won
                // this hub: production keeps that owner and just drops the
                // conflicting affiliate claims, it does not become unowned.
                guard (exactClaimsPerHub[hubID]?.count ?? 0) != 1 else { continue }
                assertUnowned(hubID, claimCount: claims.count)
            }

            placedEndpoints += flat.filter { !$0.device.isHub && result.regionOwner[$0.device.id] != nil }.count

            // Named pins. Folder suffix letters are positional, so these are
            // pinned by the shape they were chosen for and skipped if the shape
            // changes, rather than asserted blind.
            if folder == "m4_macos26.5.2_x", chainNodes.count == 2 {
                pins["m4_macos26.5.2_x"] = "marks=\(result.regionRoots.count) absorbed=\(result.absorbed.count)"
                #expect(result.regionRoots.isEmpty,
                    "m4_macos26.5.2_x: both chain devices name endpoints on one hub, so nothing may be marked")
            }
            if folder == "m5_macos26.5.1_p", chainNodes.count == 2 {
                let lan = devices.first { $0.productName?.contains("10_100_1000 LAN") == true }
                if let lan, let owner = result.regionOwner[lan.id] {
                    let name = chainNodes.first { $0.sw.id == owner }?.sw.modelName ?? "?"
                    pins["m5_macos26.5.1_p"] = "LAN owner=\(name)"
                    #expect(name.contains("Docking Station"),
                        "m5_macos26.5.1_p: the Ethernet adapter is in the dock, not the \(name)")
                }
            }
        }

        // Floors, only meaningful when the corpus is on disk. No probe-29 file
        // was tracked in git, so a fresh clone swept zero folders and this
        // test passed without asserting anything: a known gap, not a pass.
        // #493 added the first two tracked probe-29 fixtures
        // (m3pro_macos27.0_l / _m, for the regression test below), so a
        // fresh clone or worktree now sweeps those two and nothing else.
        // Per-folder invariants (checks 1-5 in the loop above) still run
        // against whatever is on disk, because those are correctness
        // properties that hold regardless of corpus size. The floors right
        // below make a claim about the FULL corpus, not "whatever happens to
        // be present", so they need their own stronger gate: skip (not
        // fail) when `swept` doesn't clear the same bar the floor asserts,
        // matching the skip-not-fail convention in
        // PowerSourceSynthesisProbeSweepTests / PDODecodeCorpusSweepTests.
        print("""
            [chain attribution sweep] folders with both probes: \(withProbes), swept: \(swept), \
            skipped (2+ chains, port unknowable): \(skippedMultiChain)
              chain devices: \(chainDevices), multi-device chains: \(multiDeviceChains)
              fully matched: \(allAnchoredChains) chains, of which multi-device: \(multiDeviceAllAnchored)
              marks: \(marks) (vendor-derived: \(vendorMarks)), absorbed: \(absorbedTotal), \
            endpoints placed: \(placedEndpoints)
              conflict guard fired on \(conflictGuardFired) hub(s), affiliate marks refused: \(affiliateMarksRefused)
              pins: \(pins)
            """)
        guard swept >= 40 else {
            print("[chain attribution sweep] skipping full-corpus floors: only \(swept) chain(s) swept")
            return
        }
        // Non-vacuity floors. Measured on the 2026-07-30 corpus: 84 chains
        // swept, 111 chain devices, 24 multi-device chains, 23 with every chain
        // device holding a region (4 of them multi-device), 77 marks of which 46
        // vendor-derived, 30 absorbed, 145 endpoints placed, 1 conflict. Every one of those figures
        // was produced independently by a Python re-implementation over the same
        // probes first and matched exactly. Floors sit below the measurements so
        // new submissions cannot fail the build, but a resolver that quietly
        // stopped attributing anything would.
        #expect(swept >= 40, "swept only \(swept) chains; the sweep is barely covering anything")
        #expect(multiDeviceChains >= 10, "no daisy chains swept, which is the case this feature exists for")
        #expect(marks >= 20, "the structural pass placed almost nothing; it is probably broken")
        #expect(absorbedTotal >= 15, "nothing was absorbed; the exact-match rule is probably broken")
        #expect(allAnchoredChains >= 1, "no fully matched chain, so vendor continuity was never exercised")
        #expect(multiDeviceAllAnchored >= 1, "no fully matched DAISY chain, which is the case the whole ticket is about")
        #expect(vendorMarks >= 1, "vendor continuity never produced a mark")
        #expect(conflictGuardFired >= 1, "the shared-hub guard was never exercised by real data")
        // Deliberately NOT asserted: measured at 0 on the 2026-07-30 corpus. No
        // corpus machine has a chain device whose model name partly matches a
        // device an exact match already placed inside a DIFFERENT chain device, so
        // this sweep cannot catch a regression in the exact-settles-first rule.
        // Confirmed by mutation: removing that rule leaves this sweep green.
        // `affiliateMatchCannotOverrideAnExactMatch` is the only guard on it, and
        // it is a fixture for exactly that reason. If this number ever goes
        // non-zero the shape has arrived in real data and the sweep starts
        // covering it.
        #expect(skippedMultiChain < withProbes, "every folder was skipped; the sweep is vacuous")
    }

    // MARK: - Regression: issue #493

    /// `m3pro_macos27.0_l`: the OWC Express 1M2 (a single-port NVMe
    /// enclosure, no hub of its own) sits as a plain sibling of the CalDigit
    /// TB4 Pro Dock's shared internal "TBT4 Pro USB2.0 Hub". Its USB product
    /// name exactly matches the chain device model name "Express 1M2", so it
    /// gets absorbed and its claim looked for a parent hub to promote to.
    /// Before the fix, `claimTarget` promoted unconditionally, handing the
    /// CalDigit hub and its six descendants (the OWC device itself, a TI
    /// power chip, and four more CalDigit-branded nodes: three hub chips and
    /// one `IOUSBHostDevice`) to the OWC. The shared-hub guard never fired
    /// because only ONE chain device named the hub.
    ///
    /// **Round 4 (numeric-first): this now resolves on NUMBERS, not
    /// strings.** The OWC endpoint's own `idVendor`/`idProduct` (0x174c /
    /// 0x2465) exactly match the OWC Express 1M2 chain device's own DROM
    /// (`Device Vendor ID` / `Device Model ID`), so `claimTarget`'s numeric
    /// identity confirms the name match rather than overriding it. The
    /// CalDigit hub's own `idVendor`/`idProduct` (0x2188 / 0x5803) match no
    /// chain device's DROM exactly (the CalDigit dock's own DROM model id is
    /// 0x5988, not 0x5803: the hub is one of the dock's internal chips), so
    /// tier (a)/(b) do not fire; the hub's VID (0x2188) does equal the
    /// CalDigit dock's DROM vendor id, a DIFFERENT chain device from the OWC
    /// (0x174c), so tier (c) refuses the promotion. The vendor-name STRING
    /// tier (d) is never reached at all for this folder.
    ///
    /// Proven red on the unfixed code: temporarily reverting `claimTarget`'s
    /// #493 change (both the round-3 string-only rule and, separately, the
    /// round-4 numeric rule) and running this test failed with the CalDigit
    /// hub owned by the OWC's switch id, exactly the bug. See the PR
    /// description for the captured failure output.
    @Test("Regression #493: a lone claim over a shared dock hub is not promoted to it")
    func regression493SharedDockHubNotClaimedByLoneDevice() throws {
        let folder = "m3pro_macos27.0_l"
        guard let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
              let text38 = Self.probeText(folder, "38_usb_device_tree.json")
        else {
            // Raw probes are gitignored except for tracked replay fixtures.
            // This folder's 29 + 38 are tracked specifically so this
            // regression replays on a fresh clone; if they are ever missing,
            // skip rather than silently pass on the wrong premise.
            Issue.record("\(folder): probe 29 or 38 fixture missing; #493 regression cannot replay")
            return
        }
        let raws = Self.rawSwitches(text29)
        let allChains = Self.chains(raws)
        let devices = Self.usbDevices(text38)
        try #require(allChains.count == 1, "\(folder): expected exactly one Thunderbolt chain")
        let chain = allChains[0]
        let chainNodes = ThunderboltTopology.flatten(chain)
        let forest = USBDeviceNode.buildTree(from: devices)
        let flat = USBDeviceNode.flatten(forest)

        let owcSwitch = try #require(
            chainNodes.first { $0.sw.modelName == "Express 1M2" },
            "\(folder): expected an 'Express 1M2' chain device"
        )
        let owcDevice = try #require(
            devices.first { $0.productName == "Express 1M2" },
            "\(folder): expected an 'Express 1M2' USB device"
        )
        let hubNode = try #require(
            flat.first { $0.device.id == owcDevice.id }.flatMap { owc in
                flat.first { $0.children.contains(where: { $0.device.id == owc.device.id }) }
            },
            "\(folder): expected the Express 1M2 to have a parent hub node"
        )
        #expect(hubNode.device.productName == "TBT4 Pro USB2.0 Hub")
        #expect(hubNode.device.vendorName?.contains("CalDigit") == true)

        // The descendants the bug drags along with the hub. Asserted
        // non-empty FIRST: without this, every negative assertion below
        // (nothing under the hub is owned by the OWC) would pass vacuously
        // on a resolver, or a probe fixture, that produced no attribution at
        // all, or on a fixture whose hub happens to have no children.
        let hubDescendants = USBDeviceNode.flatten(hubNode.children).filter { $0.device.id != owcDevice.id }
        try #require(!hubDescendants.isEmpty,
            "\(folder): expected the CalDigit hub to have descendants besides the OWC device; the fixture may have changed shape")

        let result = ChainDeviceAttribution.resolve(chain: chain, forest: forest)

        // Positive: the OWC device itself IS owned by, and absorbed into, its
        // own switch's region. This is the exact-match/absorb rule working as
        // intended, and it is what makes the negative checks below meaningful
        // rather than a resolver that attributed nothing at all.
        #expect(result.absorbed.contains(owcDevice.id),
            "\(folder): the OWC's own identity endpoint must be absorbed into its chain device")
        #expect(result.regionOwner[owcDevice.id] == owcSwitch.sw.id,
            "\(folder): the OWC's own identity endpoint must be owned by its own switch id")

        // Positive: the CalDigit hub's final state, asserted explicitly
        // rather than only "not the OWC". The fixed code leaves it UNOWNED,
        // not reattributed to the CalDigit dock: the hub's vendor
        // ("CalDigit, Inc.") matches the CalDigit dock, a DIFFERENT chain
        // device from the OWC, so `claimTarget` refuses to promote the OWC's
        // claim onto it, but nothing on this fabric independently claims the
        // hub FOR the CalDigit dock either (the dock's own identity endpoint
        // sits on a different hub). An unowned hub is the file's documented
        // fail-closed behaviour: "when the evidence does not single out one
        // chain device, the device stays unattributed."
        #expect(result.regionOwner[hubNode.device.id] == nil,
            "\(folder): the CalDigit hub must be unowned, not reattributed to anyone")
        #expect(
            result.regionOwner[hubNode.device.id] != owcSwitch.sw.id,
            "\(folder): the CalDigit hub must not be claimed by the OWC's switch id \(owcSwitch.sw.id)"
        )
        // The OWC device itself is excluded: it IS meant to be owned by its
        // own switch id (that is the absorb rule working correctly, checked
        // positively above). The bug this guards against is everything ELSE
        // under the shared hub, e.g. the other CalDigit hub chips and the TI
        // power chip, being dragged along with it.
        for descendant in hubDescendants {
            #expect(
                result.regionOwner[descendant.device.id] != owcSwitch.sw.id,
                "\(folder): CalDigit hub descendant \(descendant.device.productName ?? "?") must not be attributed to the OWC's switch id \(owcSwitch.sw.id)"
            )
        }
    }
}
