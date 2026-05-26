# Changelog

All notable changes to SwiftAPIClient will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.1]

### Fixed
- `AuthCoordinator.signOut()` now cancels any in-flight refresh and skips persisting its result. Previously, signing out while a refresh was in flight could leave the refreshed token in storage and cache after the sign-out completed.

## [1.5.0]

### Added
- `AuthCoordinator` — owns the cached `AuthenticationState`, the `TokenRefreshHandler`, and the in-flight refresh task slot. Multiple `APIClient` instances can share one coordinator to coalesce refresh attempts and observe each other's auth state changes (e.g., one client per `URLSession` against the same API).
- New designated initializer `APIClient.init(configuration:session:authCoordinator:)`.
- `AuthCoordinator.refreshThreshold` — per-coordinator control of when proactive refresh fires (was previously on `Configuration`).

### Deprecated
- `APIClient.init(configuration:session:authStorage:)` — construct an `AuthCoordinator` and pass it to `init(configuration:session:authCoordinator:)` instead. The deprecated initializer still works and internally wraps the supplied storage in a coordinator using `Configuration.tokenRefreshHandler` and `Configuration.tokenRefreshThreshold`.
- `Configuration.tokenRefreshHandler` and `Configuration.tokenRefreshThreshold` — only consulted by the deprecated initializer. Set these on `AuthCoordinator` directly.

### Migration Guide
Before:
```swift
let configuration = APIClient.Configuration(
    baseURL: baseURL,
    tokenRefreshHandler: MyRefreshHandler(),
    tokenRefreshThreshold: 300
)
let client = APIClient(
    configuration: configuration,
    authStorage: KeychainAuthentication(serviceName: "com.example.app")
)
```

After:
```swift
let configuration = APIClient.Configuration(baseURL: baseURL)
let coordinator = AuthCoordinator(
    storage: KeychainAuthentication(serviceName: "com.example.app"),
    refreshHandler: MyRefreshHandler(),
    refreshThreshold: 300
)
let client = APIClient(configuration: configuration, authCoordinator: coordinator)
```

To run two `APIClient` instances against the same API while keeping auth state and refresh coordination consistent, construct one `AuthCoordinator` and pass it to each client.

## [1.4.1]

### Fixed
- `KeychainAuthentication.updateState` now refreshes the in-memory `expirationDate` cache. Previously, re-authenticating after a refresh failure left the stale expired date cached in the actor, causing the next `getCurrentState()` to throw `.tokenExpired` with the newly issued refresh token.

## [1.4.0]

### Added
- Retry jitter (0–30s, random) on `APIError.retry(after:)` to prevent thundering herd when many concurrent requests all receive a 429 simultaneously.

### Changed
- Default `maxConcurrentRequests` on `Route.fetchAllPages(_:)` and `Route.pagedResults(_:)` reduced from 10 to 5.
- Package now declares Swift language mode using `.v6` instead of `.version("6.0")`.

## [1.3.2]

### Fixed
- Deadlock when an unauthenticated request (e.g., the refresh-token request itself) responded with 401. Unauthenticated 401s now fail immediately instead of attempting a token refresh.

## [1.3.1]

### Fixed
- Token refresh deadlock when multiple concurrent requests triggered a refresh simultaneously.

## [1.3.0]

### Added
- Proactive token refresh: `perform(request:)` refreshes the access token automatically if it will expire within `Configuration.tokenRefreshThreshold` (default 5 minutes).
- Automatic refresh-and-retry on 401: authenticated requests that receive a 401 automatically refresh the token and retry once.
- `TokenRefreshHandler` protocol for plugging in API-specific refresh logic.
- `Configuration.tokenRefreshHandler` and `Configuration.tokenRefreshThreshold` parameters.
- `AuthenticationError.tokenExpired(refreshToken:)` case for surfacing expired tokens to refresh handlers.

## [1.2.0]

### Added
- `Configuration.dateDecodingStrategy` parameter to customize JSON date decoding (defaults to the built-in custom strategy, preserving prior behavior).

### Changed
- Default date decoding strategy rewritten to use Swift's `ISO8601FormatStyle` and to drop shared mutable state, fixing a race when decoding dates from multiple concurrent responses.

## [1.1.1]

### Changed
- Documentation: backfilled the 1.1.0 CHANGELOG entry. No code changes.

## [1.1.0]

### Added
- `ResponseHandler` protocol for customizable error handling
- `DefaultResponseHandler` for standard HTTP status code handling
- Support for API-specific error types thrown directly from custom handlers
- `throwStandardError(for:)` helper method for delegating to standard error handling
- Automatic retry logic preserved for custom error handlers

### Changed
- **BREAKING**: Renamed `APIManager` class to `APIClient`
- **BREAKING**: Renamed `APIManagerError` enum to `APIClientError`
- **BREAKING**: Route and EmptyRoute initializer parameter renamed from `apiManager:` to `apiClient:`
- **BREAKING**: Removed Trakt-specific errors from `APIError` (accountLocked, vipOnly, accountLimitExceeded, cloudflareError)
- **BREAKING**: Renamed generic `APIError` cases: `noRecordFound` → `notFound`, `noMethodFound` → `methodNotAllowed`, `resourceAlreadyCreated` → `conflict`
- `APIClient.Configuration` now accepts `responseHandler` parameter (defaults to `DefaultResponseHandler()`)

### Migration Guide
To migrate from previous version:
1. Replace all `APIManager` references with `APIClient`
2. Replace all `APIManagerError` references with `APIClientError`
3. Update Route/EmptyRoute creation: `apiManager: self` → `apiClient: self`
4. Update variable names: `let apiManager = APIClient(...)` → `let client = APIClient(...)`
5. If using Trakt-specific errors, create a custom `ResponseHandler`:
   - Define your own error type (e.g., `TraktError`)
   - Implement `ResponseHandler` protocol
   - Throw custom errors for API-specific status codes
   - Use `throwStandardError(for:)` for standard HTTP errors
6. Update `APIError` case references: `noRecordFound` → `notFound`, `noMethodFound` → `methodNotAllowed`, `resourceAlreadyCreated` → `conflict`

## [1.0.1]

### Added
- `APIClient.updateCachedAuthState(_:)` for updating the in-memory auth cache directly (e.g., immediately after a sign-in completes), without round-tripping through storage.

## [1.0.0] - Initial Release

### Added
- Core `APIClient` for configurable REST API clients
- OAuth authentication with keychain storage
- Automatic retry handling for rate-limited requests (429)
- Protocol-based `ResponseHandler` for customizable error handling
- Type-safe `Route<T>` and `EmptyRoute` for endpoint definitions
- Pagination support with `PagedObject<T>`
- Standard HTTP error handling via `APIError` enum
- Request mocking infrastructure for testing
