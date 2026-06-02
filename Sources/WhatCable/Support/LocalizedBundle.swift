import Foundation

// The bundle used for all localized strings in WhatCable.
// Updated in tandem with _coreLocalizedBundle when language changes.
//
// Same lock-guarded pattern as WhatCableCore's _coreLocalizedBundle: the write
// (live language switch, on the main actor from AppSettings) is serialised
// against any concurrent read. Reads stay synchronous so call sites are
// unchanged.
private let _appBundleLock = NSLock()
private nonisolated(unsafe) var _appBundleStorage: Bundle = .module

var _appLocalizedBundle: Bundle {
    _appBundleLock.lock()
    defer { _appBundleLock.unlock() }
    return _appBundleStorage
}

func setAppLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .module
    } else if let url = Bundle.module.url(forResource: identifier, withExtension: "lproj"),
              let b = Bundle(url: url) {
        resolved = b
    } else {
        resolved = .module
    }
    _appBundleLock.lock()
    _appBundleStorage = resolved
    _appBundleLock.unlock()
}
