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
