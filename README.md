# SwiftAPIClient

A flexible, generic Swift package for building REST API clients with OAuth support, automatic retry handling, and customizable error handling.

## Features

- **Generic API Management**: Core `APIClient` that can be configured for any REST API
- **OAuth Authentication**: Built-in support for OAuth with keychain storage
- **Token Refresh**: Pluggable `TokenRefreshHandler` with proactive and reactive (401) refresh
- **Shared Auth State**: `AuthCoordinator` lets multiple `APIClient` instances share one cache and coalesce refresh attempts
- **Automatic Retry**: Intelligent retry handling for rate-limited requests
- **Customizable Error Handling**: Protocol-based response handling for API-specific errors
- **Pagination Support**: Built-in support for paginated responses
- **Type-Safe**: Leverages Swift's type system with `Codable` for request/response handling

## Installation

Add this package to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/SwiftAPIClient", from: "1.0.0")
]
```

## Basic Usage

### 1. Configure Your API Client

```swift
import SwiftAPIClient

let configuration = APIClient.Configuration(
    baseURL: URL(string: "https://api.example.com")!,
    additionalHeaders: [
        "trakt-api-version": "2",
        "trakt-api-key": "your-client-id"
    ]
)

let coordinator = AuthCoordinator(
    storage: KeychainAuthentication(serviceName: "com.example.app"),
    refreshHandler: MyTokenRefreshHandler() // optional, see "Authentication" below
)

let client = APIClient(
    configuration: configuration,
    authCoordinator: coordinator
)

// Load the cached state from storage once at startup.
try await client.refreshCurrentAuthState()
```

> If you only call unauthenticated endpoints, omit `authCoordinator` entirely.

### 2. Define Your API Client with Routes

The `Route` type provides type-safe API endpoints with automatic response mapping. Define routes as extensions on `APIClient`:

```swift
struct User: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct Post: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String
}

extension APIClient {
    // Route returns Route<User> with type information
    func getUser(id: String) -> Route<User> {
        Route(
            path: "users/\(id)",
            method: .GET,
            apiClient: self
        )
    }
    
    // Using paths array for dynamic path building
    func getPost(userId: String, postId: String) -> Route<Post> {
        Route(
            paths: ["users", userId, "posts", postId],
            method: .GET,
            apiClient: self
        )
    }
    
    // With optional path segments - nil values are automatically removed
    func searchPosts(category: String?, tag: String?) -> Route<[Post]> {
        Route(
            paths: ["posts", "search", category, tag],
            method: .GET,
            apiClient: self
        )
    }
    
    // With authentication
    func createPost(title: String, body: String) -> Route<Post> {
        let postData = Post(id: "", title: title, body: body)
        return Route(
            path: "posts",
            body: postData,
            method: .POST,
            requiresAuthentication: true,
            apiClient: self
        )
    }
}
```

### 3. Make Requests

Routes automatically decode responses to the correct type:

```swift
do {
    // Simple request - type is inferred from Route<User>
    let user = try await client.getUser(id: "123").perform()
    print("User: \(user.name)")
    
    // With optional path segments - nil category is filtered out
    let posts = try await client.searchPosts(category: nil, tag: "swift").perform()
    print("Found \(posts.count) posts")
    
    // Authenticated request
    let newPost = try await client.createPost(
        title: "Hello World",
        body: "This is my first post"
    ).perform()
    print("Created post: \(newPost.id)")
    
} catch let error as APIError {
    print("API Error: \(error.localizedDescription)")
}
```

### Alternative: Direct Request Building

You can also build requests directly without Routes:

```swift
do {
    let request = try client.mutableRequest(
        forPath: "users/123",
        isAuthorized: false,
        withHTTPMethod: .GET
    )
    let user: User = try await client.perform(request: request)
    print("User: \(user.name)")
} catch let error as APIError {
    print("API Error: \(error.localizedDescription)")
}
```

## Custom Error Handling

The library provides a flexible, type-safe error handling system that allows you to define API-specific errors while maintaining standard HTTP error handling.

### Using the Default Handler

By default, `APIClient` uses `DefaultResponseHandler`, which provides standard HTTP status code handling (400, 401, 403, 404, 429, 500, 503, etc.) and throws `APIError`.

### Creating API-Specific Error Types

For APIs with custom status codes or error handling, you can define your own error type and throw it directly from a custom `ResponseHandler`:

```swift
// 1. Define your API-specific error type
enum TraktError: Error, LocalizedError {
    case accountLimitExceeded
    case accountLocked
    case vipOnly
    
    // You can also include standard errors if needed
    case standard(APIError)
    
    var errorDescription: String? {
        switch self {
        case .accountLimitExceeded:
            return "You've exceeded your account limit."
        case .accountLocked:
            return "Your account is locked. Please contact support."
        case .vipOnly:
            return "This feature requires a VIP subscription."
        case .standard(let error):
            return error.localizedDescription
        }
    }
}

// 2. Implement a custom ResponseHandler
struct TraktResponseHandler: ResponseHandler {
    func handleResponse(_ response: URLResponse?) throws {
        guard let response else { return }
        guard let httpResponse = response as? HTTPURLResponse else { 
            throw APIError.unhandled(response) 
        }
        
        // Success range
        guard 200...299 ~= httpResponse.statusCode else {
            // Handle Trakt-specific status codes first
            switch httpResponse.statusCode {
            case 420:
                throw TraktError.accountLimitExceeded
            case 423:
                throw TraktError.accountLocked
            case 426:
                throw TraktError.vipOnly
            default:
                // Fall back to standard HTTP error handling for other codes
                try throwStandardError(for: httpResponse)
            }
        }
    }
}

// 3. Configure your API client with the custom handler
let configuration = APIClient.Configuration(
    baseURL: URL(string: "https://api.trakt.tv")!,
    responseHandler: TraktResponseHandler()
)
let client = APIClient(configuration: configuration)

// 4. Type-safe error handling - catch your specific errors directly!
do {
    let shows: [Show] = try await client.perform(request: request)
} catch TraktError.accountLimitExceeded {
    // Handle account limit specifically
    print("Upgrade your account to access more features")
} catch TraktError.vipOnly {
    // Handle VIP requirement specifically
    print("This feature requires VIP subscription")
} catch APIError.unauthorized {
    // Standard errors still work
    print("Please sign in")
} catch APIError.retry(let after) {
    // Automatic retry still works for rate limiting
    print("Rate limited, retry after \(after) seconds")
} catch {
    print("Unexpected error: \(error)")
}
```

### Key Benefits

✅ **Type-safe catching**: Catch `TraktError.accountLimitExceeded` directly - no double-switching on status codes  
✅ **No generics needed**: Each API defines its own error type  
✅ **Automatic retry preserved**: `APIError.retry(after:)` still works automatically  
✅ **Clean separation**: Library handles HTTP, your code handles API-specific logic  
✅ **Equatable/Hashable safe**: No protocol conformance issues

## Authentication

Authentication state — the cached access token, the refresh handler, and the in-flight refresh task — lives on `AuthCoordinator`, not on `APIClient`. A coordinator can be used by one client or shared across many.

### OAuth Flow

```swift
// 1. Store credentials after OAuth flow
let authState = AuthenticationState(
    accessToken: "access_token",
    refreshToken: "refresh_token",
    expirationDate: Date().addingTimeInterval(7200)
)

let keychain = KeychainAuthentication(serviceName: "com.example.app")
await keychain.updateState(authState)

let coordinator = AuthCoordinator(storage: keychain)

// 2. Update the cached state so the next request can build an authorized header
coordinator.updateCachedState(authState)

let client = APIClient(configuration: configuration, authCoordinator: coordinator)

// 3. Make authenticated requests
let request = try client.mutableRequest(
    forPath: "users/settings",
    isAuthorized: true,
    withHTTPMethod: .GET
)
```

### Token Refresh

Implement `TokenRefreshHandler` to teach the coordinator how to mint a new access token. The handler runs:

- **Proactively** before `perform(request:)` when the cached token is within `refreshThreshold` of expiring (default 5 minutes).
- **Reactively** when a 401 comes back on an authenticated request — the request is automatically retried once with the new token.

Concurrent refresh attempts (across requests *and* across clients sharing the coordinator) are coalesced into a single in-flight task — the handler runs exactly once per refresh cycle.

```swift
struct OAuthRefreshHandler: TokenRefreshHandler {
    func refreshToken(using refreshToken: String, client: APIClient) async throws -> AuthenticationState {
        let request = try client.mutableRequest(
            forPath: "oauth/token",
            isAuthorized: false, // refresh endpoint is unauthenticated
            withHTTPMethod: .POST,
            body: ["refresh_token": refreshToken, "grant_type": "refresh_token"]
        )
        let response: TokenResponse = try await client.perform(request: request)
        return AuthenticationState(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }
}

let coordinator = AuthCoordinator(
    storage: KeychainAuthentication(serviceName: "com.example.app"),
    refreshHandler: OAuthRefreshHandler(),
    refreshThreshold: 300 // refresh when <= 5 minutes from expiration
)
```

### Sharing auth across multiple clients

A common pattern: one logical API, but two `URLSession` instances — e.g., a foreground session for interactive requests and a background session for uploads. Both clients should share auth state so a refresh triggered by one is immediately visible to the other.

```swift
let coordinator = AuthCoordinator(
    storage: KeychainAuthentication(serviceName: "com.example.app"),
    refreshHandler: OAuthRefreshHandler()
)
try await coordinator.loadCurrentState()

let interactiveClient = APIClient(
    configuration: configuration,
    session: URLSession(configuration: .default),
    authCoordinator: coordinator
)

let backgroundClient = APIClient(
    configuration: configuration,
    session: URLSession(configuration: .background(withIdentifier: "uploads")),
    authCoordinator: coordinator
)
```

When both clients hit 401 simultaneously, the refresh handler is invoked exactly once, and both clients see the new token.

### Sign Out

```swift
await client.signOut() // clears storage + cache on the coordinator
```

When two clients share a coordinator, signing out via either one is observed by both. Any in-flight token refresh is cancelled so its result cannot land in storage after the sign-out completes.

## Pagination

For paginated responses, use `PagedObject`:

```swift
typealias Users = PagedObject<[User]>

let pagedUsers: Users = try await client.perform(request: request)
print("Page \(pagedUsers.currentPage) of \(pagedUsers.pageCount)")
print("Users: \(pagedUsers.items)")
```

## Automatic Retry

The library automatically handles rate limiting (429) responses with `retry-after` headers:

```swift
// Automatically retries up to 3 times (default)
let user: User = try await client.perform(request: request)

// Custom retry limit
let user: User = try await client.perform(request: request, retryLimit: 5)
```

## Error Handling

The library supports both standard HTTP errors via `APIError` and custom API-specific errors via your own error types:

```swift
do {
    let user: User = try await client.perform(request: request)
} catch APIError.unauthorized {
    // Handle unauthorized (401)
} catch APIError.notFound {
    // Handle not found (404)
} catch APIError.retry(let after) {
    // Handle retry with delay (429 with retry-after header)
} catch {
    // Handle other errors (including custom API-specific errors from your ResponseHandler)
}
```

See [TraktKit](https://github.com/MaxHasADHD/TraktKit) for a complete example of building an API client with SwiftAPIClient.

## License

This library is available under the MIT license. See the LICENSE file for more info.
