import Foundation
import Security

/// Generic-password items, device only, available after first unlock (so background work can read them).
public struct Keychain: Sendable {
    public var service: String

    public init(service: String = "de.tagwerk.app") {
        self.service = service
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var q = base(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public func has(_ account: String) -> Bool { !(get(account) ?? "").isEmpty }
}

public enum SecretKey {
    public static let githubToken = "github-token"
    public static let passphrase = "passphrase"
    public static let claudeKey = "claude-api-key"
    public static func mailPassword(_ id: UUID) -> String { "mail-\(id.uuidString)" }
}
