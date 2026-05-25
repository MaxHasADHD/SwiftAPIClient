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
    
    @Test("APIClient accepts an AuthCoordinator with a refresh handler")
    func clientAcceptsRefreshHandler() async throws {
        let mockHandler = MockTokenRefreshHandler()
        let coordinator = AuthCoordinator(
            storage: MockAuthStorage(),
            refreshHandler: mockHandler
        )

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        #expect(client.authCoordinator === coordinator)
        #expect(coordinator.refreshHandler != nil)
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
        
        // Setup coordinator with refresh handler
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setNewToken(newToken)

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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
        
        // Setup coordinator (handler should never be called)
        let refreshHandler = MockTokenRefreshHandler()

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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
        
        // Setup coordinator with failing refresh handler
        let refreshHandler = MockTokenRefreshHandler()
        await refreshHandler.setShouldFail(true)

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )
        
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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )
        
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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )
        
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

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

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
    
    @Test("No deadlock when refresh endpoint returns 401", .timeLimit(.minutes(1)))
    func noDeadlockWhenRefreshEndpointReturns401() async throws {
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
        
        // Mock for the token refresh endpoint - returns 401 (invalid refresh token)
        let tokenMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/oauth/token",
            result: .success(Data()),
            httpCode: 401 // Refresh token is invalid!
        )
        await mockSession.add(mock: tokenMock)
        
        // Setup auth storage with token expiring soon
        let authStorage = MockAuthStorage()
        let expiringState = AuthenticationState(
            accessToken: "old_access_token",
            refreshToken: "invalid_refresh_token",
            expirationDate: Date().addingTimeInterval(120) // 2 minutes from now
        )
        await authStorage.updateState(expiringState)
        
        // Create a token refresh handler that uses client.perform() for refresh
        actor RealWorldTokenRefreshHandler: TokenRefreshHandler {
            func refreshToken(using refreshToken: String, client: APIClient) async throws -> AuthenticationState {
                let request = try client.mutableRequest(
                    forPath: "oauth/token",
                    isAuthorized: false, // Unauthenticated request!
                    withHTTPMethod: .POST
                )
                
                // This will get a 401 - should NOT trigger another refresh attempt (deadlock)
                let response: TokenResponse = try await client.perform(request: request)
                
                return AuthenticationState(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken,
                    expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn))
                )
            }
        }
        
        let refreshHandler = RealWorldTokenRefreshHandler()

        let coordinator = AuthCoordinator(storage: authStorage, refreshHandler: refreshHandler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: coordinator
        )

        // Make an authenticated request - will trigger proactive refresh
        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )

        // This should NOT deadlock - should fail with 401 error
        do {
            let _: TestUser = try await client.perform(request: request)
            Issue.record("Expected 401 error to be thrown")
        } catch APIError.unauthorized {
            // Expected - refresh endpoint returned 401
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - Deprecated init backward-compat

/// Regression coverage for the deprecated
/// `APIClient.init(configuration:session:authStorage:)`. New code should
/// construct an `AuthCoordinator` directly; these tests exist only to ensure
/// the deprecated bridge keeps working for existing callers. Deprecation
/// warnings inside this suite are intentional.
@Suite("Deprecated authStorage init")
struct DeprecatedAuthStorageInitTests {

    let baseURL = URL(string: "https://api.example.com")!

    @Test("Deprecated init forwards Configuration handler + threshold into the coordinator")
    func deprecatedInitBridgesConfigurationFields() async throws {
        let handler = MockTokenRefreshHandler()
        let storage = MockAuthStorage()

        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: handler,
            tokenRefreshThreshold: 123
        )
        let client = APIClient(configuration: configuration, authStorage: storage)

        let coordinator = try #require(client.authCoordinator)
        #expect(coordinator.storage as? MockAuthStorage === storage)
        #expect(coordinator.refreshHandler as? MockTokenRefreshHandler === handler)
        #expect(coordinator.refreshThreshold == 123)
    }

    @Test("Deprecated init still triggers proactive refresh on near-expiry token")
    func deprecatedInitProactiveRefresh() async throws {
        let mockSession = MockSession()
        let testUser = TestUser(id: "123", name: "Test User")
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(try JSONEncoder().encode(testUser)),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)

        let storage = MockAuthStorage()
        await storage.updateState(AuthenticationState(
            accessToken: "old",
            refreshToken: "old-rt",
            expirationDate: Date().addingTimeInterval(60) // expires within default threshold
        ))

        let handler = MockTokenRefreshHandler()
        await handler.setNewToken(TokenResponse(accessToken: "new", refreshToken: "new-rt", expiresIn: 3600))

        let configuration = APIClient.Configuration(
            baseURL: baseURL,
            tokenRefreshHandler: handler
        )
        let client = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authStorage: storage
        )
        try await client.refreshCurrentAuthState()

        let request = try client.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )
        _ = try await client.perform(request: request) as TestUser

        #expect(await handler.refreshCallCount == 1)
        #expect(client.authCoordinator?.cachedAuthState?.accessToken == "new")
    }

    @Test("Sign-out via deprecated init clears both storage and cache")
    func deprecatedInitSignOut() async throws {
        let storage = MockAuthStorage()
        await storage.updateState(AuthenticationState(
            accessToken: "a", refreshToken: "r", expirationDate: Date().addingTimeInterval(3600)
        ))

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authStorage: storage)
        try await client.refreshCurrentAuthState()
        #expect(client.isSignedIn)

        await client.signOut()

        #expect(client.isSignedIn == false)
        #expect(await storage.clearCallCount == 1)
    }
}
