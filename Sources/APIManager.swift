//
//  APIManager.swift
//  SwiftAPIClient
//

import Foundation
import os

/// A generic API manager that can be configured for any REST API.
open class APIManager: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let baseURL: URL
        public let additionalHeaders: [String: String]
        public let paginationPageHeader: String
        public let paginationPageCountHeader: String

        public init(
            baseURL: URL,
            additionalHeaders: [String: String] = [:],
            paginationPageHeader: String = "x-pagination-page",
            paginationPageCountHeader: String = "x-pagination-page-count"
        ) {
            self.baseURL = baseURL
            self.additionalHeaders = additionalHeaders
            self.paginationPageHeader = paginationPageHeader
            self.paginationPageCountHeader = paginationPageCountHeader
        }
    }

    // MARK: - Properties

    public let configuration: Configuration
    public let session: URLSession

    private let authStorage: (any APIAuthentication)?

    private let authStateLock = NSLock()
    nonisolated(unsafe)
    private var cachedAuthState: AuthenticationState?

    internal static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let logger = Logger(subsystem: "SwiftAPIClient", category: "APIManager")

    // MARK: - Lifecycle

    public init(
        configuration: Configuration,
        session: URLSession = URLSession(configuration: .default),
        authStorage: (any APIAuthentication)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.authStorage = authStorage
    }

    public init(
        configuration: Configuration,
        session: URLSession = URLSession(configuration: .default),
        authStorage: (any APIAuthentication)? = nil
    ) async {
        self.configuration = configuration
        self.session = session
        self.authStorage = authStorage

        try? await refreshCurrentAuthState()
    }

    // MARK: - Authentication

    public var isSignedIn: Bool {
        get {
            authStateLock.lock()
            defer { authStateLock.unlock() }
            return cachedAuthState != nil
        }
    }

    /**
     Gets the current authentication state from the authentication storage, and caches the result to make requests.
     You should only have to call this once shortly after initializing the `APIManager`, unless you use the async initializer, which calls this function automatically.
     */
    public func refreshCurrentAuthState() async throws(AuthenticationError) {
        guard let authStorage else { throw .noStoredCredentials }
        let currentState = try await authStorage.getCurrentState()
        authStateLock.withLock {
            cachedAuthState = currentState
        }
    }

    public func signOut() async {
        guard let authStorage else { return }
        await authStorage.clear()
        authStateLock.withLock {
            cachedAuthState = nil
        }
    }

    // MARK: - Request Building

    public func mutableRequest(
        forPath path: String,
        withQuery query: [String: String] = [:],
        isAuthorized authorized: Bool,
        withHTTPMethod httpMethod: Method,
        body: Encodable? = nil
    ) throws -> URLRequest {
        // Build URL
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIManagerError.malformedURL
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

        guard let url = components.url else { throw APIManagerError.malformedURL }

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
            if let accessToken = cachedAuthState?.accessToken {
                request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            } else {
                throw APIManagerError.userNotAuthorized
            }
        }

        // Body
        if let body {
            request.httpBody = try Self.jsonEncoder.encode(body)
        }

        return request
    }

    // MARK: - Error Handling

    private func handleResponse(response: URLResponse?) throws(APIError) {
        guard let response else { return }
        guard let httpResponse = response as? HTTPURLResponse else { throw .unhandled(response) }

        guard 200...299 ~= httpResponse.statusCode else {
            switch httpResponse.statusCode {
            case 400: throw .badRequest
            case 401: throw .unauthorized
            case 403: throw .forbidden
            case 404: throw .noRecordFound
            case 405: throw .noMethodFound
            case 409: throw .resourceAlreadyCreated
            case 412: throw .preconditionFailed
            case 420: throw .accountLimitExceeded
            case 422: throw .unprocessableEntity
            case 423: throw .accountLocked
            case 426: throw .vipOnly
            case 429:
                let rawRetryAfter = httpResponse.allHeaderFields["retry-after"]
                if let retryAfterString = rawRetryAfter as? String,
                   let retryAfter = TimeInterval(retryAfterString) {
                    throw .retry(after: retryAfter)
                } else if let retryAfter = rawRetryAfter as? TimeInterval {
                    throw .retry(after: retryAfter)
                } else {
                    throw .rateLimitExceeded(httpResponse)
                }
            case 500: throw .serverError
            // Try again in 30 seconds
            case 502, 503, 504: throw .serverOverloaded
            case 500...600: throw .cloudflareError
            default:
                throw .unhandled(httpResponse)
            }
        }
    }

    // MARK: - Perform Requests

    /**
     Downloads the contents of a URL based on the specified URL request. Handles ``APIError/retry(after:)`` up to the specified `retryLimit`
     */
    public func fetchData(request: URLRequest, retryLimit: Int = 3) async throws -> (Data, URLResponse) {
        var retryCount = 0

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                try handleResponse(response: response)
                return (data, response)
            } catch let error as APIError {
                switch error {
                case .retry(let retryDelay):
                    retryCount += 1
                    if retryCount >= retryLimit {
                        throw error
                    }
                    Self.logger.info("Retrying after delay: \(retryDelay)")
                    try await Task.sleep(for: .seconds(retryDelay))
                    try Task.checkCancellation()
                default:
                    throw error
                }
            } catch {
                throw error
            }
        }
    }

    /**
     Downloads the contents of a URL based on the specified URL request, and decodes the data into an API object
     */
    public func perform<T: Codable & Hashable & Sendable>(request: URLRequest, retryLimit: Int = 3) async throws -> T {
        let (data, response) = try await fetchData(request: request, retryLimit: retryLimit)
        return try decodeObject(from: data, response: response)
    }

    /// Decodes data into an API object. If the object type is `PagedObject` the headers will be extracted from the response.
    private func decodeObject<T: Codable & Hashable & Sendable>(from data: Data, response: URLResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(customDateDecodingStrategy)

        if let pagedType = T.self as? PagedObjectProtocol.Type {
            let decodedItems = try decoder.decode(pagedType.objectType, from: data)
            var currentPage = 0
            var pageCount = 0
            if let r = response as? HTTPURLResponse {
                currentPage = Int(r.value(forHTTPHeaderField: configuration.paginationPageHeader) ?? "0") ?? 0
                pageCount = Int(r.value(forHTTPHeaderField: configuration.paginationPageCountHeader) ?? "0") ?? 0
            }
            return pagedType.createPagedObject(with: decodedItems, currentPage: currentPage, pageCount: pageCount) as! T
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Errors

public enum APIManagerError: Error {
    case malformedURL
    case userNotAuthorized
    case couldNotParseData
}
