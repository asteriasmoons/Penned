//
// KeychainHelper.swift
// Penned
//

import Foundation
import Security

enum KeychainHelper {

    enum Key: String {
        case accessToken = "com.penned.accessToken"
        case refreshToken = "com.penned.refreshToken"
        case currentAppleUserID = "com.penned.currentAppleUserID"
        case currentAccountIdentity = "com.penned.currentAccountIdentity"
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]

        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(_ key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw AccountError.keychainUnavailable
        }

        return string
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func clearAll() {
        delete(.accessToken)
        delete(.refreshToken)
        delete(.currentAppleUserID)
        delete(.currentAccountIdentity)
    }

}
