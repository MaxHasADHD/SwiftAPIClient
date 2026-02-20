//
//  Method.swift
//  SwiftAPIClient
//

import Foundation

public enum Method: String, Sendable {
    /// Select one or more items. Success returns 200 status code.
    case GET
    /// Create a new item. Success returns 201 status code.
    case POST
    /// Update an item. Success returns 200 status code.
    case PUT
    /// Delete an item. Success returns 200 or 204 status code.
    case DELETE

    public var expectedResult: Int {
        switch self {
        case .GET:
            200
        case .POST:
            201
        case .PUT:
            200
        case .DELETE:
            204
        }
    }
}
