//
//  APIClientTests.swift
//  SwiftAPIClient
//
//  Created by Maximilian Litteral on 2/23/26.
//

import Foundation
import Testing
@testable import SwiftAPIClient

// MARK: - Test Models

struct TestUser: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct TestError: Error, Equatable {
    let message: String
}

// MARK: - Test Response Handler

struct TestResponseHandler: ResponseHandler {
    func handleResponse(_ response: URLResponse?) throws {
        guard let response else { return }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unhandled(response)
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            switch httpResponse.statusCode {
            case 418: // I'm a teapot
                throw TestError(message: "I'm a teapot")
            default:
                try throwStandardError(for: httpResponse)
            }
            return
        }
    }
}

// MARK: - Tests

@Suite("APIClient Request Tests", .serialized)
struct APIClientRequestTests {
    
    let baseURL = URL(string: "https://api.example.com")!
    
    @Test("Successful request with default handler")
    func successfulRequest() async throws {
        // Setup
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let jsonData = try JSONEncoder().encode(testUser)
        
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(jsonData),
            httpCode: 200
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute
        let request = try client.mutableRequest(
            forPath: "users/123",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        let result: TestUser = try await client.perform(request: request)
        
        // Verify
        #expect(result.id == "123")
        #expect(result.name == "Test User")
    }
    
    @Test("Request throws unauthorized error")
    func unauthorizedRequest() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(Data()),
            httpCode: 401
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute & Verify
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        await #expect(throws: APIError.unauthorized) {
            let _: TestUser = try await client.perform(request: request)
        }
    }
    
    @Test("Request throws notFound error")
    func notFoundRequest() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/nonexistent",
            result: .success(Data()),
            httpCode: 404
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute & Verify
        let request = try client.mutableRequest(
            forPath: "users/nonexistent",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        await #expect(throws: APIError.notFound) {
            let _: TestUser = try await client.perform(request: request)
        }
    }
    
    @Test("Request throws serverError for 500")
    func serverErrorRequest() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(Data()),
            httpCode: 500
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute & Verify
        let request = try client.mutableRequest(
            forPath: "users/123",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        await #expect(throws: APIError.serverError) {
            let _: TestUser = try await client.perform(request: request)
        }
    }
}

@Suite("APIClient Custom Handler Tests", .serialized)
struct APIClientCustomHandlerTests {
    
    let baseURL = URL(string: "https://api.example.com")!
    
    @Test("Custom handler throws custom error")
    func customErrorHandling() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/teapot",
            result: .success(Data()),
            httpCode: 418
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            responseHandler: TestResponseHandler()
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute & Verify
        let request = try client.mutableRequest(
            forPath: "teapot",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        do {
            let _: TestUser = try await client.perform(request: request)
            Issue.record("Expected TestError to be thrown")
        } catch let error as TestError {
            #expect(error.message == "I'm a teapot")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
    
    @Test("Custom handler falls back to standard errors")
    func customHandlerFallback() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(Data()),
            httpCode: 401
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            responseHandler: TestResponseHandler()
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        // Execute & Verify - should throw standard APIError
        let request = try client.mutableRequest(
            forPath: "users/123",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        await #expect(throws: APIError.unauthorized) {
            let _: TestUser = try await client.perform(request: request)
        }
    }
}

@Suite("APIClient Retry Tests", .serialized)
struct APIClientRetryTests {
    
    let baseURL = URL(string: "https://api.example.com")!
    
    @Test("Automatically retries on 429 with retry-after header")
    func automaticRetry() async throws {
        // Setup
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let jsonData = try JSONEncoder().encode(testUser)
        
        // First request returns 429 with retry-after
        let rateLimitMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(Data()),
            httpCode: 429,
            headers: [.retry(1)] // 1 second retry
        )
        await mockSession.add(mock: rateLimitMock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        let request = try client.mutableRequest(
            forPath: "users/123",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        // Start the request
        let task = Task {
            try await client.perform(request: request, retryLimit: 2) as TestUser
        }
        
        // After a short delay, replace the mock with a successful response
        try await Task.sleep(for: .seconds(0.5))
        let successMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(jsonData),
            httpCode: 200
        )
        await mockSession.replace(mock: successMock)
        
        // Wait for result
        let result = try await task.value
        
        // Verify
        #expect(result.id == "123")
        #expect(result.name == "Test User")
    }
    
    @Test("Throws error after retry limit exceeded")
    func retryLimitExceeded() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/123",
            result: .success(Data()),
            httpCode: 429,
            headers: [.retry(0.1)] // Very short retry
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        let request = try client.mutableRequest(
            forPath: "users/123",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        // Should throw after exceeding retry limit
        do {
            let _: TestUser = try await client.perform(request: request, retryLimit: 2)
            Issue.record("Expected retry error to be thrown")
        } catch let error as APIError {
            guard case .retry = error else {
                Issue.record("Expected .retry error, got \(error)")
                return
            }
        }
    }
    
    @Test("Custom errors are not retried")
    func customErrorsNotRetried() async throws {
        // Setup
        let mockSession = MockSession()
        let mock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/teapot",
            result: .success(Data()),
            httpCode: 418
        )
        await mockSession.add(mock: mock)
        
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            responseHandler: TestResponseHandler()
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: nil
        )
        
        let request = try client.mutableRequest(
            forPath: "teapot",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        // Custom errors should be thrown immediately without retry
        do {
            let _: TestUser = try await client.perform(request: request, retryLimit: 3)
            Issue.record("Expected TestError to be thrown")
        } catch let error as TestError {
            #expect(error.message == "I'm a teapot")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

@Suite("APIClient Configuration Tests")
struct APIClientConfigurationTests {
    
    @Test("Uses custom base URL")
    func customBaseURL() throws {
        let baseURL = URL(string: "https://custom.api.com/v2")!
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authStorage: nil)
        
        let request = try client.mutableRequest(
            forPath: "users",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        #expect(request.url?.absoluteString == "https://custom.api.com/v2/users")
    }
    
    @Test("Adds additional headers")
    func additionalHeaders() throws {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            additionalHeaders: [
                "X-API-Version": "2",
                "X-Client-ID": "test-client"
            ]
        )
        let client = APIClient(configuration: configuration, authStorage: nil)
        
        let request = try client.mutableRequest(
            forPath: "users",
            isAuthorized: false,
            withHTTPMethod: .GET
        )
        
        #expect(request.value(forHTTPHeaderField: "X-API-Version") == "2")
        #expect(request.value(forHTTPHeaderField: "X-Client-ID") == "test-client")
    }
    
    @Test("Uses custom response handler")
    func customResponseHandler() {
        let baseURL = URL(string: "https://api.example.com")!
        let customHandler = TestResponseHandler()
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            responseHandler: customHandler
        )
        
        // Verify the configuration was accepted
        #expect(configuration.baseURL == baseURL)
    }
}
