//
//  APIClient.swift
//  SwiftAPIClient
//

import Foundation
import os

/// A generic API client that can be configured for any REST API.
open class APIClient: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let baseURL: URL
        public let additionalHeaders: [String: String]
        /// Names of the headers SwiftAPIClient reads to extract pagination
        /// metadata. Defaults to Trakt's `X-Pagination-*` conventions.
        public let paginationHeaders: PaginationHeaders
        public let responseHandler: any ResponseHandler
        public let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy

        /// - Note: As of the introduction of `AuthCoordinator`, this field is only
        ///   consulted by the deprecated `init(configuration:session:authStorage:)`.
        ///   New code should construct an `AuthCoordinator` with its own refresh
        ///   handler and pass it to the `init(configuration:session:authCoordinator:)`.
        public let tokenRefreshHandler: (any TokenRefreshHandler)?

        /// - Note: As of the introduction of `AuthCoordinator`, this field is only
        ///   consulted by the deprecated `init(configuration:session:authStorage:)`.
        ///   New code should set the threshold on `AuthCoordinator` directly.
        public let tokenRefreshThreshold: TimeInterval

        public init(
            baseURL: URL,
            additionalHeaders: [String: String] = [:],
            paginationHeaders: PaginationHeaders = .default,
            responseHandler: any ResponseHandler = DefaultResponseHandler(),
            dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .custom(customDateDecodingStrategy),
            tokenRefreshHandler: (any TokenRefreshHandler)? = nil,
            tokenRefreshThreshold: TimeInterval = 300
        ) {
            self.baseURL = baseURL
            self.additionalHeaders = additionalHeaders
            self.paginationHeaders = paginationHeaders
            self.responseHandler = responseHandler
            self.dateDecodingStrategy = dateDecodingStrategy
            self.tokenRefreshHandler = tokenRefreshHandler
            self.tokenRefreshThreshold = tokenRefreshThreshold
        }
    }

    // MARK: - Properties

    public let configuration: Configuration
    public let session: URLSession

    /// Coordinates auth state (cache + refresh) for this client. Optional —
    /// clients that only hit unauthenticated endpoints can omit it.
    ///
    /// Multiple `APIClient` instances may share a single `AuthCoordinator`
    /// (typical use case: one logical API exposed over two `URLSession`s for
    /// network-resource isolation). When shared, refresh requests across all
    /// clients are coalesced into a single in-flight handler invocation, and
    /// auth state updates are observed by all of them.
    public let authCoordinator: AuthCoordinator?

    internal static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let logger = Logger(subsystem: "SwiftAPIClient", category: "APIClient")

    // MARK: - Lifecycle

    public init(
        configuration: Configuration,
        session: URLSession = URLSession(configuration: .default),
        authCoordinator: AuthCoordinator? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.authCoordinator = authCoordinator
    }

    /// Convenience initializer that constructs an `AuthCoordinator` from the
    /// supplied `authStorage` plus `configuration.tokenRefreshHandler` and
    /// `configuration.tokenRefreshThreshold`, then delegates to the designated
    /// initializer.
    @available(*, deprecated, message: "Construct an AuthCoordinator and pass it via init(configuration:session:authCoordinator:). Move tokenRefreshHandler and tokenRefreshThreshold off of Configuration onto the coordinator.")
    public convenience init(
        configuration: Configuration,
        session: URLSession = URLSession(configuration: .default),
        authStorage: any APIAuthentication
    ) {
        let coordinator = AuthCoordinator(
            storage: authStorage,
            refreshHandler: configuration.tokenRefreshHandler,
            refreshThreshold: configuration.tokenRefreshThreshold
        )
        self.init(configuration: configuration, session: session, authCoordinator: coordinator)
    }

    // MARK: - Authentication

    /// Returns true if the coordinator has a cached auth state — even an
    /// expired one, since an expired token still represents a signed-in user.
    /// Returns false if no coordinator is configured or the cache is empty.
    public var isSignedIn: Bool {
        authCoordinator?.isSignedIn ?? false
    }

    /// True when credentials exist but the access token is past its expiration
    /// date, meaning a token refresh is needed before authenticated requests
    /// will succeed. Returns false if no coordinator is configured.
    public var isTokenExpired: Bool {
        authCoordinator?.isTokenExpired ?? false
    }

    /**
     Loads the current authentication state from the coordinator's storage,
     populates its cache, and returns the loaded state. Call this once shortly
     after initializing the client when an `authCoordinator` is configured.

     A nil result means the user has never authenticated (or signed out); an
     expired state means signed in but needing a token refresh.

     - Throws: `AuthenticationError.notConfigured` if no coordinator is set.
     */
    @discardableResult
    public func refreshCurrentAuthState() async throws(AuthenticationError) -> AuthenticationState? {
        guard let authCoordinator else { throw .notConfigured }
        return await authCoordinator.loadCurrentState()
    }

    /**
     Updates the coordinator's cached auth state directly without reading from
     storage. Use this when you've just saved credentials and want to immediately
     update the cache.
     */
    public func updateCachedAuthState(_ state: AuthenticationState?) {
        authCoordinator?.updateCachedState(state)
    }

    public func signOut() async {
        guard let authCoordinator else { return }
        await authCoordinator.signOut()
    }

    // MARK: - Request Building

    /// Builds a request for the given path. For authorized requests, waits for
    /// the coordinator's first storage load if it hasn't happened yet, so a
    /// request built early in the app's lifetime still finds stored
    /// credentials. Throws `APIClientError.userNotAuthorized` only when no
    /// credentials exist at all (never authenticated, or signed out).
    ///
    /// `baseURL` replaces the configuration's for this request only, for an API
    /// that serves some endpoints from another host. Headers are unchanged.
    public func mutableRequest(
        forPath path: String,
        baseURL: URL? = nil,
        withQuery query: [String: String] = [:],
        isAuthorized authorized: Bool,
        withHTTPMethod httpMethod: Method,
        body: Encodable? = nil
    ) async throws -> URLRequest {
        // Build URL
        guard var components = URLComponents(url: baseURL ?? configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIClientError.malformedURL
        }

        // Append path to base URL
        if components.path.hasSuffix("/") {
            components.path += path
        } else {
            components.path += "/" + path
        }

        if query.isEmpty == false {
            var queryItems: [URLQueryItem] = []
            for (key, value) in query {
                queryItems.append(URLQueryItem(name: key, value: value))
            }
            components.queryItems = queryItems
        }

        guard let url = components.url else { throw APIClientError.malformedURL }

        // Request
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod.rawValue

        // Headers
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add additional headers from configuration
        for (key, value) in configuration.additionalHeaders {
            request.addValue(value, forHTTPHeaderField: key)
        }

        if authorized {
            // Make sure a cold cache reflects storage before concluding the
            // user isn't signed in — no-op after the first load.
            await authCoordinator?.ensureLoaded()
            if let accessToken = authCoordinator?.cachedAuthState?.accessToken {
                request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            } else {
                throw APIClientError.userNotAuthorized
            }
        }

        // Body
        if let body {
            request.httpBody = try Self.jsonEncoder.encode(body)
        }

        return request
    }

    // MARK: - Error Handling

    private func handleResponse(response: URLResponse?) throws {
        try configuration.responseHandler.handleResponse(response)
    }

    private static let errorBodyLogLimit = 1024

    /// Logs why a request was rejected. Marked `.public` because these are API error
    /// payloads, not user content, and OSLog would otherwise redact them out of an
    /// exported log — where they are needed.
    private func logErrorBody(_ data: Data, for request: URLRequest, response: URLResponse?) {
        guard !data.isEmpty else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let path = request.url?.path ?? "?"

        guard var body = String(data: data.prefix(Self.errorBodyLogLimit), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty
        else {
            Self.logger.error("HTTP \(status, privacy: .public) \(path, privacy: .public): \(data.count, privacy: .public)-byte non-text error body")
            return
        }
        if data.count > Self.errorBodyLogLimit { body += "… (truncated)" }

        Self.logger.error("HTTP \(status, privacy: .public) \(path, privacy: .public): \(body, privacy: .public)")
    }

    // MARK: - Perform Requests

    /**
     Downloads the contents of a URL based on the specified URL request. Handles ``APIError/retry(after:)`` up to the specified `retryLimit`.
     Proactively refreshes the token before sending when it is about to expire (authenticated requests only).

     - Note: This method can throw any error type defined by your `ResponseHandler`. The automatic retry functionality
             only applies to `APIError.retry(after:)` errors and automatic token refresh for 401 errors.
     */
    public func fetchData(request: URLRequest, retryLimit: Int = 3) async throws -> (Data, URLResponse) {
        var retryCount = 0
        var tokenRefreshAttempted = false
        var cachedTokenShortcutTried = false
        var currentRequest = request

        // Only check for token refresh if this is an authenticated request.
        // This prevents deadlock when the refresh handler uses this client for
        // its own (unauthenticated) refresh request.
        let isAuthenticatedRequest = request.value(forHTTPHeaderField: "Authorization") != nil

        if isAuthenticatedRequest, let coordinator = authCoordinator, coordinator.shouldRefreshToken() {
            Self.logger.info("Token expires soon, proactively refreshing")
            try await coordinator.performTokenRefresh(client: self)

            // Update the Authorization header with the new token
            if let newAccessToken = coordinator.cachedAuthState?.accessToken {
                currentRequest.setValue("Bearer \(newAccessToken)", forHTTPHeaderField: "Authorization")
            }
        }

        while true {
            do {
                let (data, response) = try await session.data(for: currentRequest)
                do {
                    try handleResponse(response: response)
                } catch {
                    // Otherwise unreachable: `handleResponse` sees only the
                    // `URLResponse`, and `perform` throws here before decoding `data`.
                    logErrorBody(data, for: currentRequest, response: response)
                    throw error
                }
                return (data, response)
            } catch let error as APIError {
                // Handle APIError retry logic
                switch error {
                case .retry(let retryDelay):
                    retryCount += 1
                    if retryCount >= retryLimit {
                        throw error
                    }
                    // Add jitter to prevent thundering herd when multiple
                    // concurrent requests all receive 429 simultaneously
                    let jitter = TimeInterval.random(in: 0...30)
                    let actualDelay = retryDelay + jitter
                    Self.logger.info("Retrying after delay: \(actualDelay) (base: \(retryDelay), jitter: \(jitter))")
                    try await Task.sleep(for: .seconds(actualDelay))
                    try Task.checkCancellation()
                case .unauthorized:
                    // Only attempt token refresh for authenticated requests
                    // Unauthenticated requests getting 401 should just fail immediately
                    // This prevents deadlock when refresh handler's request gets 401
                    let currentAuthHeader = currentRequest.value(forHTTPHeaderField: "Authorization")
                    let isAuthenticatedRequest = currentAuthHeader != nil

                    guard isAuthenticatedRequest,
                          let coordinator = authCoordinator,
                          coordinator.refreshHandler != nil
                    else { throw error }

                    // If another client (or another in-flight request) refreshed
                    // while this request was in flight, the coordinator's cache
                    // is now ahead of the token we sent. Retry once with the
                    // cached token before paying for another refresh round-trip.
                    if !cachedTokenShortcutTried,
                       let cachedAccessToken = coordinator.cachedAuthState?.accessToken,
                       currentAuthHeader != "Bearer \(cachedAccessToken)" {
                        cachedTokenShortcutTried = true
                        Self.logger.info("Received 401; cached token differs from the one sent, retrying with cached token before refreshing")
                        currentRequest.setValue("Bearer \(cachedAccessToken)", forHTTPHeaderField: "Authorization")
                        continue
                    }

                    if !tokenRefreshAttempted {
                        tokenRefreshAttempted = true
                        Self.logger.info("Received 401, attempting token refresh")
                        do {
                            try await coordinator.performTokenRefresh(client: self)
                            // Update the Authorization header with the new token
                            if let newAccessToken = coordinator.cachedAuthState?.accessToken {
                                currentRequest.setValue("Bearer \(newAccessToken)", forHTTPHeaderField: "Authorization")
                            }
                            // Retry the request with the new token
                            continue
                        } catch {
                            Self.logger.error("Token refresh failed: \(error)")
                            throw error
                        }
                    }

                    throw error
                default:
                    throw error
                }
            } catch {
                // For non-APIError types (custom errors from ResponseHandler), throw immediately
                throw error
            }
        }
    }

    /**
     Downloads the contents of a URL based on the specified URL request, and decodes the data into an API object.
     Token refresh (proactive and 401-triggered) is handled by `fetchData`.
     */
    public func perform<T: Codable & Hashable & Sendable>(request: URLRequest, retryLimit: Int = 3) async throws -> T {
        let (data, response) = try await fetchData(request: request, retryLimit: retryLimit)
        return try decodeObject(from: data, response: response)
    }

    /// Decodes data into an API object. If the object type is `PagedObject` the headers will be extracted from the response.
    private func decodeObject<T: Codable & Hashable & Sendable>(from data: Data, response: URLResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = configuration.dateDecodingStrategy

        if let pagedType = T.self as? PagedObjectProtocol.Type {
            let decodedItems = try decoder.decode(pagedType.objectType, from: data)
            var currentPage = 0
            var pageCount = 0
            var limit: Int?
            var itemCount: Int?
            if let r = response as? HTTPURLResponse {
                let headers = configuration.paginationHeaders
                currentPage = Int(r.value(forHTTPHeaderField: headers.page) ?? "0") ?? 0
                pageCount = Int(r.value(forHTTPHeaderField: headers.pageCount) ?? "0") ?? 0
                limit = (r.value(forHTTPHeaderField: headers.limit)).flatMap(Int.init)
                itemCount = (r.value(forHTTPHeaderField: headers.itemCount)).flatMap(Int.init)
            }
            let pagination = PaginationInfo(currentPage: currentPage, pageCount: pageCount, limit: limit, itemCount: itemCount)
            return pagedType.createPagedObject(with: decodedItems, pagination: pagination) as! T
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Errors

public enum APIClientError: Error {
    case malformedURL
    case userNotAuthorized
    case couldNotParseData
}
