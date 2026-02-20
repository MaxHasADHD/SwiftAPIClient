//
//  Route.swift
//  SwiftAPIClient
//

import Foundation

public struct Route<T: Codable & Hashable & Sendable>: Sendable {

    // MARK: - Properties

    private let resultType: T.Type
    private let apiManager: APIManager

    public var path: String
    public let method: Method
    public let requiresAuthentication: Bool
    public var queryItems: [String: String]

    public var page: Int?
    public var limit: Int?

    public var body: (any Encodable & Hashable & Sendable)?

    // MARK: - Lifecycle

    public init(
        path: String,
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        resultType: T.Type = T.self,
        apiManager: APIManager
    ) {
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.resultType = resultType
        self.apiManager = apiManager
    }

    public init(
        paths: [CustomStringConvertible?],
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        resultType: T.Type = T.self,
        apiManager: APIManager
    ) {
        self.path = paths.compactMap { $0?.description }.joined(separator: "/")
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.resultType = resultType
        self.apiManager = apiManager
    }

    // MARK: - Pagination

    public func page(_ page: Int?) -> Self {
        var copy = self
        copy.page = page
        return copy
    }

    public func limit(_ limit: Int?) -> Self {
        var copy = self
        copy.limit = limit
        return copy
    }

    // MARK: - Perform

    public func perform(retryLimit: Int = 3) async throws -> T {
        let request = try createRequest()
        return try await apiManager.perform(request: request, retryLimit: retryLimit)
    }

    private func createRequest() throws -> URLRequest {
        var query: [String: String] = queryItems

        // pagination
        if let page {
            query["page"] = page.description
        }

        if let limit {
            query["limit"] = limit.description
        }

        return try apiManager.mutableRequest(
            forPath: path,
            withQuery: query,
            isAuthorized: requiresAuthentication,
            withHTTPMethod: method,
            body: body
        )
    }
}

// A simple AsyncSemaphore implementation
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    init(value: Int) {
        self.value = value
    }

    func acquire() async throws {
        if value > 0 {
            value -= 1
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}

extension Route where T: PagedObjectProtocol {

    /// Fetches all pages for a paginated endpoint, and returns the data in a Set.
    public func fetchAllPages<Element>(maxConcurrentRequests preferredMaxConcurrentRequests: Int = 10) async throws -> Set<Element> where T.Type == PagedObject<[Element]>.Type {
        // Fetch first page
        let firstPage = try await self.page(1).perform()
        var resultSet = Set<Element>(firstPage.object)

        // Return early if there's only one page
        guard firstPage.pageCount > 1 else { return resultSet }
        resultSet = await withTaskGroup(of: [Element].self, returning: Set<Element>.self) { group in
            let maxConcurrentRequests = min(firstPage.pageCount - 1, preferredMaxConcurrentRequests)
            let pages = 2...firstPage.pageCount

            let indexStream = AsyncStream<Int> { continuation in
                for i in pages {
                    continuation.yield(i)
                }
                continuation.finish()
            }
            var indexIterator = indexStream.makeAsyncIterator()
            var results = resultSet

            // Start with the initial batch of tasks
            for _ in 0..<maxConcurrentRequests {
                if let index = await indexIterator.next() {
                    group.addTask {
                        (try? await self.page(index).perform())?.object ?? []
                    }
                }
            }

            // Continue adding new tasks as others finish
            while let result = await group.next() {
                results.formUnion(result)  // Merge the `[Int]` result into `Set<Int>
                if let index = await indexIterator.next() {
                    group.addTask {
                        (try? await self.page(index).perform())?.object ?? []
                    }
                }
            }

            return results
        }

        return resultSet
    }

    /// Stream paged results one at a time
    public func pagedResults<Element>(maxConcurrentRequests preferredMaxConcurrentRequests: Int = 10) -> AsyncThrowingStream<[Element], Error> where T.Type == PagedObject<[Element]>.Type {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Fetch first page
                    let firstPage = try await self.page(1).perform()
                    continuation.yield(firstPage.object)

                    guard firstPage.pageCount > 1 else {
                        continuation.finish()
                        return
                    }

                    // Use a semaphore to limit concurrency
                    let semaphore = AsyncSemaphore(value: preferredMaxConcurrentRequests)
                    let pages = 2...firstPage.pageCount

                    try await withThrowingTaskGroup(of: (Int, [Element]).self) { group in
                        for pageIndex in pages {
                            // Acquire permit before starting new task
                            try await semaphore.acquire()

                            group.addTask {
                                do {
                                    let pageResult = try await self.page(pageIndex).perform().object
                                    await semaphore.release()
                                    return (pageIndex, pageResult)
                                } catch {
                                    await semaphore.release()
                                    throw error
                                }
                            }
                        }

                        // Process results in order
                        var nextPage = 2
                        var buffer = [Int: [Element]]()

                        while let result = try await group.next() {
                            let (pageIndex, items) = result

                            if pageIndex == nextPage {
                                // We got the next page we need
                                continuation.yield(items)
                                nextPage += 1

                                // Check if we have any buffered pages that can be yielded now
                                while let bufferedItems = buffer[nextPage] {
                                    continuation.yield(bufferedItems)
                                    buffer[nextPage] = nil
                                    nextPage += 1
                                }
                            } else {
                                // Buffer out-of-order results
                                buffer[pageIndex] = items
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
