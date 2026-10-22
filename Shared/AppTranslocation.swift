//
//  AppTranslocation.swift
//  Shared
//
//  Whether macOS is running this app from a translocated copy. An app that
//  was downloaded (so is quarantined) and opened where it was unpacked,
//  rather than moved by Finder first, is run from a random read-only path
//  under /private/var/folders/…/AppTranslocation/ instead. Security.framework
//  answers both questions here, but not in its headers, so the functions are
//  looked up at run time, as other apps that move themselves do.

import Foundation

nonisolated enum AppTranslocation {

    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let security, let symbol = dlsym(security, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Whether `bundle` (this app, by default) is running translocated.
    static func isTranslocated(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        if let check = function("SecTranslocateIsTranslocatedURL", as: IsTranslocated.self) {
            var translocated = DarwinBoolean(false)
            if check(bundle as CFURL, &translocated, nil).boolValue {
                return translocated.boolValue
            }
        }
        return bundle.path.contains("/AppTranslocation/")
    }

    /// Where the translocated `bundle` really is: the copy the person
    /// opened, in Downloads or wherever they unpacked it.
    static func originalURL(of bundle: URL = Bundle.main.bundleURL) -> URL? {
        guard let original = function("SecTranslocateCreateOriginalPathForURL", as: OriginalPath.self) else { return nil }
        return original(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
