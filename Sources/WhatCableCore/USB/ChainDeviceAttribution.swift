import Foundation

/// Works out which Thunderbolt chain device each USB device sits inside.
///
/// The problem it solves: on a daisy chain (Mac -> display -> dock) macOS
/// publishes the USB devices as one flat forest per host controller with no
/// record of which downstream Thunderbolt device each one is physically plugged
/// into. The Thunderbolt fabric knows the chain exactly, and the USB tree knows
/// the hub cascade exactly, but nothing joins the two. Without a join, a dock's
/// Ethernet adapter renders five hub levels deep under the display the dock is
/// chained behind, which is where "12 rows, and you cannot tell what is plugged
/// into what" comes from.
///
/// No published technique exists for this on macOS, and `system_profiler
/// SPUSBDataType` returns nothing at all on the reference machine, so there is
/// no ground truth to copy. What follows is inference, and every step of it is
/// built to fail closed: **when the evidence does not single out one chain
/// device, the device stays unattributed and renders exactly where it does
/// today.** A wrong parent is worse than a flat list.
///
/// Three signals, in order of strength:
///
/// 1. **The name match.** A Thunderbolt device usually exposes its own USB
///    identity endpoint, and its `USB Product Name` is the same string the
///    fabric reports as `Device Model Name`. `TBT5 Docking Station 10-in-1`
///    appears in both. Two strengths of match, and the difference matters:
///    - **exact** (normalised equality): this device IS the chain device, so it
///      is absorbed into the chain row rather than rendered twice.
///    - **affiliate** (one name's words are a contiguous run inside the
///      other's): this device is PART OF the chain device. `TS5 USB 3 Hub` and
///      `CalDigit TS5 Audio - Rear` against a chain device modelled `TS5`;
///      `Apple Thunderbolt Display` against `Thunderbolt Display`. It marks its
///      hub but is never absorbed, because deleting a dock's audio endpoint
///      from the tree would be a bug, not a de-duplication.
///    Either way, the hub the device hangs off is that chain device's own
///    upstream hub, so everything under that hub is inside it.
/// 2. **Inheritance (structural).** Walking down the USB forest, a device takes
///    its nearest marked ancestor's owner. This is what separates a chained
///    dock's subtree from the display's while it sits nested inside it.
/// 3. **Vendor continuity (weakest, and heavily gated).** A device whose vendor
///    appears in exactly one chain device's marked region probably belongs to
///    that chain device. Applied top-down as a region mark, not per device, for
///    two reasons: it keeps a hub and its children together, and it makes the
///    collapsed and expanded views agree about where a device sits. An earlier
///    draft resolved it per endpoint in the collapsed view only, which put the
///    reference machine's Ethernet adapter under the dock by default and
///    somewhere else entirely once the user clicked "Show hubs".
///
/// Pure logic, no IOKit. `ConnectedDeviceTree` is the only caller.
public struct ChainDeviceAttribution: Equatable {
    /// USB device id -> chain switch id: every device the three signals could
    /// place, hubs included. Both view modes read this, so they cannot disagree
    /// about which chain device something is inside.
    public let regionOwner: [UInt64: Int64]

    /// The marked nodes: USB device id -> the chain switch id whose region
    /// starts there. The expanded view renders one nested subtree per entry.
    public let regionRoots: [UInt64: Int64]

    /// Devices that ARE a chain device (their own USB identity endpoint).
    /// Rendering both them and the chain row would duplicate the device, which
    /// is a good part of why the tree reads as a tangle today.
    public let absorbed: Set<UInt64>

    /// True when every chain device was anchored. Gates vendor continuity: see
    /// the `resolve` implementation for why a partial anchor set makes vendor
    /// evidence meaningless rather than merely weak.
    public let allAnchored: Bool

    public static let none = ChainDeviceAttribution(
        regionOwner: [:], regionRoots: [:], absorbed: [], allAnchored: false
    )

    /// Nothing was attributed and nothing absorbed, so the caller can render
    /// its existing layout unchanged.
    public var isEmpty: Bool { regionOwner.isEmpty && absorbed.isEmpty }

    // MARK: - Resolution

    /// - Parameters:
    ///   - chain: the downstream Thunderbolt tree for ONE port, as
    ///     `ThunderboltTopology.tree(from:in:)` returns it.
    ///   - forest: the USB device forest for the same port, as
    ///     `USBDeviceNode.buildTree(from:)` returns it.
    public static func resolve(
        chain: [IOThunderboltSwitchNode],
        forest: [USBDeviceNode]
    ) -> ChainDeviceAttribution {
        let chainNodes = ThunderboltTopology.flatten(chain)
        let allNodes = USBDeviceNode.flatten(forest)
        guard !chainNodes.isEmpty, !allNodes.isEmpty else { return .none }

        var nodeByID: [UInt64: USBDeviceNode] = [:]
        var parentOf: [UInt64: UInt64] = [:]
        for node in allNodes { nodeByID[node.device.id] = node }
        for node in allNodes {
            for child in node.children { parentOf[child.device.id] = node.device.id }
        }

        // 1. Anchors: a USB product name that matches a chain device's model
        // name. Matched against `modelName`, NOT
        // `ThunderboltLabels.deviceName(for:)`: that prepends the DROM vendor
        // ("Ugreen Group Limited TBT5 Docking Station 10-in-1") and would never
        // match the USB side. Names are whitespace-collapsed and case-folded
        // because the fabric reports "Studio Display " with a trailing space.
        var switchIDsByName: [String: Set<Int64>] = [:]
        for node in chainNodes {
            let key = normalized(node.sw.modelName)
            // Two characters is not a name, it is a chance collision.
            guard key.count >= 3 else { continue }
            switchIDsByName[key, default: []].insert(node.sw.id)
        }

        var exact: [UInt64: Int64] = [:]
        var affiliates: [UInt64: Int64] = [:]
        for node in allNodes {
            guard let product = node.device.productName else { continue }
            let key = normalized(product)
            guard key.count >= 3 else { continue }
            if let ids = switchIDsByName[key] {
                // Two chain devices with the same model name (two identical
                // daisy-chained displays: "UltraFine 4K" twice in the corpus)
                // cannot be told apart by name, so neither is matched.
                if ids.count == 1, let id = ids.first { exact[node.device.id] = id }
                continue
            }
            // Word-run containment, either direction, which is what catches the
            // families exact equality misses: CalDigit's entire TS line reports
            // `TS5` in the DROM and never once as a bare USB product name, so
            // without this it can never be recognised at all. Matching on whole
            // words rather than raw substrings keeps `TS5` out of an unrelated
            // `ATS5000`.
            let soft = chainNodes.filter {
                let model = normalized($0.sw.modelName)
                return model.count >= 3 && affiliated(product: product, model: $0.sw.modelName)
            }
            if soft.count == 1, let id = soft.first?.sw.id { affiliates[node.device.id] = id }
        }

        // 2. Region roots, in two passes: exact matches settle ownership, then
        // affiliate matches may only fill the gaps left over.
        //
        // The order is the point, and it is a correctness fix rather than tidying.
        // An affiliate match is a partial-name match, so a chain device whose
        // model name is a single generic word ("Hub", which clears the
        // three-character floor) matches the internal hub chips of completely
        // unrelated devices, because "USB3.0 Hub" contains the whole word "hub"
        // and so does nearly every hub descriptor ever written. Running both
        // strengths together let such a match re-parent a device that an exact
        // match had already placed inside a different chain device, moving its
        // whole subtree under an unrelated dock. Exact evidence going first, and
        // affiliate matches being refused wherever they would contradict it,
        // closes that without needing a list of words to distrust.
        //
        // A hub claimed by two DIFFERENT chain devices is claimed by neither.
        // Corpus counterexample: on `m4_macos26.5.2_x` an Echo 13 dock and the
        // Envoy Ultra chained behind it expose their identity endpoints on the
        // SAME hub, which means the hub is upstream of both. Letting either one
        // claim it (say, the deeper device) moved five of that machine's
        // endpoints inside a bare SSD.
        func claimTarget(_ deviceID: UInt64) -> UInt64? {
            guard let node = nodeByID[deviceID] else { return nil }
            if node.device.isHub { return deviceID }
            if let parentID = parentOf[deviceID], nodeByID[parentID]?.device.isHub == true {
                return parentID
            }
            return deviceID
        }
        // `contested` is the other half of the shared-hub guard, and it is not
        // optional bookkeeping. Refusing to MARK a disputed hub leaves it
        // unowned, and unowned is exactly what vendor continuity looks for, so
        // without this the hub the guard just protected gets handed to whichever
        // chain device happens to share its vendor. Recording where the
        // ambiguity was seen keeps that evidence available to the later pass.
        //
        // It gates vendor evidence only, deliberately. A disputed hub nested
        // inside another chain device's region still INHERITS that region, which
        // is a true statement and not a guess: a region root is the hub a chain
        // device's identity endpoint hangs off, so everything below it reaches the
        // Mac through that device. What that leaves is a row reading slightly more
        // definite than its evidence, not a wrong parent; both the reasoning and
        // the residual are set out in
        // `contestedSubtreeStillInheritsItsEnclosingRegion`.
        //
        // Slightly over-collects, harmlessly: a target contested in the affiliate
        // pass is recorded even when the exact pass resolved it cleanly. Anything
        // already owned never reaches the vendor branch, so the extra entry has no
        // effect.
        var contested: Set<UInt64> = []
        func marks(from matches: [UInt64: Int64]) -> [UInt64: Int64] {
            var claims: [UInt64: Set<Int64>] = [:]
            for (deviceID, switchID) in matches {
                guard let target = claimTarget(deviceID) else { continue }
                claims[target, default: []].insert(switchID)
            }
            for (target, switchIDs) in claims where switchIDs.count > 1 {
                contested.insert(target)
            }
            return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
        }

        var regionRoots = marks(from: exact)

        // 3. Inherit down the forest. A deeper mark overrides a shallower one,
        // which is exactly how a chained dock's subtree separates from the
        // display's while nested inside it.
        var regionOwner: [UInt64: Int64] = [:]
        func descend(_ node: USBDeviceNode, _ inherited: Int64?) {
            let owner = regionRoots[node.device.id] ?? inherited
            if let owner { regionOwner[node.device.id] = owner }
            for child in node.children { descend(child, owner) }
        }
        for root in forest { descend(root, nil) }

        // Affiliate marks now, keeping only those that do not contradict what
        // the exact pass established. Note this compares against the OWNER of
        // the hub being claimed, so an affiliate match is still free to open a
        // region inside an unowned part of the tree.
        let affiliateMarks = marks(from: affiliates).filter { target, switchID in
            guard let established = regionOwner[target] else { return true }
            return established == switchID
        }
        if !affiliateMarks.isEmpty {
            regionRoots.merge(affiliateMarks) { existing, _ in existing }
            regionOwner = [:]
            for root in forest { descend(root, nil) }
        }

        // 4. Vendor continuity, for what the structural pass could not place.
        //
        // Gated on every chain device having actually RESOLVED a region, which is
        // a correctness requirement and not caution. Vendor sets are built only
        // from resolved regions, so a chain device without one contributes no
        // vendors at all: a device physically inside dock B whose parents are VIA
        // Labs hubs would then be handed to dock A purely because dock A is the
        // only candidate with a vendor set, not because the vendor discriminates.
        // VIA Labs, Genesys Logic, Terminus and Fresco Logic hubs are inside
        // nearly every dock, so that failure mode is the common case, not an edge
        // one. With every chain device holding a region, "the vendor is in
        // exactly one set" is a real comparison between real candidates.
        //
        // This keys on regions and not on name matches, and the difference is a
        // hole that was open until an adversarial review found it: on a chain of
        // three where two devices name endpoints on one shared hub and the third
        // is cleanly matched, every device HAS a name match, yet only the third
        // holds a region. Keying on matches made the gate pass, and vendor
        // continuity then handed the disputed hub, plus everything inside the
        // first two devices, to the third. That is the exact wrong-parent
        // failure the shared-hub guard exists to prevent, reached by the other
        // path.
        let allAnchored = Set(regionRoots.values).count == chainNodes.count

        var vendorsBySwitch: [Int64: Set<UInt16>] = [:]
        for (deviceID, switchID) in regionOwner {
            guard let device = nodeByID[deviceID]?.device else { continue }
            vendorsBySwitch[switchID, default: []].insert(device.vendorID)
        }

        // Top-down, and the vendor sets are frozen from step 3: a device placed
        // here never widens a set and so never seeds a further inference.
        if allAnchored, !vendorsBySwitch.isEmpty {
            // `blocked` carries the contested finding down the subtree. A hub two
            // chain devices both named is upstream of both, so every device under
            // it is inside one of them and nothing here can say which: a vendor
            // mark on the hub OR on anything below it is a guess. Direct evidence
            // still wins inside that subtree, because `regionRoots` is consulted
            // first and a structural mark there was never in dispute.
            //
            // Found by a re-verification pass after the first attempt at this
            // guard, which only required every chain device to hold a region
            // somewhere. That is necessary but not sufficient: when the two
            // devices sharing a disputed hub each hold a second region elsewhere,
            // the gate opens legitimately and the disputed hub, still unowned, was
            // handed to an unrelated third device along with everything inside it.
            func vendorDescend(_ node: USBDeviceNode, _ inherited: Int64?, _ blocked: Bool) {
                let blockedHere = blocked || contested.contains(node.device.id)
                var owner = regionRoots[node.device.id] ?? inherited
                if owner == nil, !blockedHere {
                    let matches = vendorsBySwitch.filter { $0.value.contains(node.device.vendorID) }
                    // Exactly one candidate, or none: a vendor in two sets
                    // discriminates nothing, so the device stays put.
                    if matches.count == 1, let switchID = matches.keys.first {
                        owner = switchID
                        regionRoots[node.device.id] = switchID
                    }
                }
                if let owner { regionOwner[node.device.id] = owner }
                for child in node.children { vendorDescend(child, owner, blockedHere) }
            }
            for root in forest { vendorDescend(root, nil, false) }
        }

        // 5. Drop redundant marks: a region root whose nearest marked ancestor
        // has the same owner adds nothing, because inheritance already covers
        // its subtree. Left in, it would render that subtree TWICE in the
        // expanded view, once inside its ancestor and once as a region of its
        // own.
        //
        // Reachable, not theoretical: a CalDigit dock publishes both
        // `TS5 USB 3 Hub` (a hub, which marks itself) and
        // `CalDigit TS5 Audio - Rear` (an endpoint one level further in, which
        // marks the hub it hangs off). Two matches, same chain device, nested.
        // Decided against the marks as they stood, not against a set being
        // mutated underneath the loop: with a three-deep nest, each level has to
        // be judged against its real nearest ancestor rather than one that a
        // previous iteration has already removed.
        let marked = regionRoots
        for (id, owner) in marked {
            // `seen` is what makes this walk provably terminate: each pass either
            // stops or adds a new id to a finite set. `parentOf` is keyed by IOKit
            // entry ID rather than locationID, and while the forest itself cannot
            // contain a cycle (`parentLocationID` clears a nibble, so the path
            // strictly shortens), two devices arriving with the SAME entry ID
            // would collide in this map and could form one. A hang in the menu
            // bar app's render path is the worst outcome available here, so it is
            // ruled out structurally rather than assumed away.
            var seen: Set<UInt64> = [id]
            var cursor = parentOf[id]
            while let ancestor = cursor, !seen.contains(ancestor) {
                seen.insert(ancestor)
                if let ancestorOwner = marked[ancestor] {
                    if ancestorOwner == owner { regionRoots[id] = nil }
                    break
                }
                cursor = parentOf[ancestor]
            }
        }

        return ChainDeviceAttribution(
            regionOwner: regionOwner,
            regionRoots: regionRoots,
            absorbed: Set(exact.keys),
            allAnchored: allAnchored
        )
    }

    /// Whether a USB product name and a fabric model name name the same product
    /// family: one's words appear as a contiguous run inside the other's.
    ///
    /// Word-level, not substring, in both directions. `TS5` matches
    /// `TS5 USB 3 Hub` (the DROM carries the short name, the USB descriptors the
    /// long one) and `Thunderbolt Display` matches `Apple Thunderbolt Display`
    /// (the other way round), while `TS5` correctly fails against `ATS5000`.
    static func affiliated(product: String, model: String) -> Bool {
        let p = matchWords(product)
        let m = matchWords(model)
        guard !p.isEmpty, !m.isEmpty else { return false }
        return contains(p, m) || contains(m, p)
    }

    /// Whole words, punctuation dropped, so `Thunderbolt(TM) 4 Dock` and
    /// `Thunderbolt (TM) 4 Dock` compare equal and `USB2.0` splits the same way
    /// on both sides.
    private static func matchWords(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Whitespace-collapsed, case-folded name for matching a USB product name
    /// against a fabric model name. Internal punctuation is kept: it is part of
    /// the name ("10-in-1") and dropping it would let unrelated names collide.
    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
