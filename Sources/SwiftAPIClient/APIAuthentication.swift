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
