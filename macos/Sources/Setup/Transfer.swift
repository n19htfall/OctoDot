import Foundation

/// The user's data in transit: out of the IME for a backup, and back in. Plaintext, so it only ever travels in
/// memory and through pipes, never written to disk as it is.
struct Transfer: Codable, Equatable, Sendable {
    /// The user dictionary's text form (engine/userdb.goose).
    var userDictionary: Data?
    /// custom_phrases.txt.
    var customPhrases: Data?
    /// The IME's preferences, as a property list.
    var preferences: Data?
}
