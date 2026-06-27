//
//  AuthCoordinator.swift
//  SwiftAPIClient
//

import Foundation
import os

/// Coordinates authenticated state across one or more `APIClient` instances that
/// target the same API.
///
/// `AuthCoordinator` owns:
/// - The storage actor (`APIAuthentication`) for reading/writing tokens at rest.
/// - The in-memory cache of the current `AuthenticationState` so hot-path reads
///   (`isSignedIn`, building `Authorization` headers) can stay synchronous.
/// - The refresh handler and threshold that determine when and how to refresh
///   the access token.
/// - Coalescing of in-flight refresh attempts: concurrent refresh requests —
///   even from different `APIClient` instances sharing this coordinator — share
///   one in-flight task. The handler is invoked exactly once.
///
/// To run two `APIClient` instances on different `URLSession`s while keeping
/// auth state and refresh coordination consistent across them, construct a
/// single `AuthCoordinator` and pass it to each client.
public final class AuthCoordinator: @unchecked Sendable {

    // MARK: - Properties

    /// Persistent storage for the auth state (e.g., keychain).
    public let storage: any APIAuthentication

    /// Performs the actual token refresh request. Optional — APIs that don't
    /// support refresh (e.g., long-lived API keys) can omit it; calls to
    /// `performTokenRefresh` will throw `APIError.unauthorized` instead.
    public let refreshHandler: (any TokenRefreshHandler)?

    /// How close to expiration the current token must be before a proactive
    /// refresh fires. Defaults to 5 minutes.
    public let refreshThreshold: TimeInterval

    private let stateLock = NSLock()
    nonisolated(unsafe)
    private var cachedState: AuthenticationState?

    private let refreshLock = NSLock()
    nonisolated(unsafe)
    private var ongoingRefreshTask: Task<AuthenticationState, Error>?

    static let logger = Logger(subsystem: "SwiftAPIClient", category: "AuthCoordinator")

    // MARK: - Lifecycle

    public init(
        storage: any APIAuthentication,
        refreshHandler: (any TokenRefreshHandler)? = nil,
        refreshThreshold: TimeInterval = 300
    ) {
        self.storage = storage
        self.refreshHandler = refreshHandler
        self.refreshThreshold = refreshThreshold
    }

    // MARK: - Synchronous reads (hot path)

    /// The currently cached auth state, or nil if not signed in.
    /// Updated automatically by `loadCurrentState`, `performTokenRefresh`, and `signOut`,
    /// and manually by `updateCachedState`.
    public var cachedAuthState: AuthenticationState? {
        stateLock.withLock { cachedState }
    }

    public var isSignedIn: Bool {
        cachedAuthState != nil
    }

    /// Returns true if the cached token will expire within `refreshThreshold` seconds.
    /// Returns false if there is no cached state.
    public func shouldRefreshToken() -> Bool {
        guard let state = cachedAuthState else { return false }
        return state.expirationDate.timeIntervalSinceNow <= refreshThreshold
    }

    /// Updates the cached state directly without going through storage.
    /// Use this when you've just received fresh credentials (e.g., a sign-in
    /// completion) and want to update the cache without triggering a storage read.
    /// Note: this does NOT write to `storage` — the caller is responsible for
    /// persistence if needed.
    public func updateCachedState(_ state: AuthenticationState?) {
        stateLock.withLock { cachedState = state }
    }

    // MARK: - Asynchronous

    /// Loads the current state from storage and populates the cache.
    /// Call this once shortly after constructing the coordinator (typically at app start).
    public func loadCurrentState() async throws(AuthenticationError) {
        let state = try await storage.getCurrentState()
        stateLock.withLock { cachedState = state }
    }

    /// Clears storage and the in-memory cache. Any in-flight refresh is
    /// cancelled so its result cannot overwrite the cleared state.
    public func signOut() async {
        let inflight: Task<AuthenticationState, Error>? = refreshLock.withLock {
            let task = ongoingRefreshTask
            ongoingRefreshTask = nil
            return task
        }
        inflight?.cancel()
        await storage.clear()
        stateLock.withLock { cachedState = nil }
    }

    /// Performs (or joins) a token refresh.
    ///
    /// Concurrent callers — including those from different `APIClient` instances
    /// that share this coordinator — share one in-flight refresh task. The
    /// `refreshHandler` is invoked exactly once per refresh cycle. On success the
    /// new state is written to both `storage` and the cache; on failure the cache
    /// is left untouched and the error is rethrown to all waiters.
    ///
    /// - Parameter client: The `APIClient` to pass to the refresh handler. The
    ///   handler typically uses this to make the OAuth refresh request.
    /// - Returns: The new authentication state.
    /// - Throws: `APIError.unauthorized` if no refresh handler is configured or
    ///   no current state exists; otherwise rethrows the handler's error.
    @discardableResult
    public func performTokenRefresh(client: APIClient) async throws -> AuthenticationState {
        // Atomically check for an in-flight task; create one if not.
        // The caller that created the task is responsible for clearing the slot
        // when it completes. Joiners just await the shared value.
        let (task, isNewTask): (Task<AuthenticationState, Error>, Bool) = refreshLock.withLock {
            if let existing = ongoingRefreshTask {
                Self.logger.info("Token refresh already in progress, joining existing task")
                return (existing, false)
            }

            let new = Task<AuthenticationState, Error> { [self] in
                guard let refreshHandler else {
                    throw APIError.unauthorized
                }

                // Prefer the cached refresh token; fall back to storage when the
                // cache is cold or the access token has already expired. Reading
                // inside the task keeps concurrent cold callers coalesced.
                let refreshToken = if let cached = stateLock.withLock({ cachedState?.refreshToken }) {
                    cached
                } else {
                    try await storedRefreshToken()
                }

                Self.logger.info("Refreshing access token")

                let newState = try await refreshHandler.refreshToken(
                    using: refreshToken,
                    client: client
                )

                // If signOut() ran while the handler was in flight, the task
                // was cancelled. Bail before persisting so we don't overwrite
                // the cleared state with the refreshed token.
                try Task.checkCancellation()

                await storage.updateState(newState)
                stateLock.withLock { cachedState = newState }

                Self.logger.info("Token refresh successful")
                return newState
            }

            ongoingRefreshTask = new
            return (new, true)
        }

        defer {
            if isNewTask {
                refreshLock.withLock {
                    ongoingRefreshTask = nil
                }
            }
        }

        return try await task.value
    }

    /// The stored refresh token, tolerating an expired access token. Throws
    /// `APIError.unauthorized` when there are no stored credentials.
    private func storedRefreshToken() async throws -> String {
        do {
            return try await storage.getCurrentState().refreshToken
        } catch AuthenticationError.tokenExpired(let refreshToken) {
            return refreshToken
        } catch {
            throw APIError.unauthorized
        }
    }
}
