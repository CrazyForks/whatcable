import Foundation
import Testing
@testable import WhatCableCore

/// Unit tests for `ChainDeviceAttribution`
/// (`Sources/WhatCableCore/USB/ChainDeviceAttribution.swift`): which
/// Thunderbolt chain device each USB device sits inside.
///
/// This is inference, so most of these tests are about it NOT firing. The
/// requirement they exist to hold is "anything unattributable hangs at chain
/// level with no guessed parent": a device shown inside the wrong dock is worse
/// than a flat list, because the flat list at least does not lie.
///
/// The corpus sweep in `ChainAttributionProbeSweepTests` replays the same
/// resolver over every probe-29 + probe-38 pair on disk. Two of the guards here
/// exist because that sweep found real counterexamples, and the counterexample
/// folder is named in each.
@Suite("ChainDeviceAttribution")
struct ChainDeviceAttributionTests {

    // MARK: - Fixtures

    private func chainSwitch(
        id: Int64,
        parent: Int64?,
        vendor: String,
        model: String,
        depth: Int
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchIntelJHL9580",
            vendorID: 0x8086,
            vendorName: vendor,
            modelName: model,
            routerID: 1,
            depth: depth,
            routeString: Int64(depth),
            upstreamPortNumber: 1,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [],
            parentSwitchUID: parent
        )
    }

    private func device(
        id: UInt64,
        locationID: UInt32,
        vendorID: UInt16,
        vendor: String?,
        product: String?,
        isHub: Bool
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: locationID,
            vendorID: vendorID,
            productID: 0x1234,
            vendorName: vendor,
            productName: product,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 3,
            busPowerMA: nil,
            currentMA: nil,
            deviceClass: isHub ? 0x09 : 0x00,
            rawProperties: [:]
        )
    }

    /// Host root -> dock. `ThunderboltTopology.tree` numbers the first hop
    /// depth 0, so the dock is the only chain node here.
    private func oneDeviceChain() -> [IOThunderboltSwitchNode] {
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let dock = chainSwitch(id: 200, parent: 100, vendor: "Ugreen", model: "TBT5 Dock", depth: 1)
        return ThunderboltTopology.tree(from: root, in: [root, dock])
    }

    /// Host root -> display -> dock, the reference machine's shape.
    private func twoDeviceChain(
        displayModel: String = "Studio Display ",
        dockModel: String = "TBT5 Docking Station 10-in-1"
    ) -> [IOThunderboltSwitchNode] {
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let display = chainSwitch(id: 200, parent: 100, vendor: "Apple", model: displayModel, depth: 1)
        let dock = chainSwitch(id: 300, parent: 200, vendor: "Ugreen Group Limited", model: dockModel, depth: 2)
        return ThunderboltTopology.tree(from: root, in: [root, display, dock])
    }

    private func resolve(_ chain: [IOThunderboltSwitchNode], _ devices: [USBDevice]) -> ChainDeviceAttribution {
        ChainDeviceAttribution.resolve(chain: chain, forest: USBDeviceNode.buildTree(from: devices))
    }

    // MARK: - The name match

    @Test("A device named exactly like a chain device IS that device, so it is absorbed")
    func exactNameAbsorbs() {
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Dock", isHub: false),
        ]
        let result = resolve(oneDeviceChain(), devices)
        #expect(result.absorbed == [2], "The dock's own USB identity endpoint should be absorbed into the chain row")
        #expect(result.regionRoots[1] == 200, "Its parent hub is the dock's upstream hub")
        #expect(result.regionOwner[1] == 200)
        #expect(result.regionOwner[2] == 200)
    }

    @Test("A device named like PART of a chain device marks its hub but is never absorbed")
    func affiliateMarksWithoutAbsorbing() {
        // CalDigit's whole TS line: the fabric reports "TS5", the USB
        // descriptors only ever say "TS5 USB 3 Hub" or "CalDigit TS5 Audio -
        // Rear", so exact equality recognises the dock never, on any machine.
        // Absorbing on a loose match would be a different bug: the audio
        // endpoint is a real thing inside the dock, and deleting it from the
        // tree is not de-duplication.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let dock = chainSwitch(id: 200, parent: 100, vendor: "CalDigit", model: "TS5", depth: 1)
        let chain = ThunderboltTopology.tree(from: root, in: [root, dock])
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "TS5 USB 3 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x0D8C, vendor: "CalDigit", product: "CalDigit TS5 Audio - Rear", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.absorbed.isEmpty, "A partial name match must not delete a device from the tree")
        #expect(result.regionOwner[1] == 200)
        #expect(result.regionOwner[2] == 200)
    }

    @Test("Word runs match in both directions, and only on whole words")
    func affiliateMatchesWholeWordsOnly() {
        #expect(ChainDeviceAttribution.affiliated(product: "TS5 USB 3 Hub", model: "TS5"))
        #expect(ChainDeviceAttribution.affiliated(product: "Apple Thunderbolt Display", model: "Thunderbolt Display"))
        #expect(ChainDeviceAttribution.affiliated(product: "WD_BLACK D50", model: "WD_BLACK D50 Game Dock"))
        #expect(ChainDeviceAttribution.affiliated(product: "Microsoft Surface Thunderbolt(TM) 4 Dock Audio", model: "Surface Thunderbolt(TM) 4 Dock"))
        // A short model name inside an unrelated word is the reason this is
        // word-level and not `contains`.
        #expect(!ChainDeviceAttribution.affiliated(product: "ATS5000 Scanner", model: "TS5"))
        #expect(!ChainDeviceAttribution.affiliated(product: "Docking Station", model: "Dock"))
        #expect(!ChainDeviceAttribution.affiliated(product: "Thunderbolt 4 Hub", model: "Thunderbolt 4 Dock"))
        // Non-contiguous words are not a match: the run has to be intact.
        #expect(!ChainDeviceAttribution.affiliated(product: "TS5 Fancy USB Hub", model: "TS5 USB Hub"))
    }

    @Test("Two chain devices with the same model name match neither")
    func duplicateModelNamesMatchNothing() {
        // Two identical daisy-chained displays: "UltraFine 4K" twice in the
        // corpus (`intel_corei9_9980hk_macos26.5.2`, `m2max_macos26.5.2_c`).
        // Nothing in the USB descriptors says which one a device is behind.
        let chain = twoDeviceChain(displayModel: "UltraFine 4K", dockModel: "UltraFine 4K")
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x043E, vendor: "LG", product: "UltraFine 4K", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.absorbed.isEmpty)
        #expect(result.regionRoots.isEmpty)
        #expect(result.regionOwner.isEmpty, "An ambiguous name must place nothing at all")
    }

    @Test("A name shorter than three characters is not a name")
    func shortNamesDoNotMatch() {
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let dock = chainSwitch(id: 200, parent: 100, vendor: "Some", model: "X5", depth: 1)
        let chain = ThunderboltTopology.tree(from: root, in: [root, dock])
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA", product: "X5", isHub: false)
        ]
        #expect(resolve(chain, devices).regionOwner.isEmpty)
    }

    // MARK: - The guards

    @Test("A hub claimed by two different chain devices is claimed by neither")
    func sharedHubClaimsNothing() {
        // Corpus counterexample: `m4_macos26.5.2_x`, an Echo 13 Thunderbolt 5
        // SSD Dock with an Envoy Ultra chained behind it, both exposing their
        // identity endpoint on the SAME hub. The hub is therefore upstream of
        // both, and an earlier draft that let the deeper device win moved five
        // of that machine's endpoints inside a bare SSD.
        let chain = twoDeviceChain(displayModel: "Echo 13 Thunderbolt 5 SSD Dock", dockModel: "Envoy Ultra")
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x1E91, vendor: "OWC", product: "Echo 13 Thunderbolt 5 SSD Dock", isHub: false),
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x1E91, vendor: "OWC", product: "Envoy Ultra", isHub: false),
            device(id: 4, locationID: 0x0313_0000, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.regionRoots.isEmpty, "The shared hub must not be marked for either device")
        #expect(result.absorbed == [2, 3], "Both are still their own chain device, so both are still absorbed")
        #expect(result.regionOwner[4] == nil, "The LAN adapter must not be handed a guessed parent")
    }

    @Test("Vendor continuity places a device by its hub vendor when every chain device is matched")
    func vendorContinuityPlacesTheEthernetAdapter() {
        // The reference machine's shape, reduced: the dock's USB2 subtree is
        // anchored, its USB3 subtree is not, and the two are linked only by both
        // containing VIA Labs hubs.
        let chain = twoDeviceChain()
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0313_0000, vendorID: 0x05AC, vendor: "Apple Inc.", product: "Studio Display", isHub: false),
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0312_1000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", isHub: false),
            device(id: 5, locationID: 0x0312_4000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            // The unanchored USB3 branch.
            device(id: 6, locationID: 0x0320_0000, vendorID: 0x8087, vendor: "Intel Corporation", product: "USB3 HUB", isHub: true),
            device(id: 7, locationID: 0x0321_4000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 8, locationID: 0x0321_4100, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.allAnchored)
        #expect(result.regionOwner[7] == 300, "A VIA Labs hub is only in the dock's vendor set")
        #expect(result.regionOwner[8] == 300, "So the adapter behind it inherits the dock")
        #expect(result.regionOwner[6] == nil, "Intel is in nobody's set, so the hub above stays put")
        #expect(result.regionRoots[7] == 300, "Vendor continuity marks a region, so the expanded view agrees")
    }

    @Test("Vendor continuity is off entirely unless every chain device is matched")
    func vendorContinuityNeedsEveryChainDeviceMatched() {
        // Vendor sets are built only from matched regions, so an unmatched chain
        // device contributes nothing at all. A device inside it would then be
        // handed to the matched device purely for being the only candidate with
        // a set, which is not discrimination. VIA Labs, Genesys Logic, Terminus
        // and Fresco Logic hubs are inside nearly every dock, so this is the
        // common case rather than an edge one.
        let chain = twoDeviceChain(displayModel: "Some Unnamed Dock")
        let devices = [
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0312_1000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", isHub: false),
            device(id: 5, locationID: 0x0312_4000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 7, locationID: 0x0321_4000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 8, locationID: 0x0321_4100, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(!result.allAnchored, "One chain device has no matching USB device")
        #expect(result.regionOwner[7] == nil, "The unanchored VIA hub must stay unplaced")
        #expect(result.regionOwner[8] == nil)
        #expect(result.regionOwner[3] == 300, "The structural pass is unaffected and still places the dock's own subtree")
    }

    @Test("A vendor in two chain devices' regions places nothing")
    func ambiguousVendorPlacesNothing() {
        let chain = twoDeviceChain(displayModel: "Alpha Dock", dockModel: "Beta Dock")
        let devices = [
            // Both docks' anchored regions contain a VIA Labs hub.
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x1111, vendor: "Alpha", product: "Alpha Dock", isHub: false),
            device(id: 3, locationID: 0x0320_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0321_0000, vendorID: 0x2222, vendor: "Beta", product: "Beta Dock", isHub: false),
            // A third VIA hub in neither region: the vendor cannot discriminate.
            device(id: 5, locationID: 0x0330_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 6, locationID: 0x0331_0000, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.allAnchored)
        #expect(result.regionOwner[5] == nil, "VIA Labs is in both regions, so it decides nothing")
        #expect(result.regionOwner[6] == nil)
    }

    @Test("The structural pass always wins over vendor continuity")
    func structuralBeatsVendor() {
        // A hub inside the display's anchored region whose vendor belongs to the
        // dock's set. Structure is direct evidence and the vendor is not, so the
        // hub must stay with the display.
        let chain = twoDeviceChain()
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0313_0000, vendorID: 0x05AC, vendor: "Apple Inc.", product: "Studio Display", isHub: false),
            device(id: 3, locationID: 0x0311_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0320_0000, vendorID: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 5, locationID: 0x0321_0000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", isHub: false),
            device(id: 6, locationID: 0x0322_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
        ]
        let result = resolve(chain, devices)
        #expect(result.regionOwner[3] == 200, "Nested inside the display's marked hub, so it is the display's")
    }

    @Test("Vendor continuity stays off when a chain device matched a name but holds no region")
    func vendorGateKeysOnRegionsNotNames() {
        // Found by an adversarial review, and it is the shared-hub guard being
        // walked around rather than broken. Three chain devices: Alpha and Beta
        // both name endpoints on ONE hub, so that hub is claimed by two and
        // marked for neither; Gamma is cleanly matched elsewhere. Every chain
        // device has a name match, so a gate keyed on matches passes, and vendor
        // continuity then sees the disputed hub's VIA Labs vendor in Gamma's
        // region (the only region there is) and hands it, plus everything
        // physically inside Alpha and Beta, to Gamma.
        //
        // The gate keys on RESOLVED REGIONS instead: Alpha and Beta hold none, so
        // it never opens.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let alpha = chainSwitch(id: 200, parent: 100, vendor: "OWC", model: "Alpha Dock", depth: 1)
        let beta = chainSwitch(id: 300, parent: 200, vendor: "OWC", model: "Beta Dock", depth: 2)
        let gamma = chainSwitch(id: 400, parent: 300, vendor: "Other", model: "Gamma Dock", depth: 3)
        let chain = ThunderboltTopology.tree(from: root, in: [root, alpha, beta, gamma])
        let devices = [
            // The disputed hub, with both docks' identity endpoints on it.
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x1E91, vendor: "OWC", product: "Alpha Dock", isHub: false),
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x1E91, vendor: "OWC", product: "Beta Dock", isHub: false),
            // A real endpoint inside one of them, which must not move.
            device(id: 6, locationID: 0x0313_0000, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
            // Gamma's region, whose hub shares the disputed hub's vendor.
            device(id: 4, locationID: 0x0320_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 5, locationID: 0x0321_0000, vendorID: 0x2222, vendor: "Other", product: "Gamma Dock", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(!result.allAnchored, "Alpha and Beta matched a name but hold no region, so the gate must stay shut")
        #expect(result.regionOwner[1] == nil, "The disputed hub belongs to none of them")
        #expect(result.regionOwner[6] == nil, "And nothing under it may be handed to Gamma")
        #expect(result.regionRoots[4] == 400, "Gamma's own region is unaffected")
    }

    @Test("A hub two chain devices both named stays unowned even when the vendor gate opens")
    func contestedHubIsOffLimitsToVendorContinuity() {
        // The re-verification finding, and the reason the region-based gate alone
        // was not enough. Alpha and Beta both name endpoints on hub 1, so it is
        // marked for neither. They ALSO each hold a second region elsewhere, so
        // every chain device holds a region and the vendor gate opens honestly.
        // Hub 1 is still unowned, which is exactly what vendor continuity looks
        // for, and its VIA Labs vendor appears only in Gamma's region: so it, and
        // the Ethernet adapter inside it, went to a dock they have nothing to do
        // with.
        //
        // Refusing to mark a disputed hub is only half a guard. Where the
        // ambiguity was seen has to stay on the record, and the whole subtree
        // under it is off limits to vendor evidence, because every device down
        // there is inside one of the two contenders and nothing says which.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let alpha = chainSwitch(id: 200, parent: 100, vendor: "OWC", model: "Alpha Dock", depth: 1)
        let beta = chainSwitch(id: 300, parent: 200, vendor: "OWC", model: "Beta Dock", depth: 2)
        let gamma = chainSwitch(id: 400, parent: 300, vendor: "Other", model: "Gamma Dock", depth: 3)
        let chain = ThunderboltTopology.tree(from: root, in: [root, alpha, beta, gamma])
        let devices = [
            // The disputed hub, both docks' identity endpoints on it, and a real
            // device inside it that shares the hub's vendor so it would also be
            // claimed if the subtree were not off limits.
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x1E91, vendor: "OWC", product: "Alpha Dock", isHub: false),
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x1E91, vendor: "OWC", product: "Beta Dock", isHub: false),
            device(id: 6, locationID: 0x0313_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB 10/100/1000 LAN", isHub: false),
            // Gamma's region, whose hub shares the disputed hub's vendor.
            device(id: 4, locationID: 0x0320_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 5, locationID: 0x0321_0000, vendorID: 0x3333, vendor: "Other", product: "Gamma Dock", isHub: false),
            // The second region each contender needs for the gate to open.
            device(id: 7, locationID: 0x0330_0000, vendorID: 0x1111, vendor: "Someone", product: "USB2.0 Hub", isHub: true),
            device(id: 8, locationID: 0x0331_0000, vendorID: 0x1E91, vendor: "OWC", product: "Alpha Dock", isHub: false),
            device(id: 9, locationID: 0x0340_0000, vendorID: 0x2222, vendor: "Someone", product: "USB2.0 Hub", isHub: true),
            device(id: 10, locationID: 0x0341_0000, vendorID: 0x1E91, vendor: "OWC", product: "Beta Dock", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.allAnchored, "Every chain device does hold a region here, so the gate opens")
        #expect(result.regionOwner[1] == nil, "The disputed hub must belong to none of them")
        #expect(result.regionOwner[6] == nil, "Nor may anything inside it be claimed on vendor evidence")
        #expect(result.regionRoots[4] == 400, "Gamma's own region is untouched")
        #expect(result.regionRoots[7] == 200, "And so is Alpha's second region")
    }

    @Test("A disputed hub inside an anchored region still inherits that region, and that is correct")
    func contestedSubtreeStillInheritsItsEnclosingRegion() {
        // Raised in review as a third wrong-parent route and REJECTED after
        // working through what the two attributions actually claim. Pinned here so
        // nobody "fixes" it later.
        //
        // Shape: the display is exactly matched, and inside its region sits a hub
        // that two chained docks both name, so that hub is marked for neither.
        // Plain inheritance then gives the hub, and everything under it, to the
        // display.
        //
        // That is not a wrong parent. A region root is the hub a chain device's
        // own identity endpoint hangs off, which is that device's upstream hub, so
        // everything below it reaches the Mac THROUGH that device. Both docks are
        // chained behind the display, so a device inside either of them is inside
        // the display too. The row says "this is behind the Studio Display", and
        // it is: one level less precise than naming the dock, and true.
        //
        // The two real bugs this is often mistaken for said something false
        // instead: they put a device inside a chain device that does NOT enclose it
        // (a sibling dock, an unrelated third device). True-but-less-precise and
        // false are not the same finding, and only the second is worth degrading
        // for. The ticket's own requirement, "anything unattributable hangs at
        // chain level", is this behaviour.
        //
        // What blocking inheritance would actually do, measured rather than
        // assumed (the first version of this comment claimed "nothing", which was
        // wrong for the collapsed view and was corrected in review):
        //
        //  - expanded: nothing, genuinely. `nestedRows` reads direct marks and the
        //    absorbed set, never `regionOwner`, so the rendering is unchanged.
        //  - collapsed: the row would move to the leftover group, which is
        //    appended after every chain device's rows rather than inline, and it
        //    would keep its "via N hubs" suffix, since only the leftover group is
        //    rendered with hop counts.
        //
        // So there IS a residual, and it is the second bullet: an inherited row
        // shows no hop count, which reads more definite than the evidence behind
        // it. The device is genuinely inside the display, but two docks were
        // candidates and neither could be ruled in. The honest marker would be
        // "ownership was inherited across a contested boundary", which is narrower
        // than "inherited" (the reference machine's Ethernet adapter is inherited
        // too, from its hub's vendor mark, and there the dock IS the most specific
        // answer, which is why its row correctly carries no suffix).
        //
        // Not built, deliberately: no corpus machine has this shape at all (one
        // contested hub exists in 84 chains, and it is not nested inside another
        // chain device's region), and getting the condition subtly wrong would put
        // a suffix on the reference machine's approved output. Left as a follow-up
        // rather than guessed at here.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let display = chainSwitch(id: 200, parent: 100, vendor: "Apple", model: "Studio Display", depth: 1)
        let dockOne = chainSwitch(id: 300, parent: 200, vendor: "OWC", model: "Alpha Dock", depth: 2)
        let dockTwo = chainSwitch(id: 400, parent: 300, vendor: "OWC", model: "Beta Dock", depth: 3)
        let chain = ThunderboltTopology.tree(from: root, in: [root, display, dockOne, dockTwo])
        let devices = [
            // The display's own hub and identity endpoint: an exact match.
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x05AC, vendor: "Apple Inc.", product: "Studio Display", isHub: false),
            // Nested inside it: a hub both docks name, so marked for neither.
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", isHub: true),
            device(id: 4, locationID: 0x0312_1000, vendorID: 0x1E91, vendor: "OWC", product: "Alpha Dock", isHub: false),
            device(id: 5, locationID: 0x0312_2000, vendorID: 0x1E91, vendor: "OWC", product: "Beta Dock", isHub: false),
            device(id: 6, locationID: 0x0312_3000, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.regionRoots[3] == nil, "The disputed hub is still marked for neither dock")
        #expect(result.regionOwner[3] == 200, "But it is inside the display, and saying so is true")
        #expect(result.regionOwner[6] == 200, "As is the adapter behind it")
        // What must NOT happen is a claim of containment that is false.
        #expect(result.regionOwner[6] != 300)
        #expect(result.regionOwner[6] != 400)
    }

    @Test("A generically named chain device cannot steal a device an exact match already placed")
    func affiliateMatchCannotOverrideAnExactMatch() {
        // Also from the adversarial review. A chain device whose model name is one
        // generic word clears the three-character floor, and "Hub" word-matches
        // the internal hub chips of unrelated devices, because "USB3.0 Hub"
        // contains the whole word and so does nearly every hub descriptor ever
        // written. With both match strengths running together, that partial match
        // re-parented a hub the display's exact match had already placed, taking
        // its whole subtree under an unrelated dock.
        //
        // Exact matches settle ownership first; an affiliate match is refused
        // wherever it would contradict them.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let display = chainSwitch(id: 200, parent: 100, vendor: "Apple", model: "Studio Display", depth: 1)
        let genericDock = chainSwitch(id: 300, parent: 200, vendor: "Nobody", model: "Hub", depth: 2)
        let chain = ThunderboltTopology.tree(from: root, in: [root, display, genericDock])
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0313_0000, vendorID: 0x05AC, vendor: "Apple Inc.", product: "Studio Display", isHub: false),
            // Inside the display's hub, and named like every hub chip on earth.
            device(id: 3, locationID: 0x0311_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0311_1000, vendorID: 0x046D, vendor: "Logitech", product: "Webcam", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.regionOwner[3] == 200, "The hub is nested inside the display's region and stays there")
        #expect(result.regionOwner[4] == 200, "And so does the device behind it")
        #expect(result.regionRoots[3] == nil, "No region may be opened for the generically named dock here")
    }

    // MARK: - Degenerate inputs

    @Test("No chain and no devices resolve to nothing, and nothing crashes")
    func emptyInputs() {
        #expect(ChainDeviceAttribution.resolve(chain: [], forest: []).isEmpty)
        #expect(resolve(oneDeviceChain(), []).isEmpty)
        let devices = [device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA", product: "USB2.0 Hub", isHub: true)]
        #expect(ChainDeviceAttribution.resolve(chain: [], forest: USBDeviceNode.buildTree(from: devices)).isEmpty)
    }

    @Test("A forest whose parent links form a cycle still terminates")
    func cyclicParentLinksTerminate() {
        // `parentOf` inside the resolver is keyed by IOKit entry ID, not by
        // locationID. The forest itself cannot contain a cycle (each parent
        // locationID clears a nibble, so the path strictly shortens), but two
        // devices arriving with the SAME entry ID collide in that map and can
        // close a loop. IOKit does not hand out duplicate entry IDs; a stale
        // snapshot or a hand-built fixture can. A hang in the render path is the
        // worst failure available here, so it is ruled out structurally rather
        // than assumed away.
        //
        // Building a fixture that actually hangs took three attempts, and the two
        // that did not are worth recording because both looked convincing:
        //
        //  - a single `3 -> 2` link is not a cycle at all, and the test stayed
        //    green with the guard removed;
        //  - a cycle CONTAINING a marked node also terminates, because the walk
        //    stops at the first marked ancestor it meets.
        //
        // What hangs is a marked node whose parent chain leads into a cycle none
        // of whose members is marked. Here id 1 is marked (a hub that names the
        // dock, so it roots the region itself) and ids 2 and 3 are each other's
        // parent: node id 2 has children 1 and 3, and node id 3 has child 2.
        // The chain is deliberately only half matched, so vendor continuity
        // cannot run and mark a cycle member on the way past.
        //
        // If this regresses, the symptom is this test never finishing.
        let devices = [
            device(id: 2, locationID: 0x0310_0000, vendorID: 0x8087, vendor: "Intel", product: "USB3 HUB", isHub: true),
            device(id: 1, locationID: 0x0311_0000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", isHub: true),
            device(id: 3, locationID: 0x0312_0000, vendorID: 0x8087, vendor: "Intel", product: "USB3 HUB", isHub: true),
            device(id: 3, locationID: 0x0320_0000, vendorID: 0x8087, vendor: "Intel", product: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0321_0000, vendorID: 0x8087, vendor: "Intel", product: "USB3 HUB", isHub: true),
        ]
        let result = resolve(twoDeviceChain(), devices)
        #expect(!result.allAnchored, "Only the dock is named, so vendor continuity must be off")
        #expect(result.regionRoots[1] == 300, "The hub that names the dock still roots its region")
    }

    @Test("A device with no product name matches nothing")
    func namelessDeviceMatchesNothing() {
        let devices = [device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: nil, product: nil, isHub: false)]
        #expect(resolve(oneDeviceChain(), devices).isEmpty)
    }

    @Test("Two matches for one chain device, nested, mark only the outer hub")
    func nestedSameOwnerMarksAreCollapsed() {
        // A CalDigit dock publishes `TS5 USB 3 Hub` (a hub, which marks itself)
        // and `CalDigit TS5 Audio - Rear` (an endpoint further in, which marks
        // the hub it hangs off). Both name the same chain device, and the second
        // hub is inside the first. Keeping both marks renders that subtree twice
        // in the expanded view: once inside its ancestor and once as a region of
        // its own.
        let root = chainSwitch(id: 100, parent: nil, vendor: "Apple", model: "Mac", depth: 0)
        let dock = chainSwitch(id: 200, parent: 100, vendor: "CalDigit", model: "TS5", depth: 1)
        let chain = ThunderboltTopology.tree(from: root, in: [root, dock])
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "TS5 USB 3 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", isHub: true),
            device(id: 3, locationID: 0x0311_1000, vendorID: 0x0D8C, vendor: "CalDigit", product: "CalDigit TS5 Audio - Rear", isHub: false),
        ]
        let result = resolve(chain, devices)
        #expect(result.regionRoots[1] == 200, "The outer hub roots the dock's region")
        #expect(result.regionRoots[2] == nil, "The inner hub adds nothing: its subtree already inherits the dock")
        #expect(result.regionOwner[2] == 200, "Ownership is unaffected, only the redundant mark is gone")
        #expect(result.regionOwner[3] == 200)
    }

    @Test("A hub that names a chain device claims itself, not its parent")
    func hubAnchorClaimsItself() {
        let devices = [
            device(id: 1, locationID: 0x0310_0000, vendorID: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", isHub: true),
            device(id: 2, locationID: 0x0311_0000, vendorID: 0x2B89, vendor: "UGREEN", product: "TBT5 Dock", isHub: true),
            device(id: 3, locationID: 0x0311_1000, vendorID: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", isHub: false),
        ]
        let result = resolve(oneDeviceChain(), devices)
        #expect(result.regionRoots[2] == 200, "The hub IS the dock, so it roots the region itself")
        #expect(result.regionRoots[1] == nil, "Its parent hub belongs to nothing in particular")
        #expect(result.regionOwner[3] == 200)
    }
}
