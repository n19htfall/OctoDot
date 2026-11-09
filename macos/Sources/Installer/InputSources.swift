import Carbon
import Foundation

/// The input-source functions (HIToolbox's TextInputSources), for one bundle.
enum InputSources {
    /// Every source of the bundle with `bundleID` that is installed: the
    /// method itself and its input mode.
    static func of(_ bundleID: String) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func register(_ bundle: URL) -> Bool { TISRegisterInputSource(bundle as CFURL) == noErr }

    @discardableResult
    static func enable(_ bundleID: String) -> Bool {
        let sources = of(bundleID)
        for source in sources where !isEnabled(source) { TISEnableInputSource(source) }
        return !sources.isEmpty && isEnabled(bundleID)
    }

    static func disable(_ bundleID: String) {
        for source in of(bundleID) where isEnabled(source) { TISDisableInputSource(source) }
    }

    /// Enabled: the bundle's input mode is among the user's input sources.
    static func isEnabled(_ bundleID: String) -> Bool {
        let modes = of(bundleID).filter(selectable)
        return !modes.isEmpty && modes.allSatisfy(isEnabled)
    }

    /// Makes the bundle's input mode the current input source.
    static func select(_ bundleID: String) -> Bool {
        guard let mode = of(bundleID).first(where: selectable) else { return false }
        return TISSelectInputSource(mode) == noErr
    }

    private static func isEnabled(_ source: TISInputSource) -> Bool { flag(source, kTISPropertyInputSourceIsEnabled) }
    private static func selectable(_ source: TISInputSource) -> Bool {
        flag(source, kTISPropertyInputSourceIsSelectCapable)
    }

    private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}
