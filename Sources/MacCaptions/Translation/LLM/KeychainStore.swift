import Foundation
import Security

/// API keys live in the login Keychain, never in settings files, session folders or logs.
///
/// A key is filed under provider AND server origin (scheme, host, port), so changing the address of a provider can
/// never send an existing key to a different server, or send an https key over plain http.
///
/// Note: the app is ad-hoc signed, so after an update macOS sees a "different" app and asks once for the login
/// password before handing a saved key to it ("Always Allow" remembers it for that version).
enum KeychainStore {
    static var service = "io.github.chengxuphd.maccaptions.apikey"      // changed only by tests

    static func account(provider: LLMProvider, endpoint: LLMEndpoint) -> String { "\(provider.rawValue)@\(endpoint.origin)" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
        }
    }

    /// A key saved by an earlier build of the app can refuse to be deleted or replaced by this one. A new key is then
    /// stored beside it as "account#2", "#3"…, and the newest one is used. These are the stored names, newest first.
    /// Reads attributes only, which never triggers a password prompt.
    private static func storedNames(_ account: String) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        func generation(_ name: String) -> Int? {
            if name == account { return 1 }
            guard name.hasPrefix(account + "#") else { return nil }
            return Int(name.dropFirst(account.count + 1))
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap { name in generation(name).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Whether a key is saved.
    static func exists(_ account: String) -> Bool { !storedNames(account).isEmpty }

    /// nil when no key is saved; throws when macOS refuses access. May block while macOS shows its prompt,
    /// so call it away from the main thread.
    static func read(_ account: String) throws -> String? {
        guard let name = storedNames(account).first else { return nil }
        var q = query(name)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    /// Saves a new item, owned by the current build of the app, and removes older ones where macOS allows it.
    static func save(_ key: String, account: String) throws {
        let older = storedNames(account)
        let highest = older.first.map { Int($0.dropFirst(account.count + 1)) ?? 1 } ?? 0
        let name = highest == 0 ? account : "\(account)#\(highest + 1)"
        var q = query(name)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrLabel as String] = "MacCaptions API key (\(account))"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        for old in older { SecItemDelete(query(old) as CFDictionary) }
    }

    static func delete(_ account: String) throws {
        var refused: OSStatus?
        for name in storedNames(account) {
            let status = SecItemDelete(query(name) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { refused = status }
        }
        if let refused { throw RemovalRefused(status: refused) }
    }

    struct RemovalRefused: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            "macOS did not let this version remove a key saved by an earlier one. Delete it in the Keychain Access app: search for “MacCaptions API key”. (error \(status))"
        }
    }
}
