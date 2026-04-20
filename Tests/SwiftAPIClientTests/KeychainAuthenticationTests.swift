//
//  KeychainAuthenticationTests.swift
//  SwiftAPIClient
//

import Foundation
import Testing
@testable import SwiftAPIClient

/// In-memory KeychainHelper so tests don't touch the real keychain.
final class InMemoryKeychainHelper: KeychainHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func setString(value: String, forKey key: String) -> Bool {
        lock.withLock { storage[key] = value.data(using: .utf8) }
        return true
    }

    func loadData(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func deleteItem(forKey key: String) -> Bool {
        _ = lock.withLock { storage.removeValue(forKey: key) }
        return true
    }
}

@Suite("KeychainAuthentication Tests")
struct KeychainAuthenticationTests {

    /// Reproduces the bug where `updateState` fails to refresh the in-memory
    /// `expirationDate`, so the next `getCurrentState()` throws `.tokenExpired`
    /// with the brand-new refresh token even though sign-in just succeeded.
    ///
    /// Scenario from production:
    /// 1. App launches, old persisted state is loaded into memory (expired date cached).
    /// 2. Token refresh fails — user re-authenticates.
    /// 3. `updateState(newState)` writes new tokens to keychain and new date to
    ///    UserDefaults, but leaves the stale in-memory `expirationDate` alone.
    /// 4. Next `getCurrentState()` sees all three in-memory fields non-nil,
    ///    skips `load()`, sees the old expired date, throws `.tokenExpired`
    ///    with the *new* refresh token.
    @Test("updateState refreshes the in-memory expiration date after re-authentication")
    func updateStateRefreshesInMemoryExpiration() async throws {
        let suffix = UUID().uuidString
        let accessTokenKey = "test-access-\(suffix)"
        let refreshTokenKey = "test-refresh-\(suffix)"
        let expirationDateKey = "test-expiration-\(suffix)"

        let helper = InMemoryKeychainHelper()

        // Pre-populate storage as if the user had previously authenticated and the token has since expired.
        _ = helper.setString(value: "old-access", forKey: accessTokenKey)
        _ = helper.setString(value: "old-refresh", forKey: refreshTokenKey)
        UserDefaults.standard.set(Date().addingTimeInterval(-3600), forKey: expirationDateKey)
        defer { UserDefaults.standard.removeObject(forKey: expirationDateKey) }

        let auth = KeychainAuthentication(
            accessTokenKey: accessTokenKey,
            refreshTokenKey: refreshTokenKey,
            expirationDateKey: expirationDateKey,
            keychainHelper: helper
        )

        // Simulate app startup: `load()` caches the expired state (including the expired date) in the actor.
        _ = try? await auth.getCurrentState()

        // User re-authenticates with a fresh token that is valid for 24h.
        let newExpiration = Date().addingTimeInterval(86_400)
        let newState = AuthenticationState(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expirationDate: newExpiration
        )
        await auth.updateState(newState)

        // Next API call resolves auth state — should return the new state, not throw tokenExpired.
        let current = try await auth.getCurrentState()
        #expect(current.accessToken == "new-access")
        #expect(current.refreshToken == "new-refresh")
        #expect(current.expirationDate == newExpiration)
    }
}
