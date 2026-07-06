//
//  APIAuthentication.swift
//  SwiftAPIClient
//

import Foundation

public struct AuthenticationState: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expirationDate: Date

    /// Whether the access token is past its expiration date. An expired state
    /// still represents a signed-in user — it just needs a token refresh.
    public var isExpired: Bool {
        expirationDate <= .now
    }

    public init(accessToken: String, refreshToken: String, expirationDate: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expirationDate = expirationDate
    }
}

public enum AuthenticationError: Error, Equatable {
    /// The client has no `AuthCoordinator` configured — a setup error, distinct
    /// from the user simply having no stored credentials (a `nil` state).
    case notConfigured
}

public protocol APIAuthentication: Sendable {
    /// Returns the stored credentials, or nil when the user has never
    /// authenticated (or has signed out). Expiration is not an error and not
    /// nil: implementations must return whatever credentials exist — even
    /// expired ones. Callers check `AuthenticationState.isExpired` to decide
    /// whether a refresh is needed.
    func getCurrentState() async -> AuthenticationState?
    /// Store the latest state
    func updateState(_ state: AuthenticationState) async
    /// Delete the data
    func clear() async
}

/// Protocol for handling token refresh operations.
/// Implement this protocol to define how your API handles refreshing expired or expiring access tokens.
public protocol TokenRefreshHandler: Sendable {
    /// Refreshes the access token using the provided refresh token.
    /// - Parameters:
    ///   - refreshToken: The refresh token to use for obtaining a new access token
    ///   - client: The APIClient instance to use for making the refresh request
    /// - Returns: A new AuthenticationState with updated tokens
    /// - Throws: Any error if the refresh fails
    func refreshToken(using refreshToken: String, client: APIClient) async throws -> AuthenticationState
}
