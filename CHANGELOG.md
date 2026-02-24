# Changelog

All notable changes to SwiftAPIClient will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
