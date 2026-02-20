//
//  RequestMocking.swift
//  SwiftAPIClient
//

import Foundation
import os

extension URLSession {
    public static var mockedResponsesOnly: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [RequestMocking.self, RequestBlocking.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }
}

extension RequestMocking {
    private final class MocksContainer: @unchecked Sendable {
        var mocks: [MockedResponse] = []
    }

    static private let container = MocksContainer()
    static private let lock = NSLock()

    public static func add(mock: MockedResponse) {
        lock.withLock {
            container.mocks.append(mock)
        }
    }

    public static func replace(mock: MockedResponse) {
        lock.withLock {
            container.mocks.removeAll(where: { $0.url == mock.url })
            container.mocks.append(mock)
        }
    }

    public static func removeAllMocks() {
        lock.withLock {
            container.mocks.removeAll()
        }
    }

    static private func mock(for request: URLRequest) -> MockedResponse? {
        return lock.withLock {
            container.mocks.first { mock in
                guard let url = request.url else { return false }
                return mock.url.compareComponents(url)
            }
        }
    }
}

// MARK: - RequestMocking

public final class RequestMocking: URLProtocol, @unchecked Sendable {
    override public class func canInit(with request: URLRequest) -> Bool {
        return mock(for: request) != nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override public class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        return false
    }

    override public func startLoading() {
        guard
            let mock = RequestMocking.mock(for: request),
            let url = request.url,
            let response = mock.customResponse ??
                HTTPURLResponse(url: url, statusCode: mock.httpCode, httpVersion: "HTTP/1.1", headerFields: mock.headers)
        else { return }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        switch mock.result {
        case let .success(data):
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }


    override public func stopLoading() { }
}

// MARK: - RequestBlocking

/// Block all outgoing requests not caught by `RequestMocking` protocol
private class RequestBlocking: URLProtocol, @unchecked Sendable {

    static let logger = Logger(subsystem: "SwiftAPIClient", category: "RequestBlocking")

    enum Error: Swift.Error {
        case requestBlocked
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.logger.warning("Blocking request to \(self.request.url?.absoluteString ?? "Unknown URL.")")
        self.client?.urlProtocol(self, didFailWithError: Error.requestBlocked)
    }

    override func stopLoading() { }
}

// MARK: - MockedResponse

public struct MockedResponse {
    let url: URL
    let httpCode: Int
    let headers: [String: String]
    let result: Result<Data, Error>
    let customResponse: HTTPURLResponse?

    public init(
        url: URL,
        httpCode: Int = 200,
        headers: [String: String] = [:],
        result: Result<Data, Error>,
        customResponse: HTTPURLResponse? = nil
    ) {
        self.url = url
        self.httpCode = httpCode
        self.headers = headers
        self.result = result
        self.customResponse = customResponse
    }
}

extension URL {
    /// Compares components, which doesn't require query parameters to be in any particular order
    public func compareComponents(_ url: URL) -> Bool {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }

        return components.scheme == urlComponents.scheme &&
        components.host == urlComponents.host &&
        components.path == urlComponents.path &&
        components.queryItems?.enumerated().compactMap { $0.element.name }.sorted() == urlComponents.queryItems?.enumerated().compactMap { $0.element.name }.sorted() &&
        components.queryItems?.enumerated().compactMap { $0.element.value }.sorted() == urlComponents.queryItems?.enumerated().compactMap { $0.element.value }.sorted()
    }
}
