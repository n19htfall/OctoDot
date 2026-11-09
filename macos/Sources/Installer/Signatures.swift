import Foundation
import Security

/// Code-signature checks: what the installer accepts to install, and who may
/// talk to it.
enum Signatures {
    /// The requirement for code of this project: signed by its team (Apple
    /// Development or Developer ID, whose leaf certificates both carry the
    /// team as their organizational unit), with this identifier.
    static func requirement(_ identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(Identity.team)\" and identifier \"\(identifier)\""
    }

    /// The bundle at `url` is intact (every file sealed, nested code too) and
    /// signed by the team with `identifier`.
    static func valid(_ url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(identifier) as CFString, [], &requirement) == errSecSuccess
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The bundle carries a notarization ticket Apple issued (a release; a
    /// development build has none).
    static func notarized(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Whether the running companion is a release (Developer ID): then an
    /// update must be notarized too.
    static func isDeveloperID(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
