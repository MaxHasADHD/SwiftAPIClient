//
//  APIAuthentication.swift
//  SwiftAPIClient
//

import Foundation

public struct AuthenticationState: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expirationDate: Date

    public init(accessToken: String, refreshToken: String, expirationDate: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expirationDate = expirationDate
    }
}

public enum AuthenticationError: Error, Equatable {
    /// Token was found, but is past the expiration date.
    case tokenExpired(refreshToken: String)
    /// Thrown if credentials could not be retrieved.
    case noStoredCredentials
}

public protocol APIAuthentication: Sendable {
    /// Returns the current access token, refresh token, and expiration date.
    func getCurrentState() async throws(AuthenticationError) -> AuthenticationState
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
