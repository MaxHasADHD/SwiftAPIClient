# Changelog

All notable changes to SwiftAPIClient will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.8.0] - 2026-10-22

### Added
- **A request can go to another host.** `mutableRequest`, `Route` and `EmptyRoute` take an optional
  `baseURL` that replaces the configuration's for that request only, keeping its headers. For APIs
  that serve some endpoints from a second host: Trakt is moving all OAuth requests to
  `auth.trakt.tv` while the rest of its API stays on `api.trakt.tv`.

## [1.7.1]

### Fixed
- **`Retry-After` is honored again.** `DefaultResponseHandler` looked the header up as
  `allHeaderFields["retry-after"]`. `allHeaderFields` is a plain dictionary that preserves whatever
  casing CFNetwork stored — it does no case folding — so the canonical `Retry-After` servers send was
  missed, and 429s surfaced as `.rateLimitExceeded` instead of `.retry(after:)`. Since `fetchData`
  only retries `.retry(after:)`, its automatic backoff never ran. This regressed when the client was
  extracted from TraktKit, which had used the correct `allHeaderFields["Retry-After"]`. The lookup
  now uses `HTTPURLResponse.value(forHTTPHeaderField:)`, which matches case-insensitively per
  RFC 9110.

  Note: only the delta-seconds form is understood. RFC 9110 also permits an HTTP-date, which still
  falls through to `.rateLimitExceeded`.

### Added
- **Error response bodies are logged.** `fetchData` now logs the body of any response its
  `ResponseHandler` rejects, then rethrows unchanged. The body was previously unreachable —
  `handleResponse` receives only the `URLResponse`, and `perform` throws before it can decode
  `data` — so an API's explanation of *why* it refused a request was impossible to see, including in
  logs collected from users. Logged verbatim (truncated to 1KB) rather than parsed, so no error is
  dropped for having an unexpected body shape. Marked `.public` so it survives into exported logs;
  these are API error payloads, not user content.

## [1.7.0]

### Added
- `AuthenticationState.isExpired` — expiry is now a property of the state instead of an error. An expired state means "signed in, needs refresh."
- `AuthCoordinator.isTokenExpired` and `APIClient.isTokenExpired` — true when credentials exist but the access token is past its expiration date.
- `AuthCoordinator.loadCurrentState()` and `APIClient.refreshCurrentAuthState()` now return the loaded `AuthenticationState?` (`@discardableResult`), so callers get the state without a follow-up `cachedAuthState` read. `nil` means the user has never authenticated (or signed out).

### Added (auth lifecycle)
- `AuthCoordinator.ensureLoaded()` — populates the cache from storage on first call, no-op afterwards. `mutableRequest` awaits it before attaching an Authorization header, so authorized requests built before an explicit `loadCurrentState()` still find stored credentials. Startup ordering no longer affects correctness.

### Added (pagination)
- `PagedFetchResult<Element>` — the new return type of `fetchAllPages`, carrying `items`, `failedPages` (page number + error for each page that failed), `totalPages`, and `isComplete`.
- `retryLimit` parameter on `fetchAllPages` and `pagedResults`, forwarded to every page request. Pass `0` to fail fast against APIs with long rate-limit cooldowns (e.g. Trakt's 5-minute wait) instead of sleeping through `retry-after`.

### Changed
- **BREAKING**: `Route.fetchAllPages` returns `PagedFetchResult<Element>` instead of `Set<Element>`, and no longer swallows page failures. Previously a failed page silently yielded an incomplete `Set` that was indistinguishable from a complete one. Now: a first-page failure throws (nothing was fetched); a later-page failure returns the partial `items` with the missing pages listed in `failedPages`. The defensive tail probe only runs on fully successful fetches, since a count shortfall is otherwise already explained.
- **BREAKING**: `APIClient.mutableRequest(forPath:withQuery:isAuthorized:withHTTPMethod:body:)` is now `async` so it can wait for the coordinator's first storage load. Call sites add `await`.
- Proactive token refresh moved from `perform` into `fetchData`, so `EmptyRoute` and direct `fetchData` callers refresh an expiring token before sending instead of paying a 401 round trip first.
- **BREAKING**: `APIAuthentication.getCurrentState()` is now non-throwing and returns `AuthenticationState?`. Implementations must return whatever credentials exist — even expired ones — and return `nil` only when nothing is stored.
- **BREAKING**: `AuthenticationError.tokenExpired` and `.noStoredCredentials` are removed. Expiry is read from `AuthenticationState.isExpired`; missing credentials are a `nil` state. `.notConfigured` (a setup error) is the only remaining case, thrown by `APIClient.refreshCurrentAuthState()` when no coordinator is set.
- **BREAKING**: `AuthCoordinator.loadCurrentState()` no longer throws.
- `KeychainAuthentication` returns expired credentials as state instead of throwing, and treats tokens with no persisted expiration date as an expired state (`Date.distantPast`) rather than an error.

### Fixed
- `isSignedIn` no longer reports `false` for a user whose access token has expired. Previously `loadCurrentState()` threw on expired credentials and never populated the cache, making an expired-but-authenticated user indistinguishable from one who never signed in — which could prevent clients from ever attempting a token refresh.

## [1.6.0]

### Added
- `PaginationHeaders` config struct (`PagedObject.swift`) for customizing the names of the four pagination response headers. Defaults to `x-pagination-page` / `-page-count` / `-limit` / `-item-count`.
- `PagedObject.limit` and `PagedObject.itemCount` — optional values extracted from `X-Pagination-Limit` and `X-Pagination-Item-Count` response headers. Empty (nil) when the server doesn't send them, preserving behavior for older APIs.
- `PaginationInfo` struct now passed to `PagedObjectProtocol.createPagedObject(with:pagination:)`, carrying `currentPage`, `pageCount`, `limit`, and `itemCount` together.

### Changed
- `Route.fetchAllPages` and `Route.pagedResults` now compute the effective total page count from `itemCount / limit` when the server provides both headers, falling back to `pageCount` otherwise. This defends against servers (notably Trakt as of May 2026) that downgrade the requested page size for "heavy" response modes — in that scenario the `pageCount` header alone can be wrong, leading to silently truncated results.
- `Route.fetchAllPages` adds a defensive sequential probe after the main concurrent loop: if the server's reported `itemCount` is higher than what was collected, it walks subsequent pages (capped at 10) until an empty page or no-progress. Final safety net for servers whose pagination headers diverge from reality.
- **BREAKING**: `APIClient.Configuration.init` — four `pagination*Header: String` parameters replaced by a single `paginationHeaders: PaginationHeaders = .default` parameter. The four flat stored properties on `Configuration` are also removed in favor of `paginationHeaders`.
- **BREAKING**: `PagedObjectProtocol.createPagedObject(with:currentPage:pageCount:)` → `createPagedObject(with:pagination:)`. Only relevant for custom implementers of the protocol; consumers of `PagedObject` itself are unaffected.

### Migration Guide
For `APIClient.Configuration`:
```swift
// Before
let configuration = APIClient.Configuration(
    baseURL: baseURL,
    paginationPageHeader: "x-pagination-page",
    paginationPageCountHeader: "x-pagination-page-count"
)

// After — defaults match the Trakt/X-Pagination-* convention
let configuration = APIClient.Configuration(baseURL: baseURL)

// After — with non-default header names
let configuration = APIClient.Configuration(
    baseURL: baseURL,
    paginationHeaders: PaginationHeaders(
        page: "X-Page",
        pageCount: "X-Total-Pages",
        limit: "X-Per-Page",
        itemCount: "X-Total-Count"
    )
)
```

For custom `PagedObjectProtocol` implementers (rare):
```swift
// Before
static func createPagedObject(with object: Decodable, currentPage: Int, pageCount: Int) -> Self { ... }

// After
static func createPagedObject(with object: Decodable, pagination: PaginationInfo) -> Self { ... }
// pagination.currentPage, pagination.pageCount, pagination.limit, pagination.itemCount
```

## [1.5.1]

### Fixed
- `AuthCoordinator.signOut()` now cancels any in-flight refresh and skips persisting its result. Previously, signing out while a refresh was in flight could leave the refreshed token in storage and cache after the sign-out completed.

### Changed
- 401 retry path in `APIClient.fetchData` now tries the coordinator's cached access token before invoking the refresh handler. When another client (or another in-flight request) has already refreshed via the same `AuthCoordinator`, the retry uses the up-to-date cached token without triggering a second refresh round-trip.

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
