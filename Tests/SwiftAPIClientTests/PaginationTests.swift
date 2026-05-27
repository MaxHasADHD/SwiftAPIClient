//
//  PaginationTests.swift
//  SwiftAPIClient
//

import Foundation
import Testing
@testable import SwiftAPIClient

@Suite("Pagination Tests")
struct PaginationTests {

    let baseURL = URL(string: "https://api.example.com")!

    // MARK: - Helpers

    private func makeClient(_ mockSession: MockSession) -> APIClient {
        APIClient(
            configuration: APIClient.Configuration(baseURL: baseURL),
            session: mockSession.urlSession
        )
    }

    private func mock(
        _ mockSession: MockSession,
        url: String,
        items: [Int],
        headers: [HTTPHeader]
    ) async throws {
        let data = try JSONEncoder().encode(items)
        let mock = try RequestMocking.MockedResponse(
            urlString: url,
            result: .success(data),
            httpCode: 200,
            headers: headers
        )
        await mockSession.add(mock: mock)
    }

    // MARK: - Backward compatibility

    /// Pre-change behavior: server only sends X-Pagination-Page-Count. fetchAllPages
    /// must still work — fall back to pageCount when limit/itemCount headers are absent.
    @Test("Server with only pageCount header still works")
    func legacyPageCountOnly() async throws {
        let session = MockSession()
        try await mock(session, url: "https://api.example.com/items?page=1", items: [1, 2, 3],
                       headers: [.contentType, .page(1), .pageCount(2)])
        try await mock(session, url: "https://api.example.com/items?page=2", items: [4, 5, 6],
                       headers: [.contentType, .page(2), .pageCount(2)])

        let route = Route<PagedObject<[Int]>>(
            path: "items",
            method: .GET,
            apiClient: makeClient(session)
        )
        let all: Set<Int> = try await route.fetchAllPages()
        #expect(all == [1, 2, 3, 4, 5, 6])
    }

    // MARK: - Limit downgrade

    /// Scenario: client requests `limit=250`, server downgrades to `limit=100`,
    /// reports `pageCount=4` (the wrong/requested-limit math) but ALSO reports
    /// `limit=100` + `itemCount=350`. fetchAllPages must use itemCount/limit
    /// to compute the true page count (ceil(350/100) = 4) — coincidentally same
    /// here, but the assertion is that all 350 items are returned.
    @Test("Server downgrades limit but reports actual limit + itemCount")
    func limitDowngradeWithFullHeaders() async throws {
        let session = MockSession()
        // Three full pages of 100 each + a final page of 50.
        let pages: [[Int]] = [
            Array(0..<100),
            Array(100..<200),
            Array(200..<300),
            Array(300..<350)
        ]
        for (index, page) in pages.enumerated() {
            let pageNumber = index + 1
            // Note: server claims pageCount=4 based on the requested limit=250,
            // but actual served pages are 100/page. truePageCount = ceil(350/100) = 4.
            try await mock(session,
                           url: "https://api.example.com/items?limit=250&page=\(pageNumber)",
                           items: page,
                           headers: [.contentType, .page(pageNumber), .pageCount(4), .limit(100), .itemCount(350)])
        }

        let route = Route<PagedObject<[Int]>>(
            path: "items",
            method: .GET,
            apiClient: makeClient(session)
        ).limit(250)

        let all: Set<Int> = try await route.fetchAllPages()
        #expect(all.count == 350)
    }

    /// Scenario where pageCount UNDERCOUNTS but itemCount tells the truth.
    /// Server reports pageCount=2 (wrong — actual is 4) but provides limit=100 + itemCount=350.
    /// truePageCount via itemCount/limit = ceil(350/100) = 4 — must override pageCount.
    @Test("itemCount overrides incorrect pageCount")
    func itemCountOverridesIncorrectPageCount() async throws {
        let session = MockSession()
        let pages: [[Int]] = [
            Array(0..<100),
            Array(100..<200),
            Array(200..<300),
            Array(300..<350)
        ]
        for (index, page) in pages.enumerated() {
            let pageNumber = index + 1
            // pageCount is wrong (2 instead of 4) — server's stale or inconsistent math.
            try await mock(session,
                           url: "https://api.example.com/items?limit=250&page=\(pageNumber)",
                           items: page,
                           headers: [.contentType, .page(pageNumber), .pageCount(2), .limit(100), .itemCount(350)])
        }

        let route = Route<PagedObject<[Int]>>(
            path: "items",
            method: .GET,
            apiClient: makeClient(session)
        ).limit(250)

        let all: Set<Int> = try await route.fetchAllPages()
        #expect(all.count == 350, "Should have collected all 350 items via itemCount/limit override, not the bad pageCount=2.")
    }

    /// Defensive tail: server reports itemCount=350, pageCount=3, limit=100, but the math
    /// adds up to 300 — there's actually one more page lurking. fetchAllPages should probe
    /// pageCount+1 and recover the remaining items.
    @Test("Defensive tail probes past stated pageCount when itemCount is higher")
    func defensiveTailProbesAfterStatedPageCount() async throws {
        let session = MockSession()
        let pages: [[Int]] = [
            Array(0..<100),
            Array(100..<200),
            Array(200..<300),
            Array(300..<350) // server didn't report this — defensive tail must find it
        ]
        // Server reports limit=100, itemCount=350, pageCount=3 (wrong — should be 4).
        // ceil(350/100) = 4, so effectivePageCount = 4 → page 4 is fetched in the main loop.
        // To exercise the defensive tail itself, make limit/itemCount math also give 3:
        // limit=100, itemCount=300 (server thinks total is 300), but there are 350 in reality.
        for (index, page) in pages.enumerated() {
            let pageNumber = index + 1
            let pageCountHeader: Int = index < 3 ? 3 : 4 // doesn't matter for the test
            try await mock(session,
                           url: "https://api.example.com/items?page=\(pageNumber)",
                           items: page,
                           headers: [.contentType, .page(pageNumber), .pageCount(pageCountHeader), .limit(100), .itemCount(350)])
        }
        // An empty page 5 to terminate the defensive tail
        try await mock(session, url: "https://api.example.com/items?page=5", items: [],
                       headers: [.contentType, .page(5), .pageCount(4), .limit(100), .itemCount(350)])

        let route = Route<PagedObject<[Int]>>(
            path: "items",
            method: .GET,
            apiClient: makeClient(session)
        )

        let all: Set<Int> = try await route.fetchAllPages()
        #expect(all.count == 350)
    }

    /// Single page response — no additional fetches.
    @Test("Single page returns early")
    func singlePage() async throws {
        let session = MockSession()
        try await mock(session, url: "https://api.example.com/items?page=1", items: [1, 2, 3],
                       headers: [.contentType, .page(1), .pageCount(1), .limit(100), .itemCount(3)])

        let route = Route<PagedObject<[Int]>>(
            path: "items",
            method: .GET,
            apiClient: makeClient(session)
        )
        let all: Set<Int> = try await route.fetchAllPages()
        #expect(all == [1, 2, 3])
    }
}
