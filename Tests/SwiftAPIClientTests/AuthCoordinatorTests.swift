//
//  AuthCoordinatorTests.swift
//  SwiftAPIClient
//

import Foundation
import Testing
@testable import SwiftAPIClient

// MARK: - Suite

@Suite("AuthCoordinator Tests")
struct AuthCoordinatorTests {

    let baseURL = URL(string: "https://api.example.com")!

    // MARK: - Cache + sign-in/out

    @Test("Initially has no cached state and reports not signed in")
    func initiallyEmpty() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage)

        #expect(coordinator.cachedAuthState == nil)
        #expect(coordinator.isSignedIn == false)
        #expect(coordinator.shouldRefreshToken() == false)
    }

    @Test("loadCurrentState populates cache from storage")
    func loadCurrentStatePopulatesCache() async throws {
        let storage = MockAuthStorage()
        let state = AuthenticationState(
            accessToken: "access",
            refreshToken: "refresh",
            expirationDate: Date().addingTimeInterval(3600)
        )
        await storage.updateState(state)

        let coordinator = AuthCoordinator(storage: storage)
        try await coordinator.loadCurrentState()

        #expect(coordinator.isSignedIn)
        #expect(coordinator.cachedAuthState?.accessToken == "access")
    }

    @Test("loadCurrentState propagates noStoredCredentials")
    func loadCurrentStatePropagatesError() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage)

        await #expect(throws: AuthenticationError.noStoredCredentials) {
            try await coordinator.loadCurrentState()
        }
        #expect(coordinator.isSignedIn == false)
    }

    @Test("updateCachedState writes the cache without touching storage")
    func updateCachedStateBypassesStorage() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage)

        let state = AuthenticationState(
            accessToken: "memory-only",
            refreshToken: "rt",
            expirationDate: Date().addingTimeInterval(3600)
        )
        coordinator.updateCachedState(state)

        #expect(coordinator.cachedAuthState?.accessToken == "memory-only")
        #expect(await storage.updateStateCallCount == 0)
    }

    @Test("signOut clears both storage and cache")
    func signOutClearsBoth() async throws {
        let storage = MockAuthStorage()
        let state = AuthenticationState(
            accessToken: "access",
            refreshToken: "refresh",
            expirationDate: Date().addingTimeInterval(3600)
        )
        await storage.updateState(state)

        let coordinator = AuthCoordinator(storage: storage)
        try await coordinator.loadCurrentState()
        #expect(coordinator.isSignedIn)

        await coordinator.signOut()

        #expect(coordinator.isSignedIn == false)
        #expect(coordinator.cachedAuthState == nil)
        #expect(await storage.clearCallCount == 1)
    }

    // MARK: - shouldRefreshToken

    @Test("shouldRefreshToken returns true when expiration is within threshold")
    func shouldRefreshWhenExpirationNear() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage, refreshThreshold: 300)

        coordinator.updateCachedState(AuthenticationState(
            accessToken: "a",
            refreshToken: "r",
            expirationDate: Date().addingTimeInterval(120) // 2 min from now, threshold 5 min
        ))

        #expect(coordinator.shouldRefreshToken() == true)
    }

    @Test("shouldRefreshToken returns false when expiration is far in future")
    func noRefreshWhenExpirationFar() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage, refreshThreshold: 300)

        coordinator.updateCachedState(AuthenticationState(
            accessToken: "a",
            refreshToken: "r",
            expirationDate: Date().addingTimeInterval(3600)
        ))

        #expect(coordinator.shouldRefreshToken() == false)
    }

    // MARK: - performTokenRefresh

    @Test("performTokenRefresh throws unauthorized when no handler is set")
    func refreshThrowsWithNoHandler() async throws {
        let storage = MockAuthStorage()
        let coordinator = AuthCoordinator(storage: storage, refreshHandler: nil)
        coordinator.updateCachedState(AuthenticationState(
            accessToken: "a", refreshToken: "r", expirationDate: Date().addingTimeInterval(60)
        ))

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        await #expect(throws: APIError.unauthorized) {
            _ = try await coordinator.performTokenRefresh(client: client)
        }
    }

    @Test("performTokenRefresh updates both storage and cache on success")
    func refreshUpdatesStorageAndCache() async throws {
        let storage = MockAuthStorage()
        let initialState = AuthenticationState(
            accessToken: "old", refreshToken: "old-rt", expirationDate: Date().addingTimeInterval(60)
        )
        await storage.updateState(initialState)

        let handler = MockTokenRefreshHandler()
        await handler.setNewToken(TokenResponse(
            accessToken: "new", refreshToken: "new-rt", expiresIn: 3600
        ))

        let coordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        let newState = try await coordinator.performTokenRefresh(client: client)

        #expect(newState.accessToken == "new")
        #expect(coordinator.cachedAuthState?.accessToken == "new")
        let storageState = try await storage.getCurrentState()
        #expect(storageState.accessToken == "new")
    }

    @Test("Concurrent performTokenRefresh calls share one in-flight task")
    func refreshDeduplication() async throws {
        let storage = MockAuthStorage()
        let initialState = AuthenticationState(
            accessToken: "old", refreshToken: "old-rt", expirationDate: Date().addingTimeInterval(60)
        )
        await storage.updateState(initialState)

        let handler = MockTokenRefreshHandler()
        await handler.setNewToken(TokenResponse(
            accessToken: "new", refreshToken: "new-rt", expiresIn: 3600
        ))
        await handler.setRefreshDelay(0.1)

        let coordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await coordinator.performTokenRefresh(client: client)
                }
            }
        }

        // Ten concurrent callers, but the handler ran exactly once.
        #expect(await handler.refreshCallCount == 1)
        #expect(coordinator.cachedAuthState?.accessToken == "new")
    }

    @Test("Sequential refresh attempts each invoke the handler")
    func refreshIsRepeatableAfterCompletion() async throws {
        let storage = MockAuthStorage()
        let initialState = AuthenticationState(
            accessToken: "v0", refreshToken: "rt0", expirationDate: Date().addingTimeInterval(60)
        )
        await storage.updateState(initialState)

        let handler = MockTokenRefreshHandler()
        let coordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        await handler.setNewToken(TokenResponse(accessToken: "v1", refreshToken: "rt1", expiresIn: 3600))
        _ = try await coordinator.performTokenRefresh(client: client)

        await handler.setNewToken(TokenResponse(accessToken: "v2", refreshToken: "rt2", expiresIn: 3600))
        _ = try await coordinator.performTokenRefresh(client: client)

        #expect(await handler.refreshCallCount == 2)
        #expect(coordinator.cachedAuthState?.accessToken == "v2")
    }

    @Test("Refresh failure leaves cache untouched and rethrows to all waiters")
    func refreshFailureDoesNotMutateCache() async throws {
        let storage = MockAuthStorage()
        let initialState = AuthenticationState(
            accessToken: "old", refreshToken: "old-rt", expirationDate: Date().addingTimeInterval(60)
        )
        await storage.updateState(initialState)

        let handler = MockTokenRefreshHandler()
        await handler.setShouldFail(true)

        let coordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        var caughtCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await coordinator.performTokenRefresh(client: client)
                        return false
                    } catch {
                        return true
                    }
                }
            }
            for await caught in group where caught {
                caughtCount += 1
            }
        }

        #expect(caughtCount == 3)
        #expect(coordinator.cachedAuthState?.accessToken == "old")
    }

    // MARK: - Multi-client sharing

    @Test("Two APIClients sharing one coordinator both observe a refresh")
    func sharedCoordinatorAcrossClients() async throws {
        let mockSession = MockSession()

        let testUser = TestUser(id: "1", name: "Shared User")
        let userData = try JSONEncoder().encode(testUser)
        let userMock = try RequestMocking.MockedResponse(
            urlString: "https://api.example.com/users/me",
            result: .success(userData),
            httpCode: 200
        )
        await mockSession.add(mock: userMock)

        // Setup auth storage with a token expiring soon (forces proactive refresh)
        let storage = MockAuthStorage()
        await storage.updateState(AuthenticationState(
            accessToken: "old",
            refreshToken: "old-rt",
            expirationDate: Date().addingTimeInterval(60)
        ))

        let handler = MockTokenRefreshHandler()
        await handler.setNewToken(TokenResponse(
            accessToken: "shared-new",
            refreshToken: "shared-new-rt",
            expiresIn: 3600
        ))
        await handler.setRefreshDelay(0.05) // small window to expose any race

        let sharedCoordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await sharedCoordinator.loadCurrentState()

        // Two clients with independent URLSession instances but the same coordinator —
        // models the "isolated network resources, shared auth state" use case.
        let configuration = APIClient.Configuration(baseURL: baseURL)
        let clientA = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: sharedCoordinator
        )
        let clientB = APIClient(
            configuration: configuration,
            session: mockSession.urlSession,
            authCoordinator: sharedCoordinator
        )

        let request = try clientA.mutableRequest(
            forPath: "users/me",
            isAuthorized: true,
            withHTTPMethod: .GET
        )

        // Hit both clients in parallel — both should see the shared refresh.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try? await clientA.perform(request: request) as TestUser
                }
                group.addTask {
                    _ = try? await clientB.perform(request: request) as TestUser
                }
            }
        }

        // The handler should have been invoked exactly once across BOTH clients.
        #expect(await handler.refreshCallCount == 1)
        // Both clients see the new token via the shared coordinator.
        #expect(clientA.authCoordinator?.cachedAuthState?.accessToken == "shared-new")
        #expect(clientB.authCoordinator?.cachedAuthState?.accessToken == "shared-new")
    }

    @Test("Sign-out on shared coordinator is observed by all clients")
    func sharedSignOut() async throws {
        let storage = MockAuthStorage()
        await storage.updateState(AuthenticationState(
            accessToken: "a", refreshToken: "r", expirationDate: Date().addingTimeInterval(3600)
        ))

        let coordinator = AuthCoordinator(storage: storage)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let clientA = APIClient(configuration: configuration, authCoordinator: coordinator)
        let clientB = APIClient(configuration: configuration, authCoordinator: coordinator)

        #expect(clientA.isSignedIn)
        #expect(clientB.isSignedIn)

        await clientA.signOut()

        #expect(clientA.isSignedIn == false)
        #expect(clientB.isSignedIn == false)
    }

    // MARK: - signOut race with in-flight refresh

    @Test("signOut during in-flight refresh discards the refreshed token")
    func signOutCancelsInFlightRefresh() async throws {
        let storage = MockAuthStorage()
        await storage.updateState(AuthenticationState(
            accessToken: "old", refreshToken: "old-rt", expirationDate: Date().addingTimeInterval(60)
        ))

        // Long handler delay so we have a wide window to call signOut while
        // the refresh is in flight.
        let handler = MockTokenRefreshHandler()
        await handler.setNewToken(TokenResponse(accessToken: "new", refreshToken: "new-rt", expiresIn: 3600))
        await handler.setRefreshDelay(0.3)

        let coordinator = AuthCoordinator(storage: storage, refreshHandler: handler)
        try await coordinator.loadCurrentState()

        let configuration = APIClient.Configuration(baseURL: baseURL)
        let client = APIClient(configuration: configuration, authCoordinator: coordinator)

        // Kick off the refresh, then sign out before it finishes.
        let refreshTask = Task<Bool, Never> {
            do {
                _ = try await coordinator.performTokenRefresh(client: client)
                return false // refresh succeeded — should not happen post-signOut
            } catch {
                return true  // refresh threw (CancellationError expected)
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await coordinator.signOut()

        let refreshThrew = await refreshTask.value

        // After signOut, the coordinator's state should remain cleared even
        // though the handler eventually produced a fresh token.
        #expect(coordinator.cachedAuthState == nil)
        #expect(coordinator.isSignedIn == false)
        // Storage should not have been updated with the refreshed token.
        await #expect(throws: AuthenticationError.noStoredCredentials) {
            _ = try await storage.getCurrentState()
        }
        // The in-flight refresh saw its task get cancelled and rethrew.
        #expect(refreshThrew)
    }
}
