import Foundation
import IOKit
import WhatCableCore

/// Watches `IOPortFeaturePowerSource` services. These appear under each port's
/// `Power In` feature when something that advertises PD is connected.
@MainActor
public final class PowerSourceWatcher: ObservableObject {
    @Published public private(set) var sources: [PowerSource] = []

    /// Live charger-in wattage for the menu bar readout. Recomputed on the hub's
    /// poll cadence (1 Hz while a UI surface is visible, 30 s idle) and on each
    /// system power-source change notification, so the number stays fresh between
    /// idle polls without a separate per-second timer. 0 on battery or when
    /// nothing is readable. Only populated while ``readsChargerInputWatts`` is on.
    @Published public private(set) var chargerInputWatts: Int = 0

    /// Whether each refresh should also read the live charger-in wattage. Off by
    /// default, so the common case (menu bar watts readout disabled) does no
    /// SMC / battery read at all. The app turns this on only while the readout is
    /// shown. Flipping it on computes once immediately so the label paints without
    /// waiting for the next poll; flipping it off clears the value.
    public var readsChargerInputWatts = false {
        didSet {
            guard readsChargerInputWatts != oldValue else { return }
            if readsChargerInputWatts {
                startPowerSourceNotification()
                refreshChargerInputWatts()
            } else {
                stopPowerSourceNotification()
                if chargerInputWatts != 0 { chargerInputWatts = 0 }
            }
        }
    }

    /// Reads the live SMC DC-in rail. Held once and reused (its `open()` is lazy
    /// and idempotent) so the per-tick read doesn't churn the AppleSMC user client.
    private let smcReader = SMCPowerReader()

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    /// System power-source change notification. Fires the watts recompute on a
    /// real charging change (charge ramp near full, charger swap) so the menu bar
    /// number stays fresh between the hub's idle (30 s) polls without a 1 Hz
    /// timer. Only registered while ``readsChargerInputWatts`` is on, so the
    /// readout-off majority schedules nothing.
    private var powerSourceRunLoopSource: CFRunLoopSource?

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleRemoved(iter) }
        }

        let matching = IOServiceMatching("IOPortFeaturePowerSource")
        if IOServiceAddMatchingNotification(port, kIOMatchedNotification, matching, added, selfPtr, &addedIter) == KERN_SUCCESS {
            handleAdded(addedIter)
        }

        let matching2 = IOServiceMatching("IOPortFeaturePowerSource")
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching2, removed, selfPtr, &removedIter) == KERN_SUCCESS {
            handleRemoved(removedIter)
        }

        // Reconcile the power-source notification to the flag: stop() tears the
        // source down but leaves readsChargerInputWatts as-is, so a stop/start
        // cycle must re-register it here rather than silently lose it.
        if readsChargerInputWatts { startPowerSourceNotification() }
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        stopPowerSourceNotification()
        sources.removeAll()
    }

    // MARK: - Charger-in watts notification

    /// Register the system power-source change notification on the main run loop.
    /// The callback fires on a charging-state change, which recomputes the watts
    /// without polling. Idempotent.
    private func startPowerSourceNotification() {
        guard powerSourceRunLoopSource == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let w = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handlePowerSourceNotification() }
        }
        guard let unmanaged = IOPSNotificationCreateRunLoopSource(callback, selfPtr) else { return }
        let source = unmanaged.takeRetainedValue()
        // .commonModes so the callback still fires while the run loop is in a
        // tracking/modal mode (e.g. a menu open), not only the default mode.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    private func stopPowerSourceNotification() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = nil
    }

    private func handlePowerSourceNotification() {
        guard readsChargerInputWatts else { return }
        refreshChargerInputWatts()
    }

    public func refresh() {
        // Build the new list locally and assign once. Mutating the published
        // `sources` in place (removeAll then re-append) emits a transient empty
        // value that downstream subscribers see as "everything disconnected,"
        // which made NotificationManager fire a charger-connect/disconnect pair
        // on every poll tick. See issue #227.
        let rebuilt = Self.readAllPowerSources()
        if rebuilt != sources { sources = rebuilt }
        if readsChargerInputWatts { refreshChargerInputWatts() }
    }

    /// Read the live charger-in wattage and publish it when the rounded value
    /// changes. Same source order the menu bar has always shown: the live SMC
    /// DC-in rail first, then `AppleSmartBattery`'s coarse `SystemPowerIn`, then
    /// the rated adapter. Runs on the hub's poll cadence, not a private timer.
    private func refreshChargerInputWatts() {
        let dict = PowerTelemetryWatcher.appleSmartBatteryProperties()
        // No battery dict at all means a desktop: treat as always externally
        // powered. A dict without the flag also reads as connected.
        let externalConnected = dict.map { ($0["ExternalConnected"] as? Bool) ?? true } ?? true
        // On battery there is nothing to show. Return before the SMC user-client
        // and adapter reads so those run only while a charger is attached (the
        // same short-circuit the old menu-bar read had).
        guard externalConnected else {
            if chargerInputWatts != 0 { chargerInputWatts = 0 }
            return
        }

        let smcWatts = smcReader.readSystemPowerInput()?.watts
        let telemetry = dict?["PowerTelemetryData"] as? [String: Any]
        let systemPowerInMilliwatts = telemetry?["SystemPowerIn"] as? Int
        let adapterWatts = SystemPower.currentAdapter()?.watts

        let watts = Self.selectChargerInputWatts(
            externalConnected: externalConnected,
            smcWatts: smcWatts,
            systemPowerInMilliwatts: systemPowerInMilliwatts,
            adapterWatts: adapterWatts
        )
        if watts != chargerInputWatts { chargerInputWatts = watts }
    }

    /// Pure watts-selection policy, testable without IOKit. Returns 0 on battery
    /// (`externalConnected == false`) or when no source reports a usable figure.
    /// Prefers the live SMC rail, then the battery gauge (milliwatts, rounded to
    /// the nearest watt), then the rated adapter wattage.
    nonisolated static func selectChargerInputWatts(
        externalConnected: Bool,
        smcWatts: Double?,
        systemPowerInMilliwatts: Int?,
        adapterWatts: Int?
    ) -> Int {
        guard externalConnected else { return 0 }
        if let smcWatts, smcWatts > 0 { return Int(smcWatts.rounded()) }
        if let systemPowerInMilliwatts, systemPowerInMilliwatts > 0 {
            return (systemPowerInMilliwatts + 500) / 1000
        }
        if let adapterWatts, adapterWatts > 0 { return adapterWatts }
        return 0
    }

    /// Enumerate every `IOPortFeaturePowerSource` once and parse it into the
    /// self-keyed `PowerSource` model. Shared with `PowerTelemetryWatcher`,
    /// which needs the keyed contract to attribute `PortControllerInfo` detail
    /// to the right port (instead of array-offset guessing).
    public nonisolated static func readAllPowerSources() -> [PowerSource] {
        var rebuilt: [PowerSource] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortFeaturePowerSource"), &iter) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iter), service != 0 {
                if let s = makeSource(from: service), !rebuilt.contains(where: { $0.id == s.id }) {
                    rebuilt.append(s)
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iter)
        }
        return rebuilt
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            if let s = Self.makeSource(from: service), !sources.contains(where: { $0.id == s.id }) {
                sources.append(s)
            }
            IOObjectRelease(service)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                sources.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    // MARK: - IOKit wrapper (package-internal)

    nonisolated static func makeSource(from service: io_service_t) -> PowerSource? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        // Walk the parent chain to get the HPM controller UUID. This is the
        // same UUID stored on the AppleHPMInterface node two levels above, so
        // matching by UUID ties a power source to its port with no @N guessing.
        let uuid = wcHPMControllerUUID(for: service)
        return makeSource(entryID: entryID, read: read, hpmControllerUUID: uuid)
    }

    // MARK: - Parse function (internal, testable)

    /// Parse a power source from a property-read closure. The `hpmControllerUUID`
    /// is passed in so the caller can walk the parent chain once and tests can
    /// supply nil without IOKit.
    nonisolated static func makeSource(
        entryID: UInt64,
        read: (String) -> Any?,
        hpmControllerUUID: String?
    ) -> PowerSource? {
        let name = (read("PowerSourceName") as? String) ?? "Unknown"
        let parent = parentPortIdentity(read: read)

        let options: [PowerOption] = parseOptions(read("PowerSourceOptions"))
        let winning: PowerOption? = parseOption(read("WinningPowerSourceOption"))

        return PowerSource(
            id: entryID,
            name: name,
            parentPortType: parent.type,
            parentPortNumber: parent.number,
            options: options,
            winning: winning,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    nonisolated static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
            ?? 0
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
            ?? Int(((read("Priority") as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    nonisolated static func parseOptions(_ value: Any?) -> [PowerOption] {
        // IOKit publishes PowerSourceOptions as an __NSCFSet (CF set), not
        // an NSArray. ioreg renders it as "[{...}]" which looks like an
        // array, but the actual CF type is a set. Handle both.
        let items: [Any]
        if let set = value as? NSSet {
            items = set.allObjects
        } else if let arr = value as? NSArray {
            items = arr.compactMap { $0 }
        } else {
            return []
        }
        return items.compactMap { parseOption($0) }
            .sorted { $0.maxPowerMW > $1.maxPowerMW }
    }

    nonisolated static func parseOption(_ value: Any?) -> PowerOption? {
        let dict: [String: Any]?
        if let d = value as? [String: Any] {
            dict = d
        } else if let nsd = value as? NSDictionary {
            var converted: [String: Any] = [:]
            for case let (key, val) as (String, Any) in nsd {
                converted[key] = val
            }
            dict = converted
        } else {
            dict = nil
        }
        guard let dict else { return nil }
        let v = (dict["Voltage (mV)"] as? NSNumber)?.intValue ?? 0
        let i = (dict["Max Current (mA)"] as? NSNumber)?.intValue ?? 0
        let p = (dict["Max Power (mW)"] as? NSNumber)?.intValue ?? (v * i / 1000)
        guard v > 0 else { return nil }
        return PowerOption(voltageMV: v, maxCurrentMA: i, maxPowerMW: p)
    }
}

extension PowerSourceWatcher {
    /// All power sources attached to a given port.
    /// Uses UUID-based matching when available (M3+), else portKey fallback.
    public func sources(for port: AppleHPMInterface) -> [PowerSource] {
        return sources.filter { $0.canonicallyMatches(port: port) }
    }
}

