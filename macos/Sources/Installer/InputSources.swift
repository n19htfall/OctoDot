import Carbon
import Foundation
import os

private let log = Logger(subsystem: "OctoDot", category: "input-sources")

/// The input-source functions (HIToolbox's TextInputSources), for one bundle.
enum InputSources {
    /// Every source of the bundle with `bundleID` that is installed: the
    /// method itself and its input mode.
    private static func of(_ bundleID: String) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func register(_ bundle: URL) -> Bool {
        onMain {
            let status = TISRegisterInputSource(bundle as CFURL)
            if status != noErr { log.error("Register input source failed: \(status)") }
            return status == noErr
        }
    }

    @discardableResult
    static func enable(_ bundleID: String) -> Bool {
        onMain {
            // macOS requires the parent input method to be enabled before its modes.
            for parent in of(bundleID) where isParent(parent) && !isEnabled(parent) {
                guard enable(parent) else { return false }
            }
            let modes = of(bundleID).filter(selectable)
            var succeeded = true
            for mode in modes where !isEnabled(mode) {
                if !enable(mode) { succeeded = false }
            }
            return succeeded && enabledModes(bundleID)
        }
    }

    static func disable(_ bundleID: String) {
        onMain {
            for source in of(bundleID) where isEnabled(source) { TISDisableInputSource(source) }
        }
    }

    /// Enabled: the bundle's input mode is among the user's input sources.
    static func isEnabled(_ bundleID: String) -> Bool {
        onMain { enabledModes(bundleID) }
    }

    private static func enabledModes(_ bundleID: String) -> Bool {
        let modes = of(bundleID).filter(selectable)
        return !modes.isEmpty && modes.allSatisfy(isEnabled)
    }

    /// Makes the bundle's input mode the current input source.
    static func select(_ bundleID: String) -> Bool {
        onMain {
            guard let mode = of(bundleID).first(where: selectable) else { return false }
            return TISSelectInputSource(mode) == noErr
        }
    }

    private static func enable(_ source: TISInputSource) -> Bool {
        let status = TISEnableInputSource(source)
        if status != noErr { log.error("Enable input source failed: \(status)") }
        return status == noErr
    }

    private static func isParent(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return CFEqual(type, kTISTypeKeyboardInputMethodModeEnabled)
    }

    // HIToolbox's text input APIs are not thread-safe. XPC calls can arrive on
    // different queues, so keep all access on the main thread.
    private static func onMain<T: Sendable>(_ body: @Sendable () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
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
