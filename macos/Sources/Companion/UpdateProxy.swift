import Foundation
import Network
import Security

/// The proxy for the companion's update check, update download and grammar
/// download. Turned off, those requests keep the system proxy: an empty
/// `proxyConfigurations` means that. Turned on, each session gets one
/// `ProxyConfiguration` and does not fall open onto a direct connection.
///
/// `ProxyConfiguration` (Network, macOS 14) is the interface Apple points
/// `URLSession` at. An HTTP proxy here is an HTTP CONNECT proxy, which is
/// how an HTTPS check and download go through it. The password stays in the
/// login Keychain; the rest is preference data.
@MainActor
@Observable
final class UpdateProxy {
    static let shared = UpdateProxy()

    enum Kind: String, CaseIterable, Identifiable {
        case http
        case socks5
        var id: String { rawValue }
        var title: String { self == .http ? "HTTP" : "SOCKS5" }
    }

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) } }
    var kind: Kind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: Key.kind) } }
    var host: String { didSet { UserDefaults.standard.set(host, forKey: Key.host) } }
    var portText: String { didSet { UserDefaults.standard.set(portText, forKey: Key.port) } }
    var username: String { didSet { UserDefaults.standard.set(username, forKey: Key.username) } }
    var password: String { didSet { ProxyPassword.write(password) } }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        kind = Kind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .http
        host = defaults.string(forKey: Key.host) ?? ""
        portText = defaults.string(forKey: Key.port) ?? ""
        username = defaults.string(forKey: Key.username) ?? ""
        password = ProxyPassword.read()
    }
}

/// One ephemeral session configuration, with the saved proxy applied.
enum UpdateProxyConfiguration {
    static func ephemeral() throws -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if let proxy = try proxy() { configuration.proxyConfigurations = [proxy] }
        return configuration
    }

    private static func proxy() throws -> ProxyConfiguration? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.enabled) else { return nil }
        guard let endpoint = endpoint(hostField: defaults.string(forKey: Key.host) ?? "",
                                      portField: defaults.string(forKey: Key.port) ?? "") else {
            throw InvalidUpdateProxy()
        }
        let kind = UpdateProxy.Kind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .http
        var proxy = switch kind {
        case .http: ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5: ProxyConfiguration(socksv5Proxy: endpoint)
        }
        proxy.allowFailover = false
        let username = (defaults.string(forKey: Key.username) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty { proxy.applyCredential(username: username, password: ProxyPassword.read()) }
        return proxy
    }

    /// The proxy to connect to. A pasted `http://host:port` or `host:port`
    /// is accepted; a port typed on its own wins over one carried in the host.
    private static func endpoint(hostField: String, portField: String) -> NWEndpoint? {
        var text = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var parsedPort: UInt16?
        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty,
           let urlHost = url.host, !urlHost.isEmpty {
            text = urlHost
            if let port = url.port, let value = UInt16(exactly: port), value > 0 { parsedPort = value }
        } else if text.hasPrefix("["), let bracket = text.firstIndex(of: "]") {
            let name = String(text[text.index(after: text.startIndex)..<bracket])
            let rest = text[text.index(after: bracket)...]
            text = name
            if rest.first == ":", let port = UInt16(rest.dropFirst()), port > 0 { parsedPort = port }
        } else if let colon = text.lastIndex(of: ":"), text.firstIndex(of: ":") == colon {
            let name = String(text[..<colon])
            if !name.isEmpty, let port = UInt16(text[text.index(after: colon)...]), port > 0 {
                text = name
                parsedPort = port
            }
        }
        let typed = portField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard let port = UInt16(typed), port > 0 else { return nil }
            parsedPort = port
        }
        guard let parsedPort, let port = NWEndpoint.Port(rawValue: parsedPort) else { return nil }
        let host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

struct InvalidUpdateProxy: Error, CustomStringConvertible, LocalizedError {
    var description: String { "代理地址或端口不正确。" }
    var errorDescription: String? { description }
}

private enum Key {
    static let enabled = "updateProxyEnabled"
    static let kind = "updateProxyKind"
    static let host = "updateProxyHost"
    static let port = "updateProxyPort"
    static let username = "updateProxyUsername"
}

/// The proxy password. The companion's own keychain item: not synced, and
/// readable after the first unlock, the same way the user-dictionary key is.
private enum ProxyPassword {
    private static let service = "OctoDot.update-proxy"
    private static let account = "password"

    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func write(_ password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if password.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "OctoDot update proxy"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
