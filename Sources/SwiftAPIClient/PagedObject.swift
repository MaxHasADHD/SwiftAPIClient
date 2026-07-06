//
//  PagedObject.swift
//  SwiftAPIClient
//

import Foundation

// MARK: - Pagination

public protocol PagedObjectProtocol {
    static var objectType: Decodable.Type { get }
    static func createPagedObject(with object: Decodable, pagination: PaginationInfo) -> Self
}

/// Configures which response headers SwiftAPIClient reads to extract pagination
/// metadata. Defaults match Trakt's conventions; APIs using different names can
/// pass a custom `PaginationHeaders` to `APIClient.Configuration`.
///
/// Note: this only covers header-name customization. APIs with fundamentally
/// different pagination models (Link-header navigation, cursor-based) need
/// dedicated parsing rather than just different header names.
public struct PaginationHeaders: Sendable, Hashable {
    /// Header reporting the current page number.
    public var page: String
    /// Header reporting total number of pages.
    public var pageCount: String
    /// Header reporting items actually served per page (may differ from the
    /// `.limit(_:)` the client requested if the server downgrades).
    public var limit: String
    /// Header reporting the total number of items across all pages.
    public var itemCount: String

    public init(
        page: String = "x-pagination-page",
        pageCount: String = "x-pagination-page-count",
        limit: String = "x-pagination-limit",
        itemCount: String = "x-pagination-item-count"
    ) {
        self.page = page
        self.pageCount = pageCount
        self.limit = limit
        self.itemCount = itemCount
    }

    public static let `default` = PaginationHeaders()
}

/// Metadata extracted from a paged response's pagination headers.
///
/// `limit` and `itemCount` were added when servers (notably Trakt) started
/// downgrading the requested page size — the requested limit can no longer be
/// trusted as the effective served size, so the actual size and total count
/// must be reported back so callers can compute the real page count.
public struct PaginationInfo: Sendable, Hashable {
    public let currentPage: Int
    public let pageCount: Int
    /// Items actually served per page (from the response header), if the server provided it.
    /// May be smaller than the requested `.limit(_:)` for "heavy" response modes.
    public let limit: Int?
    /// Total number of items across all pages, if the server provided it.
    /// Use this with `limit` to compute the true page count when the server
    /// downgrades the requested page size.
    public let itemCount: Int?

    public init(currentPage: Int, pageCount: Int, limit: Int? = nil, itemCount: Int? = nil) {
        self.currentPage = currentPage
        self.pageCount = pageCount
        self.limit = limit
        self.itemCount = itemCount
    }
}

/// The outcome of `Route.fetchAllPages`: every item that was fetched, plus
/// which pages (if any) could not be.
///
/// A partial result only exists once at least one page has succeeded — if the
/// first page fails, `fetchAllPages` throws instead. Check `isComplete` (or
/// `failedPages`) before treating `items` as the full data set.
public struct PagedFetchResult<Element: Hashable & Sendable>: Sendable {
    /// A page that could not be fetched, and why.
    public struct PageFailure: Sendable {
        public let page: Int
        public let error: any Error

        public init(page: Int, error: any Error) {
            self.page = page
            self.error = error
        }
    }

    /// All items from the pages that succeeded.
    public let items: Set<Element>
    /// Pages that failed after exhausting their retries, in page order.
    /// Empty when the fetch is complete.
    public let failedPages: [PageFailure]
    /// The total number of pages the fetch attempted, as reported by the server.
    public let totalPages: Int

    /// True when every page was fetched successfully.
    public var isComplete: Bool { failedPages.isEmpty }

    public init(items: Set<Element>, failedPages: [PageFailure], totalPages: Int) {
        self.items = items
        self.failedPages = failedPages
        self.totalPages = totalPages
    }
}

public struct PagedObject<APIModel: Codable & Hashable & Sendable>: PagedObjectProtocol, Codable, Hashable, Sendable {
    public let object: APIModel
    public let currentPage: Int
    public let pageCount: Int
    /// Items served per page in this response, if the server reported it.
    public let limit: Int?
    /// Total items across all pages, if the server reported it.
    public let itemCount: Int?

    public init(object: APIModel, currentPage: Int, pageCount: Int, limit: Int? = nil, itemCount: Int? = nil) {
        self.object = object
        self.currentPage = currentPage
        self.pageCount = pageCount
        self.limit = limit
        self.itemCount = itemCount
    }

    public static var objectType: any Decodable.Type {
        APIModel.self
    }

    public static func createPagedObject(with object: Decodable, pagination: PaginationInfo) -> Self {
        PagedObject(
            object: object as! APIModel,
            currentPage: pagination.currentPage,
            pageCount: pagination.pageCount,
            limit: pagination.limit,
            itemCount: pagination.itemCount
        )
    }
}
