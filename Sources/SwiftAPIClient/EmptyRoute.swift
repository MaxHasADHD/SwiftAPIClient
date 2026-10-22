//
//  EmptyRoute.swift
//  SwiftAPIClient
//

import Foundation

// MARK: - No data response

public struct EmptyRoute: Sendable {
    private let apiClient: APIClient

    public var path: String
    public let method: Method
    public let requiresAuthentication: Bool
    public var queryItems: [String: String]

    public var body: (any Encodable & Hashable & Sendable)?

    /// Replaces the client's base URL for this route. See `APIClient.mutableRequest`.
    public var baseURL: URL?

    // MARK: - Lifecycle

    public init(
        path: String,
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        baseURL: URL? = nil,
        apiClient: APIClient
    ) {
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.baseURL = baseURL
        self.apiClient = apiClient
    }

    public init(
        paths: [CustomStringConvertible?],
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        baseURL: URL? = nil,
        apiClient: APIClient
    ) {
        self.path = paths.compactMap { $0?.description }.joined(separator: "/")
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.baseURL = baseURL
        self.apiClient = apiClient
    }

    // MARK: - Perform

    public func perform(retryLimit: Int = 3) async throws {
        let request = try await apiClient.mutableRequest(
            forPath: path,
            baseURL: baseURL,
            withQuery: queryItems,
            isAuthorized: requiresAuthentication,
            withHTTPMethod: method,
            body: body
        )
        let _ = try await apiClient.fetchData(request: request, retryLimit: retryLimit)
    }
}
