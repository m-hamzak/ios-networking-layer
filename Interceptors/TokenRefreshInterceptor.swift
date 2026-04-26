//
//  TokenRefreshInterceptor.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - TokenRefreshInterceptor
//
// Handles silent token refresh when a 401 Unauthorized response is received.
//
// The flow:
//   1. HTTPClient receives a 401 and throws NetworkError.unauthorized
//   2. TokenRefreshInterceptor catches it (via the response interceptor hook)
//   3. It calls the refresh endpoint using the stored refresh token
//   4. Stores the new access + refresh tokens in SecureTokenVault
//   5. Retries the original request with the new access token
//   6. If refresh fails (refresh token expired) → fires onSessionExpired
//
// CRITICAL: Multiple concurrent requests can all receive a 401 simultaneously.
// Without protection, all of them would attempt a token refresh concurrently,
// flooding the auth server and causing race conditions.
//
// Solution: Use a Swift actor to serialise the refresh operation.
// Only the first request to hit 401 performs the refresh.
// All others wait and then reuse the new token.

// MARK: - TokenRefreshActor
//
// The actor guarantees that only one refresh happens at a time.
// Concurrent callers suspend at the `await` and resume once the refresh completes.

actor TokenRefreshActor {

    private var isRefreshing = false
    private var refreshTask: Task<Void, Error>?

    /// Ensures only one token refresh runs at a time.
    /// If a refresh is already in progress, waits for it to complete before returning.
    func refresh(using refresher: @escaping () async throws -> Void) async throws {
        // If already refreshing, wait for the in-progress task
        if let existing = refreshTask {
            return try await existing.value
        }

        // Start a new refresh
        let task = Task<Void, Error> {
            defer { refreshTask = nil }
            try await refresher()
        }

        refreshTask = task
        return try await task.value
    }
}

// MARK: - TokenRefreshInterceptor

public final class TokenRefreshInterceptor {

    // MARK: - Dependencies

    private let authEndpoint: AuthEndpoint
    private let vault: SecureTokenVault
    private let actor  = TokenRefreshActor()

    /// Called when the refresh token itself is expired — the user must log in again.
    public var onSessionExpired: (() -> Void)?

    // MARK: - Init

    public init(
        authEndpoint: AuthEndpoint = DefaultAuthEndpoint(),
        vault: SecureTokenVault = .shared
    ) {
        self.authEndpoint = authEndpoint
        self.vault        = vault
    }

    // MARK: - Response Handling
    //
    // Called by HTTPClient after receiving a 401.
    // Performs the refresh and returns the new access token to use in the retry.

    func handleUnauthorized(originalRequest: URLRequest) async throws -> String {
        try await actor.refresh {
            try await self.performRefresh()
        }

        // After refresh, return the new access token for the retry
        return try await vault.accessToken(requireBiometric: false)
    }

    // MARK: - Refresh

    private func performRefresh() async throws {
        guard let refreshToken = try? vault.refreshToken() else {
            // No refresh token — session is completely expired
            await fireSessionExpired()
            throw NetworkError.unauthorized
        }

        let session = URLSession(configuration: .ephemeral)  // Fresh session for auth requests

        do {
            let request  = try authEndpoint.refreshRequest(using: refreshToken)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.unknown
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // Refresh token is also expired — force logout
                vault.clearAll()
                await fireSessionExpired()
                throw NetworkError.unauthorized
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.from(statusCode: httpResponse.statusCode)
            }

            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            try vault.store(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken)

        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }

    @MainActor
    private func fireSessionExpired() {
        onSessionExpired?()
    }
}

// MARK: - HTTPClient Extension — 401 Retry Hook
//
// Extend HTTPClient to support the retry-on-401 pattern.
// When a request fails with .unauthorized, the client calls the refresh interceptor,
// gets a new token, and retries the original request once.

extension HTTPClient {

    func sendWithRefresh<T: Decodable>(
        _ endpoint: APIEndpoint,
        refreshInterceptor: TokenRefreshInterceptor
    ) async throws -> T {
        do {
            return try await send(endpoint)
        } catch NetworkError.unauthorized {
            let request = try endpoint.asURLRequest()
            let newToken = try await refreshInterceptor.handleUnauthorized(originalRequest: request)

            // Rebuild and retry with new token
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: retryRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.unauthorized
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy  = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        }
    }
}

// MARK: - Supporting Types

/// The token response from your auth/refresh endpoint.
struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int?  // seconds until access token expires
}

/// Protocol for the auth endpoint — makes it testable and swappable.
public protocol AuthEndpoint {
    func refreshRequest(using refreshToken: String) throws -> URLRequest
}

/// Default implementation — replace the URL with your actual refresh endpoint.
public struct DefaultAuthEndpoint: AuthEndpoint {

    public init() {}

    public func refreshRequest(using refreshToken: String) throws -> URLRequest {
        let url = Environment.baseURL.appendingPathComponent("/api/v1/auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["refresh_token": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }
}
