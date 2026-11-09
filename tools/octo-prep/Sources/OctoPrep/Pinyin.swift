import Foundation

/// A pinyin syllable as the dictionaries write it ("zhōng", "lǜ", "a"),
/// split into the letters a user types and its tone.
public struct Syllable: Hashable, Sendable {
    public let toned: String  // NFC, as written in the dictionary
    public let plain: String  // a-z, with v for ü
    public let tone: Int      // 1-4; 0 for the neutral tone
}

public enum Pinyin {
    /// nil unless `text` is letters a-z with at most one tone mark and ü:
    /// the only marks the 万象 dictionaries use.
    public static func syllable(_ text: String) -> Syllable? {
        let toned = text.precomposedStringWithCanonicalMapping
        var plain = String.UnicodeScalarView()
        var tone = 0
        for scalar in toned.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A:
                plain.append(scalar)
            case 0x0304, 0x0301, 0x030C, 0x0300:  // macron, acute, caron, grave
                guard tone == 0 else { return nil }
                tone = scalar.value == 0x0304 ? 1 : scalar.value == 0x0301 ? 2 : scalar.value == 0x030C ? 3 : 4
            case 0x0308:                          // diaeresis: ü is typed v
                guard plain.last == "u" else { return nil }
                plain.removeLast()
                plain.append("v")
            default:
                return nil
            }
        }
        guard !plain.isEmpty else { return nil }
        return Syllable(toned: toned, plain: String(plain), tone: tone)
    }
}
