import Foundation
import os
import Security

/// Small wrapper for storing account secrets (such as a Spotify refresh token)
/// in the iOS Keychain instead of preferences.
///
/// Some re-signing tools drop the Keychain entitlement (the Keychain then answers
/// -34018). Rather than make sign-in impossible there, a secret the Keychain refuses
/// is kept in memory, so it works until the app quits.
nonisolated enum Keychain {
    private static let service = "fun.staraep.fiber"
    private static let unsaved = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        var item = query(key)
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        unsaved.withLock { $0[key] = saved ? nil : value }
    }

    static func get(_ key: String) -> String? {
        var item = query(key)
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return unsaved.withLock { $0[key] }
    }

    static func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
        unsaved.withLock { $0[key] = nil }
    }
}
