<h1 align="center">iOS Networking Layer</h1>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9-F54A2A?style=flat&logo=swift&logoColor=white"/></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/iOS-15%2B-lightgrey?style=flat&logo=apple&logoColor=white"/></a>
  <img src="https://img.shields.io/badge/async%2Fawait-Native-6A0DAD?style=flat"/>
  <img src="https://img.shields.io/badge/Zero%20Dependencies-✓-green?style=flat"/>
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat"/>
</p>

<p align="center">
  A production-ready Swift networking layer — protocol-driven, async/await native, zero third-party dependencies.<br/>
  Typed errors, automatic token refresh with concurrent-request protection, exponential backoff, reachability monitoring, and a full mock client for unit testing.<br/>
  Built from real-world GCC banking app development.
</p>

---

## Why this repo?

Most networking tutorials show you how to make a URLSession call. Production banking apps need much more:

- A 401 that arrives while 6 requests are in-flight must trigger exactly **one** token refresh — not six
- Retry logic must use **exponential backoff with jitter** to avoid hammering a recovering server
- Transfer endpoints must **never retry automatically** — a 5xx may mean the server already processed it
- Every error must be **typed** so ViewModels can react precisely (show offline UI vs. show login vs. show generic error)
- Every component must be **testable in isolation** — no URLSession calls in unit tests

This layer solves all of that. Zero Alamofire, zero Moya — pure Swift.

---

## Structure

```
ios-networking-layer/
├── Core/
│   ├── NetworkError.swift            → Typed error enum — every HTTP and connectivity failure
│   ├── APIEndpoint.swift             → Protocol for defining endpoints + URLRequest builder
│   └── HTTPClient.swift             → URLSession wrapper — async/await, decoding, retry, logging
├── Interceptors/
│   ├── RequestInterceptor.swift      → Protocol + Auth, Language, RequestID, DeviceInfo interceptors
│   └── TokenRefreshInterceptor.swift → 401 handling, silent refresh, actor-based concurrency protection
├── Retry/
│   └── RetryPolicy.swift             → Configurable retry: immediate, constant, exponential, jitter
├── Monitoring/
│   └── NetworkMonitor.swift          → NWPathMonitor reachability — SwiftUI + UIKit
└── Testing/
    └── MockHTTPClient.swift          → Stub responses, error injection, call tracking, delay simulation
```

---

## Core

### `NetworkError.swift`
A typed error enum that maps every possible failure to a clear, actionable case.

| Case | HTTP Status | When to use |
|---|---|---|
| `.noInternetConnection` | — | NWPath status != satisfied |
| `.timeout` | — | URLError.timedOut |
| `.badRequest` | 400 | Malformed request |
| `.unauthorized` | 401 | Token expired → triggers refresh |
| `.forbidden` | 403 | No permission |
| `.notFound` | 404 | Resource missing |
| `.conflict` | 409 | Duplicate transfer, concurrent edit |
| `.unprocessableEntity` | 422 | Validation failure |
| `.rateLimited(retryAfter:)` | 429 | Carries Retry-After seconds |
| `.serverError(statusCode:)` | 5xx | Server failure |
| `.decodingError(Error)` | 2xx | Response didn't match model |

Every case has `errorDescription` and `recoverySuggestion` for direct display in UI.

---

### `APIEndpoint.swift`
Protocol-based endpoint definition — inspired by Moya, without the dependency.

```swift
enum AccountsEndpoint: APIEndpoint {
    case getAccounts
    case getTransactions(accountId: String, page: Int, limit: Int)
    case transfer(fromId: String, toId: String, amount: Double, currency: String)

    var path: String { ... }
    var method: HTTPMethod { ... }
    var queryItems: [URLQueryItem]? { ... }
    var body: Encodable? { ... }
}
```

Default implementations for `headers`, `queryItems`, and `body` — only override what differs. The `asURLRequest()` extension builds the complete `URLRequest` including JSON encoding with snake_case keys and ISO 8601 dates.

---

### `HTTPClient.swift`
The core URLSession wrapper.

```swift
// Authenticated client — injects token, handles 401 refresh
let client = HTTPClient.authenticated(tokenRefresher: refreshInterceptor)

// Make a request
let accounts: [Account] = try await client.send(AccountsEndpoint.getAccounts)

// Unauthenticated — for login / public endpoints
let client = HTTPClient.unauthenticated
```

- Passes requests through the interceptor chain in order
- Maps HTTP status codes and URLErrors to `NetworkError`
- Decodes with `convertFromSnakeCase` + `.iso8601` date strategy
- Retries automatically based on `RetryPolicy`
- Logs requests and responses in `#if DEBUG` — never logs Authorization headers

---

## Interceptors

### `RequestInterceptor.swift`
Four ready-to-use interceptors:

**`AuthorizationInterceptor`** — Reads the access token from `SecureTokenVault` and injects `Authorization: Bearer <token>` into every request.

**`LanguageInterceptor`** — Adds `Accept-Language: ar, en;q=0.9` so the backend returns localised error messages. Critical for GCC banking apps.

**`RequestIDInterceptor`** — Adds a unique `X-Request-ID` UUID header. Allows support teams to find a specific request in server logs from the client's debug output.

**`DeviceInfoInterceptor`** — Adds `X-OS-Version`, `X-Device-Model`, `X-App-Version` headers. Used for fraud detection and session tracking in banking apps.

---

### `TokenRefreshInterceptor.swift`
Silent token refresh with actor-based concurrent request protection.

**The problem:** If 6 requests are in-flight and the token expires, all 6 get a 401 simultaneously. Without protection, all 6 try to refresh — the first succeeds, the rest fail because the refresh token is single-use.

**The solution:** A Swift `actor` serialises the refresh. Only the first caller performs the actual refresh. The other 5 `await` the same `Task` and resume with the new token once it completes.

```
Request 1 → 401 → starts refresh  ─────────────────────┐
Request 2 → 401 → awaits actor    ─ (suspended)         │  refresh completes
Request 3 → 401 → awaits actor    ─ (suspended)         │
                                                        ↓
                                  All 3 retry with new token
```

If the refresh token itself is expired, `onSessionExpired` fires on the main thread — wire this to your login flow.

---

## Retry

### `RetryPolicy.swift`
Four delay strategies and four preset policies:

| Policy | Max Attempts | Strategy | Use For |
|---|---|---|---|
| `.default` | 3 | Exponential jitter (1s base, 10s max) | Most GET requests |
| `.banking` | 2 | Exponential jitter (2s base, 8s max) | Transfers, payments — never retries 5xx |
| `.aggressive` | 5 | Exponential jitter (0.5s base, 15s max) | Read-only data (exchange rates, etc.) |
| `.none` | 1 | Immediate | User-initiated actions needing immediate feedback |

**Important:** The `.banking` preset deliberately excludes `.serverError` from retryable errors. A 5xx on a payment endpoint may mean the server already processed the request. Retrying could cause a duplicate transfer.

---

## Monitoring

### `NetworkMonitor.swift`
NWPathMonitor wrapper with SwiftUI and UIKit support.

```swift
// SwiftUI: show offline banner on any screen
ContentView()
    .showOfflineBanner()

// SwiftUI: disable a button when offline
Button("Transfer") { ... }
    .requiresNetwork()

// UIKit: observe connectivity changes
NotificationCenter.default.addObserver(self,
    selector: #selector(connectivityChanged(_:)),
    name: .connectivityDidChange,
    object: nil)

// Guard before sensitive operations
try NetworkMonitor.shared.assertConnected()
```

Publishes: `isConnected`, `connectionType` (wifi/cellular/ethernet), `isExpensive` (cellular/hotspot), `isConstrained` (Low Data Mode).

---

## Testing

### `MockHTTPClient.swift`
Full mock implementation of `HTTPClientProtocol` for unit tests.

```swift
// Stub a success
mock.stub(AccountsEndpoint.getAccounts, with: [account1, account2])

// Stub an error
mock.stub(AccountsEndpoint.transfer(...), withError: .noInternetConnection)

// Simulate loading delay
mock.stub(AccountsEndpoint.getAccounts, delay: 0.5)

// Inspect calls
XCTAssertEqual(mock.callCount(for: AccountsEndpoint.getAccounts), 1)
XCTAssertTrue(mock.wasCalled(AccountsEndpoint.getAccounts))
```

Re-encodes and re-decodes stub values through the real JSONEncoder/JSONDecoder pipeline — catches model mismatches during tests.

---

## Wiring it together

```swift
// AppDelegate or composition root

let refreshInterceptor = TokenRefreshInterceptor()
refreshInterceptor.onSessionExpired = {
    // Navigate to login
    AppCoordinator.shared.showLogin()
}

let client = HTTPClient.authenticated(
    tokenRefresher: refreshInterceptor,
    additionalInterceptors: [
        LanguageInterceptor(),
        RequestIDInterceptor(),
        DeviceInfoInterceptor()
    ]
)

// NetworkMonitor
NetworkMonitor.shared.startMonitoring()

// Inject client into your repositories / use cases
let accountsRepo = AccountsRepository(client: client)
```

---

## Design decisions

**Why no Alamofire or Moya?** URLSession with async/await is expressive enough for production use. Third-party networking libraries add maintenance overhead and version lock-in — a real concern in long-lived banking apps.

**Why a protocol for HTTPClient?** So `MockHTTPClient` can replace it in tests. Every ViewModel or Repository that depends on `HTTPClientProtocol` is fully testable without mocking URLSession internals.

**Why an actor for token refresh?** Swift actors are the right tool for serialising concurrent access to shared mutable state. The alternative — using `DispatchSemaphore` or a flag — is error-prone under async/await and can cause deadlocks.

**Why separate retry policies per endpoint type?** A GET request on an exchange rates screen is safe to retry 5 times. A POST to a transfer endpoint is not. One-size-fits-all retry logic is a bug waiting to happen in financial apps.

---

## Author

**Muhammad Hamza Khalid** — Senior Mobile Engineer · iOS · Swift · SwiftUI · GCC Banking

[GitHub](https://github.com/m-hamzak) · [LinkedIn](https://linkedin.com/in/m-hamzak) · [Medium](https://medium.com/@m-hamzak)
