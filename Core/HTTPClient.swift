//
//  HTTPClient.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - HTTPClientProtocol
//
// Define the contract as a protocol so the real client can be swapped
// for a mock in tests without changing any call sites.

public protocol HTTPClientProtocol {
    func send<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T
    func sendVoid(_ endpoint: APIEndpoint) async throws
}

// MARK: - HTTPClient
//
// The core URLSession wrapper. Responsibilities:
//   1. Build the URLRequest from an APIEndpoint
//   2. Pass the request through the interceptor chain (auth headers, logging)
//   3. Execute the request via URLSession
//   4. Map HTTP status codes to NetworkError
//   5. Decode the response body into the expected type
//   6. Apply retry policy on retryable errors
//
// HTTPClient knows nothing about specific endpoints, authentication details,
// or business logic — those live in the interceptors and endpoint definitions.

public final class HTTPClient: HTTPClientProtocol {

    // MARK: - Dependencies

    private let session: URLSession
    private let interceptors: [RequestInterceptor]
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder

    // MARK: - Init

    public init(
        session: URLSession = .shared,
        interceptors: [RequestInterceptor] = [],
        retryPolicy: RetryPolicy = .default
    ) {
        self.session      = session
        self.interceptors = interceptors
        self.retryPolicy  = retryPolicy

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy  = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Send (with response body)

    /// Sends a request and decodes the response into type T.
    public func send<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        try await performWithRetry(endpoint: endpoint, attempt: 1) {
            let request  = try await self.buildRequest(from: endpoint)
            let (data, response) = try await self.execute(request)
            try self.validate(response: response, data: data)
            return try self.decode(T.self, from: data)
        }
    }

    /// Sends a request that returns no response body (e.g. DELETE, logout).
    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        try await performWithRetry(endpoint: endpoint, attempt: 1) {
            let request = try await self.buildRequest(from: endpoint)
            let (data, response) = try await self.execute(request)
            try self.validate(response: response, data: data)
        }
    }

    // MARK: - Request Building

    private func buildRequest(from endpoint: APIEndpoint) async throws -> URLRequest {
        var request = try endpoint.asURLRequest()

        // Pass through all interceptors in order
        for interceptor in interceptors {
            request = try await interceptor.intercept(request)
        }

        log(request)
        return request
    }

    // MARK: - Execution

    private func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw NetworkError.from(urlError: urlError)
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }

    // MARK: - Validation

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown
        }

        log(httpResponse, data: data)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.from(
                statusCode: httpResponse.statusCode,
                headers: httpResponse.allHeaderFields
            )
        }
    }

    // MARK: - Decoding

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }

    // MARK: - Retry

    private func performWithRetry<T>(
        endpoint: APIEndpoint,
        attempt: Int,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as NetworkError {
            if retryPolicy.shouldRetry(error: error, attempt: attempt) {
                let delay = retryPolicy.delay(for: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await performWithRetry(
                    endpoint: endpoint,
                    attempt: attempt + 1,
                    operation: operation
                )
            }
            throw error
        }
    }

    // MARK: - Logging

    private func log(_ request: URLRequest) {
        #if DEBUG
        print("📤 [\(request.httpMethod ?? "?")] \(request.url?.absoluteString ?? "unknown URL")")
        if let headers = request.allHTTPHeaderFields {
            print("   Headers: \(headers.filter { $0.key != "Authorization" })")  // Never log auth tokens
        }
        if let body = request.httpBody, let json = String(data: body, encoding: .utf8) {
            print("   Body: \(json)")
        }
        #endif
    }

    private func log(_ response: HTTPURLResponse, data: Data) {
        #if DEBUG
        let status  = response.statusCode
        let emoji   = (200...299).contains(status) ? "✅" : "❌"
        print("\(emoji) [\(status)] \(response.url?.absoluteString ?? "unknown URL")")
        if let json = String(data: data, encoding: .utf8) {
            print("   Response: \(json.prefix(500))")  // Truncate long responses
        }
        #endif
    }
}

// MARK: - Convenience Factory
//
// Pre-configured HTTPClient for common banking app setups.

extension HTTPClient {

    /// Standard authenticated client — injects Bearer token and handles 401 refresh.
    static func authenticated(
        tokenRefresher: TokenRefreshInterceptor,
        additionalInterceptors: [RequestInterceptor] = []
    ) -> HTTPClient {
        HTTPClient(
            interceptors: [AuthorizationInterceptor()] + additionalInterceptors + [tokenRefresher],
            retryPolicy: .banking
        )
    }

    /// Unauthenticated client — for login, forgot password, public endpoints.
    static var unauthenticated: HTTPClient {
        HTTPClient(retryPolicy: .default)
    }
}
