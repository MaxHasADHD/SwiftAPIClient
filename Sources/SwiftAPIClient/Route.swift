//
//  Route.swift
//  SwiftAPIClient
//

import Foundation

public struct Route<T: Codable & Hashable & Sendable>: Sendable {

    // MARK: - Properties

    private let resultType: T.Type
    private let apiClient: APIClient

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
        apiClient: APIClient
    ) {
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.resultType = resultType
        self.apiClient = apiClient
    }

    public init(
        paths: [CustomStringConvertible?],
        queryItems: [String: String] = [:],
        body: (any Encodable & Hashable & Sendable)? = nil,
        method: Method,
        requiresAuthentication: Bool = false,
        resultType: T.Type = T.self,
        apiClient: APIClient
    ) {
        self.path = paths.compactMap { $0?.description }.joined(separator: "/")
        self.queryItems = queryItems
        self.body = body
        self.method = method
        self.requiresAuthentication = requiresAuthentication
        self.resultType = resultType
        self.apiClient = apiClient
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
        let request = try await createRequest()
        return try await apiClient.perform(request: request, retryLimit: retryLimit)
    }

    private func createRequest() async throws -> URLRequest {
        var query: [String: String] = queryItems

        // pagination
        if let page {
            query["page"] = page.description
        }

        if let limit {
            query["limit"] = limit.description
        }

        return try await apiClient.mutableRequest(
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

    /// Computes the true total page count from a paged response.
    ///
    /// Some servers (notably Trakt as of May 2026) may downgrade the requested
    /// page size for "heavy" response modes. When that happens, `pageCount` —
    /// which may be calculated against the *requested* limit — is unreliable.
    /// If the server also reports the actual served `limit` and total `itemCount`,
    /// derive page count from those instead.
    ///
    /// Falls back to `pageCount` if the additional headers aren't available,
    /// preserving behavior for servers that haven't adopted them.
    private static func effectivePageCount<Element>(from firstPage: PagedObject<[Element]>) -> Int {
        if let itemCount = firstPage.itemCount, let limit = firstPage.limit, limit > 0 {
            return (itemCount + limit - 1) / limit
        }
        return firstPage.pageCount
    }

    /// Fetches all pages for a paginated endpoint.
    ///
    /// Failure semantics:
    /// - If the **first page** fails, nothing was fetched — the error is thrown
    ///   and the whole request is considered failed.
    /// - If a **later page** fails, the remaining pages are still fetched and
    ///   the failure is reported in `PagedFetchResult.failedPages` alongside
    ///   the partial `items`, so callers can tell 15-of-20 pages apart from a
    ///   complete result (check `isComplete`).
    ///
    /// `retryLimit` is forwarded to every page request. Pass `0` to fail fast
    /// instead of honoring `retry-after` waits — useful against APIs with long
    /// rate-limit cooldowns (e.g. Trakt's 5 minutes) where waiting inline is
    /// worse than surfacing the failure.
    ///
    /// Uses `itemCount` / `limit` from response headers when available to compute
    /// the true page count (defends against servers downgrading the requested
    /// page size). Falls back to `pageCount` when those headers aren't present.
    public func fetchAllPages<Element>(
        maxConcurrentRequests preferredMaxConcurrentRequests: Int = 5,
        retryLimit: Int = 3
    ) async throws -> PagedFetchResult<Element> where T.Type == PagedObject<[Element]>.Type {
        // Fetch first page. A failure here propagates: with zero pages fetched
        // there is no partial result worth returning.
        let firstPage = try await self.page(1).perform(retryLimit: retryLimit)
        var resultSet = Set<Element>(firstPage.object)

        let totalPages = Self.effectivePageCount(from: firstPage)

        // Return early if there's only one page
        guard totalPages > 1 else {
            return PagedFetchResult(items: resultSet, failedPages: [], totalPages: max(totalPages, 1))
        }

        var failedPages: [PagedFetchResult<Element>.PageFailure] = []

        (resultSet, failedPages) = await withTaskGroup(
            of: (page: Int, outcome: Result<[Element], any Error>).self,
            returning: (Set<Element>, [PagedFetchResult<Element>.PageFailure]).self
        ) { group in
            let maxConcurrentRequests = min(totalPages - 1, preferredMaxConcurrentRequests)
            let pages = 2...totalPages

            let indexStream = AsyncStream<Int> { continuation in
                for i in pages {
                    continuation.yield(i)
                }
                continuation.finish()
            }
            var indexIterator = indexStream.makeAsyncIterator()
            var results = resultSet
            var failures: [PagedFetchResult<Element>.PageFailure] = []

            func addFetchTask(forPage index: Int) {
                group.addTask {
                    do {
                        return (index, .success(try await self.page(index).perform(retryLimit: retryLimit).object))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            // Start with the initial batch of tasks
            for _ in 0..<maxConcurrentRequests {
                if let index = await indexIterator.next() {
                    addFetchTask(forPage: index)
                }
            }

            // Continue adding new tasks as others finish
            while let (page, outcome) = await group.next() {
                switch outcome {
                case .success(let items):
                    results.formUnion(items)
                case .failure(let error):
                    failures.append(.init(page: page, error: error))
                }
                if let index = await indexIterator.next() {
                    addFetchTask(forPage: index)
                }
            }

            return (results, failures)
        }

        failedPages.sort { $0.page < $1.page }

        // Defensive tail: if the server reported a higher itemCount than we
        // collected (e.g. headers and reality diverge), sequentially probe
        // additional pages until we hit one that's empty or no new items appear.
        // Caps at 10 extra pages so we never loop forever on a misbehaving server.
        // Only runs on a fully successful fetch — with failed pages, the count
        // shortfall is already explained and probing would just add noise.
        if failedPages.isEmpty, let itemCount = firstPage.itemCount, resultSet.count < itemCount {
            var probePage = totalPages + 1
            let maxProbePages = 10
            for _ in 0..<maxProbePages {
                guard let next = try? await self.page(probePage).perform(retryLimit: retryLimit) else { break }
                if next.object.isEmpty { break }
                let before = resultSet.count
                resultSet.formUnion(next.object)
                if resultSet.count == before { break } // duplicates only — no progress
                if resultSet.count >= itemCount { break }
                probePage += 1
            }
        }

        return PagedFetchResult(items: resultSet, failedPages: failedPages, totalPages: totalPages)
    }

    /// Stream paged results one at a time.
    ///
    /// `retryLimit` is forwarded to every page request — pass `0` to fail fast
    /// instead of honoring `retry-after` waits.
    public func pagedResults<Element>(
        maxConcurrentRequests preferredMaxConcurrentRequests: Int = 5,
        retryLimit: Int = 3
    ) -> AsyncThrowingStream<[Element], Error> where T.Type == PagedObject<[Element]>.Type {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Fetch first page
                    let firstPage = try await self.page(1).perform(retryLimit: retryLimit)
                    continuation.yield(firstPage.object)

                    let totalPages = Self.effectivePageCount(from: firstPage)
                    guard totalPages > 1 else {
                        continuation.finish()
                        return
                    }

                    // Use a semaphore to limit concurrency
                    let semaphore = AsyncSemaphore(value: preferredMaxConcurrentRequests)
                    let pages = 2...totalPages

                    try await withThrowingTaskGroup(of: (Int, [Element]).self) { group in
                        for pageIndex in pages {
                            // Acquire permit before starting new task
                            try await semaphore.acquire()

                            group.addTask {
                                do {
                                    let pageResult = try await self.page(pageIndex).perform(retryLimit: retryLimit).object
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
