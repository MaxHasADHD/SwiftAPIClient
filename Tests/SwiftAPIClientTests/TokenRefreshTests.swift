//
//  TokenRefreshTests.swift
//  SwiftAPIClient
//
//  Created by Claude on 2/25/26.
//

import Foundation
import Testing
@testable import SwiftAPIClient

// MARK: - Test Models

struct TokenResponse: Codable, Hashable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

// MARK: - Mock Authentication Storage

actor MockAuthStorage: APIAuthentication {
    var currentState: AuthenticationState?
    var getStateCallCount = 0
    var updateStateCallCount = 0
    var clearCallCount = 0
    
    func getCurrentState() throws(AuthenticationError) -> AuthenticationState {
        getStateCallCount += 1
        guard let state = currentState else {
            throw .noStoredCredentials
        }
        
        // Check if token is expired
        guard state.expirationDate > .now else {
            throw .tokenExpired(refreshToken: state.refreshToken)
        }
        
        return state
    }
    
    func updateState(_ state: AuthenticationState) {
        updateStateCallCount += 1
        currentState = state
    }
    
    func clear() {
        clearCallCount += 1
        currentState = nil
    }
}

// MARK: - Mock Token Refresh Handler

actor MockTokenRefreshHandler: TokenRefreshHandler {
    var refreshCallCount = 0
    var shouldFail = false
    var newToken: TokenResponse?
    var refreshDelay: TimeInterval = 0
    
    func setNewToken(_ token: TokenResponse) {
        newToken = token
    }
    
    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }
    
    func setRefreshDelay(_ delay: TimeInterval) {
        refreshDelay = delay
    }
    
    func refreshToken(using refreshToken: String, client: APIClient) async throws -> AuthenticationState {
        refreshCallCount += 1
        
        // Simulate network delay if configured
        if refreshDelay > 0 {
            try await Task.sleep(for: .seconds(refreshDelay))
        }
        
        if shouldFail {
            throw APIError.unauthorized
        }
        
        guard let token = newToken else {
            throw APIError.unauthorized
        }
        
        return AuthenticationState(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
    }
}

// MARK: - Tests

@Suite("Token Refresh Tests")
struct TokenRefreshTests {
    
    let baseURL = URL(string: "https://api.example.com")!
    
    @Test("Token refresh handler protocol is defined")
    func tokenRefreshHandlerProtocol() async throws {
        // This test will fail until we define the TokenRefreshHandler protocol
        let mockHandler = MockTokenRefreshHandler()
        
        let newToken = TokenResponse(
            accessToken: "new_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        await mockHandler.setNewToken(newToken)
        
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration)
        
        let oldRefreshToken = "old_refresh_token"
        let newState = try await mockHandler.refreshToken(using: oldRefreshToken, client: client)
        
        #expect(newState.accessToken == "new_access_token")
        #expect(newState.refreshToken == "new_refresh_token")
        #expect(await mockHandler.refreshCallCount == 1)
    }
    
    @Test("APIClient accepts token refresh handler in configuration")
    func clientAcceptsRefreshHandler() async throws {
        // This test will fail until we add tokenRefreshHandler to APIClient.Configuration
        let mockHandler = MockTokenRefreshHandler()
        
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: mockHandler
        )
        
        _ = APIClient(configuration: configuration)
        #expect(configuration.baseURL == baseURL)
    }
    
    @Test("Proactively refreshes token before expiration during request")
    func proactiveTokenRefresh() async throws {
        // Setup mock session
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Setup token refresh mock
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshData = try JSONEncoder().encode(newToken)
        let refreshMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/oauth/token",
            result: .success(refreshData),
            httpCode: 200
        )
        await mockSession.add(mock: refreshMock)
        
        // Setup auth storage with token expiring soon (within 5 minutes)
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Setup token refresh handler
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make an authorized request - should trigger proactive refresh
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        let result: TestUser = try await client.perform(request: request)
        
        // Verify token was refreshed
        #expect(await refreshHandler.refreshCallCount == 1)
        #expect(result.id == "123")
        
        // Verify auth storage was updated with new token
        let updatedState = try await authStorage.getCurrentState()
        #expect(updatedState.accessToken == "refreshed_access_token")
    }
    
    @Test("Automatically attempts token refresh on 401 unauthorized")
    func automaticTokenRefreshOn401() async throws {
        // Setup mock session
        let mockSession = MockSession()
        
        // Setup auth storage with valid token (not expiring soon)
        let authStorage = MockAuthStorage()
        let validState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(3600) // 1 hour from now
        )
        await authStorage.updateState(validState)
        
        // Setup token refresh handler
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Setup mock to always return 401
        let unauthorizedMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(Data()),
            httpCode: 401
        )
        await mockSession.add(mock: unauthorizedMock)
        
        // Make an authorized request
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        // Attempt the request - will get 401, refresh token, then retry and get 401 again
        do {
            let _: TestUser = try await client.perform(request: request)
            Issue.record("Expected 401 error to be thrown")
        } catch APIError.unauthorized {
            // Expected - the retry also got 401
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        
        // Verify token refresh was attempted once
        #expect(await refreshHandler.refreshCallCount == 1)
        
        // Verify auth storage was updated with new token
        let updatedState = try await authStorage.getCurrentState()
        #expect(updatedState.accessToken == "refreshed_access_token")
    }
    
    @Test("Does not refresh token if expiration is far in future")
    func noRefreshWhenTokenValid() async throws {
        // Setup mock session
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Setup auth storage with token valid for 1 hour
        let authStorage = MockAuthStorage()
        let validState = AuthenticationState(
            accessToken: "valid_access_token",
            refreshToken: "valid_refresh_token",
            expirationDate: Date().addingTimeInterval(3600) // 1 hour from now
        )
        await authStorage.updateState(validState)
        
        // Setup token refresh handler
        let refreshHandler = MockTokenRefreshHandler()
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make an authorized request
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        let result: TestUser = try await client.perform(request: request)
        
        // Verify token was NOT refreshed
        #expect(await refreshHandler.refreshCallCount == 0)
        #expect(result.id == "123")
    }
    
    @Test("Throws error if token refresh fails")
    func tokenRefreshFailure() async throws {
        // Setup mock session
        let mockSession = MockSession()
        
        // First request returns 401
        let unauthorizedMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(Data()),
            httpCode: 401
        )
        await mockSession.add(mock: unauthorizedMock)
        
        // Setup auth storage with valid token
        let authStorage = MockAuthStorage()
        let validState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(3600)
        )
        await authStorage.updateState(validState)
        
        // Setup token refresh handler that will fail
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setShouldFail(true)
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make an authorized request - should fail after refresh attempt
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        await #expect(throws: APIError.unauthorized) {
            let _: TestUser = try await client.perform(request: request)
        }
        
        // Verify refresh was attempted
        #expect(await refreshHandler.refreshCallCount == 1)
    }
    
    @Test("Concurrent requests only trigger one token refresh")
    func concurrentTokenRefreshDeduplication() async throws {
        // Setup mock session
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Setup auth storage with token expiring soon
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Setup token refresh handler with a delay to simulate network call
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        await refreshHandler.setRefreshDelay(0.1) // 100ms delay
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make 5 concurrent requests - all should trigger proactive refresh
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        await withTaskGroup(of: TestUser?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await client.perform(request: request) as TestUser
                }
            }
            
            // Wait for all to complete
            var results: [TestUser?] = []
            for await result in group {
                results.append(result)
            }
        }
        
        // Verify token refresh was only called ONCE despite 5 concurrent requests
        #expect(await refreshHandler.refreshCallCount == 1)
        
        // Verify auth storage was updated
        let updatedState = try await authStorage.getCurrentState()
        #expect(updatedState.accessToken == "refreshed_access_token")
    }
    
    @Test("Proactive refresh updates request with new token")
    func proactiveRefreshUpdatesRequestToken() async throws {
        // Setup mock session that validates the Authorization header
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Setup auth storage with token expiring soon
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Setup token refresh handler
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Create request with old token
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        // Verify request has old token
        let oldAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        #expect(oldAuthHeader == "Bearer old_access_token")
        
        // Perform request - should trigger proactive refresh and use new token
        let result: TestUser = try await client.perform(request: request)
        
        // Verify request was successful
        #expect(result.id == "123")
        
        // Verify token was refreshed
        #expect(await refreshHandler.refreshCallCount == 1)
    }
    
    @Test("Concurrent 401 errors only trigger one token refresh")
    func concurrent401OnlyRefreshOnce() async throws {
        // Setup mock session
        let mockSession = MockSession()
        
        // Setup auth storage with valid token
        let authStorage = MockAuthStorage()
        let validState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(3600)
        )
        await authStorage.updateState(validState)
        
        // Setup token refresh handler with delay
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        await refreshHandler.setRefreshDelay(0.1) // 100ms delay
        
        // Create client
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Setup mocks to return 401
        let unauthorizedMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(Data()),
            httpCode: 401
        )
        await mockSession.add(mock: unauthorizedMock)
        
        // Make 3 concurrent requests that will all get 401
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try? await client.perform(request: request) as TestUser
                }
            }
        }
        
        // Wait a moment for all requests to complete
        try await Task.sleep(for: .milliseconds(300))
        
        // Verify token refresh was only called ONCE despite 3 concurrent 401s
        #expect(await refreshHandler.refreshCallCount == 1)
    }
    
    @Test("Stress test: Many concurrent requests only trigger one refresh")
    func stressTestConcurrentRefresh() async throws {
        // Setup mock session
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Setup auth storage with token expiring soon
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Setup token refresh handler with a very small delay to maximize race window
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)
        await refreshHandler.setRefreshDelay(0.05) // 50ms delay - small window to expose race
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make 20 concurrent requests to maximize chances of hitting race condition
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        await withTaskGroup(of: TestUser?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await client.perform(request: request) as TestUser
                }
            }
            
            // Wait for all to complete
            var results: [TestUser?] = []
            for await result in group {
                results.append(result)
            }
        }
        
        // CRITICAL: Verify token refresh was only called ONCE despite 20 concurrent requests
        let count = await refreshHandler.refreshCallCount
        #expect(count == 1, "Expected 1 refresh, but got \(count)")
        
        // Verify auth storage was updated
        let updatedState = try await authStorage.getCurrentState()
        #expect(updatedState.accessToken == "refreshed_access_token")
    }
    
    @Test("No deadlock when refresh handler uses client.perform for unauthenticated request", .timeLimit(.minutes(1)))
    func noDeadlockWhenRefreshHandlerUsesPerform() async throws {
        // Setup mock session
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userData = try JSONEncoder().encode(testUser)
        
        // Mock for the user request (authenticated)
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)
        
        // Mock for the token refresh endpoint (unauthenticated)
        let newToken = TokenResponse(
            accessToken: "refreshed_access_token",
            refreshToken: "new_refresh_token",
            expiresIn: 3600
        )
        let tokenData = try JSONEncoder().encode(newToken)
        let tokenMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/oauth/token",
            result: .success(tokenData),
            httpCode: 200
        )
        await mockSession.add(mock: tokenMock)
        
        // Setup auth storage with token expiring soon
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "old_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Create a token refresh handler that uses client.perform() for refresh
        actor RealWorldTokenRefreshHandler: TokenRefreshHandler {
            func refreshToken(using refreshToken: String, client: APIClient) async throws -> AuthenticationState {
                // This is how a real implementation would work - make an API call to refresh
                let request = try client.mutableRequest(
                    forPath: "oauth/token",
                    isAuthorized: false, // Unauthenticated request!
                    withHTTPMethod: .POST
                )
                
                let response: TokenResponse = try await client.perform(request: request)
                
                return AuthenticationState(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken,
                    expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn))
                )
            }
        }
        
        let refreshHandler = RealWorldTokenRefreshHandler()
        
        // Create client with refresh handler
        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: refreshHandler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: authStorage
        )
        
        try await client.refreshCurrentAuthState()
        
        // Make an authenticated request - will trigger proactive refresh
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        
        // This should NOT deadlock - use a timeout to catch it if it does
        let result = try await withThrowingTaskGroup(of: TestUser.self) { group in
            // Add the actual request
            group.addTask {
                try await client.perform(request: request) as TestUser
            }
            
            // Add a timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError(message: "Test timed out - likely deadlock!")
            }
            
            // Return the first result (should be the successful request, not timeout)
            guard let result = try await group.next() else {
                throw TestError(message: "No result from task group")
            }
            
            group.cancelAll()
            return result
        }
        
        // If we get here without timeout, the deadlock is fixed!
        #expect(result.id == "123")
    }
}
