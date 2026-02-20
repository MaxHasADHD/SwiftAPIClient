//
//  APIError.swift
//  SwiftAPIClient
//

import Foundation

public enum APIError: LocalizedError, Equatable {
    /// 204. Some methods will succeed but not return any content.
    case noContent

    /// Bad Request (400) - request couldn't be parsed
    case badRequest
    /// OAuth must be provided (401)
    case unauthorized
    /// Forbidden - invalid API key or unapproved app (403)
    case forbidden
    /// Not Found - method exists, but no record found (404)
    case noRecordFound
    /// Method Not Found - method doesn't exist (405)
    case noMethodFound
    /// Conflict - resource already created (409)
    case resourceAlreadyCreated
    /// Precondition Failed - use application/json content type (412)
    case preconditionFailed
    /// Account Limit Exceeded - list count, item count, etc (420)
    case accountLimitExceeded
    /// Unprocessable Entity - validation errors (422)
    case unprocessableEntity
    /// Locked User Account - have the user contact support (423)
    case accountLocked
    /// VIP Only - user must upgrade to VIP (426)
    case vipOnly
    /// Rate Limit Exceeded (429) with retry-after header
    case retry(after: TimeInterval)
    /// Rate Limit Exceeded, retry interval not available (429)
    case rateLimitExceeded(HTTPURLResponse)
    /// Server Error - please open a support ticket (500)
    case serverError
    /// Service Unavailable - server overloaded (try again in 30s) (502 / 503 / 504)
    case serverOverloaded
    /// Service Unavailable - Cloudflare error (520 / 521 / 522)
    case cloudflareError
    /// Full url response
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
        case .noRecordFound:
            "No record found."
        case .noMethodFound:
            "Method not found."
        case .resourceAlreadyCreated:
            "Resource has already been created."
        case .preconditionFailed:
            "Invalid content type."
        case .accountLimitExceeded:
            "Account limit exceeded."
        case .unprocessableEntity:
            "Invalid entity."
        case .accountLocked:
            "This account is locked. Please contact support."
        case .vipOnly:
            "This feature is VIP only."
        case .retry:
            nil
        case .rateLimitExceeded:
            "Rate limit exceeded. Please try again in a minute."
        case .serverError, .serverOverloaded, .cloudflareError:
            "Server is down. Please try again later."
        case .unhandled(let urlResponse):
            if let httpResponse = urlResponse as? HTTPURLResponse {
                "Unhandled response. Status code \(httpResponse.statusCode)"
            } else {
                "Unhandled response. \(urlResponse.description)"
            }
        }
    }
}
