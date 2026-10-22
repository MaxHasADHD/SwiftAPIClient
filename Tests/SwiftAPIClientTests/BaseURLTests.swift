//
//  BaseURLTests.swift
//  SwiftAPIClient
//

import Foundation
import Testing
@testable import SwiftAPIClient

/// Some APIs serve part of their endpoints from another host, such as sign-in from an auth server.
@Suite("Per-request base URL")
struct BaseURLTests {

    private let authURL = URL(string: "https://auth.example.com")!

    private func makeClient(_ session: MockSession) -> APIClient {
        APIClient(
            configuration: APIClient.Configuration(
                baseURL: URL(string: "https://api.example.com")!,
                additionalHeaders: ["api-key": "abc"]
            ),
            session: session.urlSession
        )
    }

    @Test("A request with its own base URL goes there, with the client's headers")
    func requestOnAnotherHost() async throws {
        let client = makeClient(MockSession())

        let request = try await client.mutableRequest(
            forPath: "oauth/token",
            baseURL: authURL,
            withQuery: ["grant": "code"],
            isAuthorized: false,
            withHTTPMethod: .POST
        )

        #expect(request.url?.absoluteString == "https://auth.example.com/oauth/token?grant=code")
        #expect(request.value(forHTTPHeaderField: "api-key") == "abc")
    }

    @Test("A base URL with a path and port keeps both")
    func baseURLWithPathAndPort() async throws {
        let client = makeClient(MockSession())

        let request = try await client.mutableRequest(
            forPath: "oauth/token",
            baseURL: URL(string: "http://127.0.0.1:8080/auth/")!,
            isAuthorized: false,
            withHTTPMethod: .POST
        )

        #expect(request.url?.absoluteString == "http://127.0.0.1:8080/auth/oauth/token")
    }

    @Test("A Route with its own base URL performs there")
    func route() async throws {
        let session = MockSession()
        await session.add(mock: try RequestMocking.MockedResponse(
            urlString: "https://auth.example.com/users/123",
            result: .success(try JSONEncoder().encode(TestUser(id: "123", name: "Test User"))),
            httpCode: 200
        ))

        let route = Route<TestUser>(path: "users/123", method: .GET, baseURL: authURL, apiClient: makeClient(session))

        #expect(try await route.perform().id == "123")
    }

    @Test("An EmptyRoute with its own base URL performs there")
    func emptyRoute() async throws {
        let session = MockSession()
        await session.add(mock: try RequestMocking.MockedResponse(
            urlString: "https://auth.example.com/oauth/revoke",
            result: .success(Data()),
            httpCode: 200
        ))

        let route = EmptyRoute(paths: ["oauth", "revoke"], method: .POST, baseURL: authURL, apiClient: makeClient(session))

        try await route.perform()
    }

    @Test("Without one, requests use the client's base URL")
    func defaultBaseURL() async throws {
        let client = makeClient(MockSession())

        let request = try await client.mutableRequest(forPath: "users", isAuthorized: false, withHTTPMethod: .GET)

        #expect(request.url?.absoluteString == "https://api.example.com/users")
    }
}
