import AppKit
import Carbon.HIToolbox

/// The single source of truth for translation display and candidate shortcuts.
enum TranslationModifier: String, CaseIterable, Identifiable, Sendable {
    case option, command, control

    var id: String { rawValue }
    var label: String {
        switch self {
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .control: "⌃ Control"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .command: .command
        case .control: .control
        }
    }

    var carbonFlags: UInt32 {
        switch self {
        case .option: UInt32(optionKey)
        case .command: UInt32(cmdKey)
        case .control: UInt32(controlKey)
        }
    }

    private static let defaultsKey = "translationModifier"
    private static let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    @MainActor private(set) static var current = TranslationModifier(
        rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    ) ?? .option
    @MainActor private static var releaseTimer: Timer?

    @MainActor static func isActive(_ flags: NSEvent.ModifierFlags) -> Bool {
        releaseTimer == nil && flags.intersection(relevantFlags) == current.flags
    }

    @MainActor static func select(_ modifier: TranslationModifier) {
        guard modifier != current else { return }
        current = modifier
        UserDefaults.standard.set(modifier.rawValue, forKey: defaultsKey)
        stopWaitingForRelease()
        // A change made while modifiers are held must not select a translation
        // using the old gesture. Re-arm only after all modifiers are released.
        if !NSEvent.modifierFlags.intersection(relevantFlags).isEmpty {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if NSEvent.modifierFlags.intersection(relevantFlags).isEmpty { stopWaitingForRelease() }
                }
            }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @MainActor static func stopWaitingForRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }
}
