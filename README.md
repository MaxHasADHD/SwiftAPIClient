# SwiftAPIClient

A flexible, generic Swift package for building REST API clients with OAuth support, automatic retry handling, and customizable error handling.

## Features

- **Generic API Management**: Core `APIClient` that can be configured for any REST API
- **OAuth Authentication**: Built-in support for OAuth with keychain storage
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

let client = APIClient(
    configuration: configuration,
    authStorage: KeychainAuthentication(serviceName: "com.example.app")
)
```

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

### OAuth Flow

```swift
// 1. Store credentials after OAuth flow
let authState = AuthenticationState(
    accessToken: "access_token",
    refreshToken: "refresh_token",
    expiresAt: Date().addingTimeInterval(7200)
)

let keychain = KeychainAuthentication(serviceName: "com.example.app")
try await keychain.save(authState)

// 2. Update the cached state
client.updateCachedAuthState(authState)

// 3. Make authenticated requests
let request = try client.mutableRequest(
    forPath: "users/settings",
    isAuthorized: true,
    withHTTPMethod: .get
)
```

### Sign Out

```swift
await client.signOut()
```

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
