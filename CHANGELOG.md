# Changelog

All notable changes to SwiftAPIClient will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **BREAKING**: Renamed `APIManager` class to `APIClient`
- **BREAKING**: Renamed `APIManagerError` enum to `APIClientError`
- **BREAKING**: Route and EmptyRoute initializer parameter renamed from `apiManager:` to `apiClient:`
- Updated all documentation to use `client` as variable name instead of `apiManager`

### Migration Guide
To migrate from previous version:
1. Replace all `APIManager` references with `APIClient`
2. Replace all `APIManagerError` references with `APIClientError`
3. Update Route/EmptyRoute creation: `apiManager: self` → `apiClient: self`
4. Update variable names: `let apiManager = APIClient(...)` → `let client = APIClient(...)`

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
