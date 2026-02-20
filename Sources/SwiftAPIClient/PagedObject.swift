//
//  PagedObject.swift
//  SwiftAPIClient
//

import Foundation

// MARK: - Pagination

public protocol PagedObjectProtocol {
    static var objectType: Decodable.Type { get }
    static func createPagedObject(with object: Decodable, currentPage: Int, pageCount: Int) -> Self
}

public struct PagedObject<APIModel: Codable & Hashable & Sendable>: PagedObjectProtocol, Codable, Hashable, Sendable {
    public let object: APIModel
    public let currentPage: Int
    public let pageCount: Int

    public static var objectType: any Decodable.Type {
        APIModel.self
    }

    public static func createPagedObject(with object: Decodable, currentPage: Int, pageCount: Int) -> Self {
        return PagedObject(object: object as! APIModel, currentPage: currentPage, pageCount: pageCount)
    }
}
