//
//  APIEndpoint.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - HTTPMethod

public enum HTTPMethod: String {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"
}

// MARK: - APIEndpoint Protocol
//
// Defines every piece of information needed to construct a URLRequest.
// Each feature module defines its own endpoints by conforming to this protocol.
//
// Benefits:
//   - All endpoint details are in one place — easy to audit and test
//   - No magic strings scattered across the codebase
//   - HTTPClient stays generic — it knows nothing about specific endpoints
//   - Swap base URLs per environment (dev/staging/prod) from one place

public protocol APIEndpoint {

    /// The base URL for this endpoint. Usually comes from a config/environment file.
    var baseURL: URL { get }

    /// The path component. Example: "/api/v1/accounts"
    var path: String { get }

    /// HTTP method for this request.
    var method: HTTPMethod { get }

    /// Headers specific to this endpoint. Auth headers are added by the interceptor — don't add them here.
    var headers: [String: String] { get }

    /// URL query parameters. Only used for GET requests typically.
    var queryItems: [URLQueryItem]? { get }

    /// The request body. Returns nil for GET/DELETE requests.
    var body: Encodable? { get }
}

// MARK: - Default Implementations

public extension APIEndpoint {

    var headers: [String: String] {
        ["Content-Type": "application/json",
         "Accept":       "application/json"]
    }

    var queryItems: [URLQueryItem]? { nil }
    var body: Encodable? { nil }

    // MARK: - URLRequest Builder

    func asURLRequest() throws -> URLRequest {
        // Build URL with path and query items
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true) else {
            throw NetworkError.badRequest
        }

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NetworkError.badRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        // Apply headers
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // Encode body
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy  = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        return request
    }
}

// MARK: - AnyEncodable
// Bridges the existential `Encodable` to a concrete type the JSONEncoder can handle.

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: Encodable) {
        _encode = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Example: Banking Endpoints
//
// Each feature module defines an enum conforming to APIEndpoint.
// The HTTPClient never needs to know about these — it only speaks APIEndpoint.

enum Environment {
    static let baseURL = URL(string: "https://api.bank.com")!  // Replace with your actual base URL
}

enum AccountsEndpoint: APIEndpoint {

    case getAccounts
    case getAccount(id: String)
    case getTransactions(accountId: String, page: Int, limit: Int)
    case transfer(fromId: String, toId: String, amount: Double, currency: String)

    var baseURL: URL { Environment.baseURL }

    var path: String {
        switch self {
        case .getAccounts:                    return "/api/v1/accounts"
        case .getAccount(let id):             return "/api/v1/accounts/\(id)"
        case .getTransactions(let id, _, _):  return "/api/v1/accounts/\(id)/transactions"
        case .transfer:                       return "/api/v1/transfers"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .getAccounts, .getAccount, .getTransactions: return .get
        case .transfer:                                    return .post
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .getTransactions(_, let page, let limit):
            return [
                URLQueryItem(name: "page",  value: "\(page)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        default: return nil
        }
    }

    var body: Encodable? {
        switch self {
        case .transfer(let fromId, let toId, let amount, let currency):
            return TransferRequest(fromAccountId: fromId, toAccountId: toId, amount: amount, currency: currency)
        default: return nil
        }
    }
}

// Request/Response models used by AccountsEndpoint

struct TransferRequest: Encodable {
    let fromAccountId: String
    let toAccountId: String
    let amount: Double
    let currency: String
}

struct Account: Decodable {
    let id: String
    let name: String
    let balance: Double
    let currency: String
    let iban: String
}

struct Transaction: Decodable {
    let id: String
    let description: String
    let amount: Double
    let currency: String
    let date: Date
    let isCredit: Bool
}

struct TransferResponse: Decodable {
    let transactionId: String
    let status: String
    let timestamp: Date
}

struct PaginatedResponse<T: Decodable>: Decodable {
    let data: [T]
    let page: Int
    let totalPages: Int
    let totalCount: Int
}
