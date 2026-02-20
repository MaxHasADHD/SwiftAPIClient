//
//  EmptyRoute.swift
//  SwiftAPIClient
//

import Foundation

// MARK: - No data response

public struct EmptyRoute: Sendable {
    private let apiManager: APIManager

    public var path: String
    public let method: Method
    public let requiresAuthentication: Bool
    public var queryItems: [String: String]

    public var body: (any Encodable & Hashable & Sendable)?

    // MARK: - Lifecycle

    public init(
        path: String,
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        apiManager: APIManager
    ) {
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.apiManager = apiManager
    }

    public init(
        paths: [CustomStringConvertible?],
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        apiManager: APIManager
    ) {
        self.path = paths.compactMap { $0?.description }.joined(separator: "/")
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.apiManager = apiManager
    }

    // MARK: - Perform

    public func perform(retryLimit: Int = 3) async throws {
        let request = try apiManager.mutableRequest(
            forPath: path,
            withQuery: queryItems,
            isAuthorized: requiresAuthentication,
            withHTTPMethod: method,
            body: body
        )
        let _ = try await apiManager.fetchData(request: request, retryLimit: retryLimit)
    }
}
