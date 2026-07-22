import Foundation
import IOKit

public func wcInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let i = value as? Int { return i }
    if let s = value as? String, let i = Int(s) { return i }
    return 0
}

public func wcUInt32(_ value: Any?) -> UInt32 {
    if let n = value as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
    if let i = value as? Int { return UInt32(truncatingIfNeeded: i) }
    if let u = value as? UInt32 { return u }
    return 0
}

public func wcUInt8(_ value: Any?) -> UInt8 {
    UInt8(truncatingIfNeeded: wcInt(value))
}

public func wcBool(_ value: Any?) -> Bool {
    if let n = value as? NSNumber { return n.boolValue }
    if let b = value as? Bool { return b }
    return false
}

public func wcDictionary(_ value: Any?) -> [String: Any] {
    if let dict = value as? [String: Any] { return dict }
    if let nsDict = value as? NSDictionary {
        var converted: [String: Any] = [:]
        for case let (key, val) as (String, Any) in nsDict {
            converted[key] = val
        }
        return converted
    }
    return [:]
}

public func wcArray(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    if let nsArray = value as? NSArray { return nsArray.map { $0 } }
    return []
}

public func wcData(_ value: Any?) -> Data? {
    value as? Data
}

public func wcRegistryEntryID(_ service: io_service_t) -> UInt64 {
    var entryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &entryID)
    return entryID
}

public func wcPortIndex(from dict: [String: Any], service: io_service_t? = nil) -> Int {
    if let n = dict["PortIndex"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentBuiltInPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["PortNumber"].map(wcInt), n != 0 { return n }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortIndex(read: (String) -> Any?, service: io_service_t? = nil) -> Int {
    for key in ["PortIndex", "ParentPortNumber", "ParentBuiltInPortNumber", "PortNumber"] {
        let n = wcInt(read(key)); if n != 0 { return n }
    }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortType(from dict: [String: Any], service: io_service_t? = nil) -> String {
    if let type = dict["PortTypeDescription"] as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        // Read the single key individually rather than bulk-fetching all
        // properties. The bulk fetch can abort inside IOCFUnserializeBinary
        // when the kernel returns a malformed blob mid-teardown. See #181.
        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

public func wcPortType(read: (String) -> Any?, service: io_service_t? = nil) -> String {
    if let type = read("PortTypeDescription") as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

/// Is this IOKit class name an HPM power-controller node (the node that carries
/// the port's `UUID`)?
///
/// **This predicate is deliberately class-agnostic and must stay that way.**
/// `AppleHPMDevice` is the base class used on **M1/M2**; `AppleHPMDeviceHAL*`
/// (e.g. `AppleHPMDeviceHALType3`) is the M3+ subclass. **Both carry a `UUID`.**
/// The 206-machine probe-35 corpus is unambiguous: 295/295 `AppleHPMDevice`
/// ports and 409/409 `AppleHPMDeviceHALType3` ports have one, zero misses
/// (704 ports total; probe 35 also lists 50 `(no port child)` internal
/// controllers, which carry a UUID but own no port and are not counted).
///
/// Narrowing this to the `HALType3` subclass would silently drop every M1/M2
/// machine from the port join while looking like "M1/M2 hardware has no UUID".
/// That misreading has already cost two separate investigations, so it is pinned
/// by `HPMControllerClassGateTests`: narrow it and the tests go red.
public func wcIsHPMControllerClass(_ className: String) -> Bool {
    className == "AppleHPMDevice" || className.hasPrefix("AppleHPMDeviceHAL")
}

/// Walks the IOKit parent chain from `service` looking for an HPM power
/// controller node (`AppleHPMDevice` or `AppleHPMDeviceHAL*`) and
/// returns its `UUID` property as a raw string.
///
/// This is the same walk `AppleHPMInterfaceWatcher.hpmControllerUUID(for:)`
/// performs, factored out so every per-port source watcher (PowerSource,
/// USB3Transport, TRMTransport, CIOCableCapability) can capture the same UUID
/// without duplicating the logic. Both share `wcIsHPMControllerClass` so the two
/// walks can never drift apart on which classes count.
///
/// Returns `nil` when no HPM controller is found within 12 parent steps, or
/// when the controller carries no `UUID` property. The depth limit of 12
/// is larger than the watcher's 8 to accommodate deeper subtrees
/// (IOPortFeaturePowerSource sits ~4 levels below the HPM device node,
/// whereas `AppleHPMInterface` is a direct child).
public func wcHPMControllerUUID(for service: io_service_t) -> String? {
    guard let uuid = wcHPMControllerProperty(for: service, key: "UUID") as? String,
          !uuid.isEmpty else { return nil }
    return uuid
}

/// Walks the IOKit parent chain from `service` to its HPM power controller and
/// returns the controller's `RID` (the SPMI resource ID identifying that
/// controller on the bus).
///
/// `RID` is the ordering key for `AppleSmartBattery`'s `PortControllerInfo`
/// array. That array carries no port identifier of its own, so entry N can only
/// be tied back to a physical port by knowing the order Apple built it in;
/// sorting the ports by controller `RID` reproduces that order. See
/// `PowerTelemetryWatcher.orderedPortKeys(_:)` for the ordering itself and
/// `HPMPortKeyOrderCorpusSweepTests` for the corpus evidence.
///
/// Returns `nil` when no controller is found, or when it carries no numeric
/// `RID`. Every one of the 1518 real ports in the probe-35 corpus has one, so
/// `nil` is a defensive path, not an expected outcome.
public func wcHPMControllerRID(for service: io_service_t) -> Int? {
    guard let raw = wcHPMControllerProperty(for: service, key: "RID") else { return nil }
    // IOKit hands numbers back as CFNumber, which bridges to NSNumber. Going
    // via NSNumber (rather than `as? Int`) accepts whatever width the kernel
    // published it at.
    return (raw as? NSNumber)?.intValue
}

/// Shared parent walk behind `wcHPMControllerUUID` and `wcHPMControllerRID`:
/// climbs from `service` until it hits an HPM power controller node
/// (`AppleHPMDevice` or `AppleHPMDeviceHAL*`) and reads one property off it.
///
/// This is the same walk `AppleHPMInterfaceWatcher.hpmControllerUUID(for:)`
/// performs, factored out so every per-port source watcher (PowerSource,
/// USB3Transport, TRMTransport, CIOCableCapability) can capture the same
/// controller identity without duplicating the logic. All of them share
/// `wcIsHPMControllerClass` so the walks can never drift apart on which
/// classes count.
///
/// Stops at the first controller found: if that controller lacks the property,
/// the answer is `nil` rather than "keep climbing", because a property read off
/// some further-up node would not be describing this port's controller.
///
/// Returns `nil` when no controller is found within 12 parent steps. The depth
/// limit of 12 is larger than the watcher's 8 to accommodate deeper subtrees
/// (IOPortFeaturePowerSource sits ~4 levels below the HPM device node, whereas
/// `AppleHPMInterface` is a direct child).
public func wcHPMControllerProperty(for service: io_service_t, key: String) -> Any? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0..<12 {
        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(current, &classBuf)
        let cls = String(cString: classBuf)
        if wcIsHPMControllerClass(cls) {
            return IORegistryEntryCreateCFProperty(
                current,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }

        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}
