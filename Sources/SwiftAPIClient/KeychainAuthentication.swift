//
//  KeychainAuthentication.swift
//  SwiftAPIClient
//

import Foundation

/// A generic keychain-based authentication storage implementation.
/// Uses UserDefaults for expiration date and Keychain for tokens.
public actor KeychainAuthentication: APIAuthentication {
    private let accessTokenKey: String
    private let refreshTokenKey: String
    private let expirationDateKey: String
    private let keychainHelper: KeychainHelper

    private var accessToken: String?
    private var refreshToken: String?
    private var expirationDate: Date?

    public init(
        accessTokenKey: String,
        refreshTokenKey: String,
        expirationDateKey: String,
        keychainHelper: KeychainHelper = DefaultKeychainHelper()
    ) {
        self.accessTokenKey = accessTokenKey
        self.refreshTokenKey = refreshTokenKey
        self.expirationDateKey = expirationDateKey
        self.keychainHelper = keychainHelper
    }

    public func load() throws(AuthenticationError) -> AuthenticationState {
        guard
            let accessTokenData = keychainHelper.loadData(forKey: accessTokenKey),
            let accessTokenString = String(data: accessTokenData, encoding: .utf8),
            let refreshTokenData = keychainHelper.loadData(forKey: refreshTokenKey),
            let refreshTokenString = String(data: refreshTokenData, encoding: .utf8)
        else { throw .noStoredCredentials }

        accessToken = accessTokenString
        refreshToken = refreshTokenString

        // Refresh auth if expiration is not found.
        guard
            let expiration = UserDefaults.standard.object(forKey: expirationDateKey) as? Date
        else { throw .tokenExpired(refreshToken: refreshTokenString) }

        expirationDate = expiration

        return AuthenticationState(accessToken: accessTokenString, refreshToken: refreshTokenString, expirationDate: expiration)
    }

    public func getCurrentState() throws(AuthenticationError) -> AuthenticationState {
        guard
            let accessToken,
            let refreshToken,
            let expirationDate
        else { return try load() }

        guard expirationDate > .now else { throw .tokenExpired(refreshToken: refreshToken) }

        return AuthenticationState(accessToken: accessToken, refreshToken: refreshToken, expirationDate: expirationDate)
    }

    public func updateState(_ state: AuthenticationState) {
        // Keep in memory
        accessToken = state.accessToken
        refreshToken = state.refreshToken

        // Save to keychain
        _ = keychainHelper.setString(value: state.accessToken, forKey: accessTokenKey)
        _ = keychainHelper.setString(value: state.refreshToken, forKey: refreshTokenKey)

        UserDefaults.standard.set(state.expirationDate, forKey: expirationDateKey)
    }

    public func clear() {
        accessToken = nil
        refreshToken = nil
        expirationDate = nil

        _ = keychainHelper.deleteItem(forKey: accessTokenKey)
        _ = keychainHelper.deleteItem(forKey: refreshTokenKey)

        UserDefaults.standard.removeObject(forKey: expirationDateKey)
    }
}

/// Protocol for keychain operations to enable testability
public protocol KeychainHelper: Sendable {
    func setString(value: String, forKey key: String) -> Bool
    func loadData(forKey key: String) -> Data?
    func deleteItem(forKey key: String) -> Bool
}

/// Default implementation using iOS Keychain
public struct DefaultKeychainHelper: KeychainHelper {
    public init() {}

    public func setString(value: String, forKey key: String) -> Bool {
        let data = value.data(using: String.Encoding.utf8, allowLossyConversion: false)!

        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String
        ]

        var result: OSStatus = SecItemAdd(keychainQuery as CFDictionary, nil)

        if result == errSecDuplicateItem {
            result = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        return result == errSecSuccess
    }

    public func loadData(forKey key: String) -> Data? {
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne as String,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String
        ]

        var dataTypeRef: AnyObject?

        let status: OSStatus = withUnsafeMutablePointer(to: &dataTypeRef) {
            SecItemCopyMatching(keychainQuery as CFDictionary, UnsafeMutablePointer($0))
        }

        if status == errSecItemNotFound {
            if updateAccessibleValue(for: key) {
                return loadData(forKey: key)
            }
        }

        if status == -34018 {
            return dataTypeRef as? Data
        }

        if status == errSecSuccess {
            return dataTypeRef as? Data
        } else {
            return nil
        }
    }

    public func deleteItem(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key
        ]

        let status: OSStatus = SecItemDelete(query as CFDictionary)

        return status == noErr
    }

    /// Sets kSecAttrAccessible to kSecAttrAccessibleAfterFirstUnlock from the default value
    private func updateAccessibleValue(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { return false }
        return true
    }
}
