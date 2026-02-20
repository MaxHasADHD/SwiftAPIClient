# SwiftAPIClient

A modern, generic REST API client framework for Swift with async/await support.

## Features

- **Generic & Reusable**: Build API wrappers for any REST API (Trakt, TMDB, etc.)
- **Modern Swift**: Built with Swift 6, async/await, and Sendable
- **Type-Safe**: Strongly-typed requests and responses
- **Configurable**: Flexible configuration for base URLs, headers, pagination
- **Authentication**: Built-in OAuth support with keychain storage
- **Pagination**: First-class pagination support with concurrent fetching
- **Error Handling**: Comprehensive HTTP error mapping
- **Testing**: URLProtocol-based request mocking for tests

## Requirements

- iOS 16.0+ / tvOS 16.0+ / watchOS 9.0+ / macOS 13.0+
- Swift 6.0+

## Installation

### Swift Package Manager

Add SwiftAPIClient to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/MaxHasADHD/SwiftAPIClient.git", from: "1.0.0")
]
```

Or add it via Xcode: File → Add Package Dependencies

## Usage

### Basic Setup

```swift
import SwiftAPIClient

// 1. Create your API manager
let config = APIManager.Configuration(
    baseURL: URL(string: "https://api.example.com")!,
    additionalHeaders: [
        "api-version": "2",
        "api-key": "your-api-key"
    ],
    paginationPageHeader: "x-pagination-page",
    paginationPageCountHeader: "x-pagination-page-count"
)

let apiManager = APIManager(
    configuration: config,
    authStorage: KeychainAuthentication(
        accessTokenKey: "accessToken",
        refreshTokenKey: "refreshToken",
        expirationDateKey: "expirationDate"
    )
)

// 2. Make requests using Route
let route = Route<[Movie]>(
    path: "movies/trending",
    method: .GET,
    requiresAuthentication: false,
    apiManager: apiManager
)

let movies = try await route.perform()
```

### Pagination

```swift
let route = Route<PagedObject<[Movie]>>(
    path: "movies/popular",
    method: .GET,
    apiManager: apiManager
)

// Fetch a specific page
let firstPage = try await route.page(1).limit(20).perform()

// Fetch all pages concurrently
let allMovies = try await route.fetchAllPages()

// Stream pages as they arrive
for try await pageOfMovies in route.pagedResults() {
    print("Got \(pageOfMovies.count) movies")
}
```

### Authentication

```swift
// Configure authentication storage
let authStorage = KeychainAuthentication(
    accessTokenKey: "myapp.access_token",
    refreshTokenKey: "myapp.refresh_token",
    expirationDateKey: "myapp.expiration_date"
)

let manager = APIManager(configuration: config, authStorage: authStorage)

// Make authenticated requests
let route = Route<User>(
    path: "users/me",
    method: .GET,
    requiresAuthentication: true,
    apiManager: manager
)
```

### Extending for Your API

Create API-specific extensions:

```swift
// Extend Route with your API's query parameters
extension Route {
    func filter(_ filter: MyAPIFilter) -> Self {
        var copy = self
        let (key, value) = filter.value()
        copy.queryItems[key] = value
        return copy
    }
}

// Use it
let route = Route<[Movie]>(...)
    .filter(.genre("action"))
    .page(1)
    .limit(20)
```

## Architecture

SwiftAPIClient provides the generic foundation:

- **APIManager**: Core manager handling requests, auth, and configuration
- **Route**: Type-safe request builder with chainable methods
- **PagedObject**: Generic pagination wrapper
- **APIError**: HTTP error handling
- **APIAuthentication**: Authentication protocol with keychain implementation

You build your API-specific wrapper on top:

```
YourAPIWrapper
├── YourManager (extends APIManager)
├── Route extensions (API-specific queries)
├── Domain models
└── Resource endpoints
```

## Example: TraktKit

See [TraktKit](https://github.com/MaxHasADHD/TraktKit) for a complete example of building an API wrapper with SwiftAPIClient.

## License

MIT License - see LICENSE file for details
