//
//  ResponseHandler.swift
//  SwiftAPIClient
//

import Foundation

/// A protocol for customizing HTTP response error handling.
/// Implement this protocol to provide API-specific error handling by throwing
/// your own error types while maintaining standard HTTP error handling as a fallback.
public protocol ResponseHandler: Sendable {
    /// Validates an HTTP response and throws an appropriate error if the response indicates an error.
    ///
    /// - Parameter response: The URLResponse to validate
    /// - Throws: Any error type - can be APIError for standard HTTP errors, or custom error types for API-specific errors
    ///
    /// Implementations should:
    /// 1. Check for API-specific status codes first and throw your custom error types
    /// 2. Fall back to standard HTTP error handling (use `throwStandardError`) for unhandled codes
    /// 3. Preserve the retry functionality - throw `APIError.retry(after:)` for 429 responses with retry-after headers
    ///
    /// Example:
    /// ```swift
    /// func handleResponse(_ response: URLResponse?) throws {
    ///     guard let httpResponse = response as? HTTPURLResponse else { return }
    ///     switch httpResponse.statusCode {
    ///     case 420: throw MyAPIError.accountLimitExceeded
    ///     case 426: throw MyAPIError.vipOnly
    ///     default: try throwStandardError(for: httpResponse)
    ///     }
    /// }
    /// ```
    func handleResponse(_ response: URLResponse?) throws
}

/// The default response handler that implements standard HTTP status code handling.
/// This provides sensible defaults for common HTTP errors and can be used as-is or
/// as a reference for custom implementations.
public struct DefaultResponseHandler: ResponseHandler {
    public init() {}
    
    public func handleResponse(_ response: URLResponse?) throws {
        guard let response else { return }
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.unhandled(response) }
        
        // Success range
        guard 200...299 ~= httpResponse.statusCode else {
            try throwError(for: httpResponse)
            return
        }
    }
    
    private func throwError(for httpResponse: HTTPURLResponse) throws {
        switch httpResponse.statusCode {
        // Client errors
        case 400: throw APIError.badRequest
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 405: throw APIError.methodNotAllowed
        case 409: throw APIError.conflict
        case 412: throw APIError.preconditionFailed
        case 422: throw APIError.unprocessableEntity
        case 429:
            // Handle retry-after header
            let rawRetryAfter = httpResponse.allHeaderFields["retry-after"]
            if let retryAfterString = rawRetryAfter as? String,
               let retryAfter = TimeInterval(retryAfterString) {
                throw APIError.retry(after: retryAfter)
            } else if let retryAfter = rawRetryAfter as? TimeInterval {
                throw APIError.retry(after: retryAfter)
            } else {
                throw APIError.rateLimitExceeded(httpResponse)
            }
            
        // Server errors
        case 500: throw APIError.serverError
        case 502, 503, 504: throw APIError.serviceUnavailable
        case 501...599: throw APIError.serverError
            
        default:
            throw APIError.unhandled(httpResponse)
        }
    }
}

// MARK: - Convenience Extensions

extension ResponseHandler {
    /// Helper method to throw standard errors for a given status code.
    /// Useful for custom handlers that want to add API-specific codes
    /// but delegate standard codes to the default implementation.
    ///
    /// Example:
    /// ```swift
    /// func handleResponse(_ response: URLResponse?) throws {
    ///     guard let httpResponse = response as? HTTPURLResponse else { return }
    ///     switch httpResponse.statusCode {
    ///     case 420: throw MyAPIError.accountLimitExceeded
    ///     default: try throwStandardError(for: httpResponse)
    ///     }
    /// }
    /// ```
    public func throwStandardError(for httpResponse: HTTPURLResponse) throws {
        try DefaultResponseHandler().handleResponse(httpResponse)
    }
}
