//
//  APIError.swift
//  SwiftAPIClient
//

import Foundation

/// Core API error type containing standard HTTP errors and retry functionality.
/// API-specific errors can be handled via custom `ResponseHandler` implementations.
public enum APIError: LocalizedError, Equatable {
    /// 204. Some methods will succeed but not return any content.
    case noContent

    // MARK: - 4xx Client Errors
    
    /// Bad Request (400) - request couldn't be parsed
    case badRequest
    /// OAuth must be provided (401)
    case unauthorized
    /// Forbidden - invalid API key or unapproved app (403)
    case forbidden
    /// Not Found - method exists, but no record found (404)
    case notFound
    /// Method Not Found - method doesn't exist (405)
    case methodNotAllowed
    /// Conflict - resource already created (409)
    case conflict
    /// Precondition Failed - use application/json content type (412)
    case preconditionFailed
    /// Unprocessable Entity - validation errors (422)
    case unprocessableEntity
    /// Rate Limit Exceeded (429) with retry-after header
    case retry(after: TimeInterval)
    /// Rate Limit Exceeded, retry interval not available (429)
    case rateLimitExceeded(HTTPURLResponse)
    
    // MARK: - 5xx Server Errors
    
    /// Server Error - please open a support ticket (500)
    case serverError
    /// Service Unavailable - server overloaded (try again in 30s) (502 / 503 / 504)
    case serviceUnavailable
    
    // MARK: - Unhandled
    
    /// Full url response for completely unhandled cases
    case unhandled(URLResponse)

    public var errorDescription: String? {
        switch self {
        case .noContent:
            nil
        case .badRequest:
            "Request could not be parsed."
        case .unauthorized:
            "Unauthorized. Please sign in."
        case .forbidden:
            "Forbidden. Invalid API key or unapproved app."
        case .notFound:
            "No record found."
        case .methodNotAllowed:
            "Method not allowed."
        case .conflict:
            "Resource has already been created."
        case .preconditionFailed:
            "Invalid content type."
        case .unprocessableEntity:
            "Invalid entity."
        case .retry:
            nil
        case .rateLimitExceeded:
            "Rate limit exceeded. Please try again in a minute."
        case .serverError:
            "Server error. Please try again later."
        case .serviceUnavailable:
            "Service unavailable. Please try again later."
        case .unhandled(let urlResponse):
            if let httpResponse = urlResponse as? HTTPURLResponse {
                "Unhandled response. Status code \(httpResponse.statusCode)"
            } else {
                "Unhandled response. \(urlResponse.description)"
            }
        }
    }
    
    /// The HTTP status code associated with this error, if available
    public var statusCode: Int? {
        switch self {
        case .noContent: return 204
        case .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .conflict: return 409
        case .preconditionFailed: return 412
        case .unprocessableEntity: return 422
        case .retry, .rateLimitExceeded: return 429
        case .serverError: return 500
        case .serviceUnavailable: return 503
        case .unhandled(let response):
            return (response as? HTTPURLResponse)?.statusCode
        }
    }
}
