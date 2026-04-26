//
//  NetworkError.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - NetworkError
//
// A typed error enum that maps every possible networking failure to a clear,
// actionable case — no raw NSErrors or ambiguous string messages.
//
// Banking apps need precise error handling:
//   - 401 must trigger token refresh, not show a generic error
//   - No internet must show a specific offline state
//   - Server errors must be logged with status codes for support teams

public enum NetworkError: LocalizedError, Equatable {

    // MARK: - Connectivity

    /// Device has no internet connection. Show offline UI.
    case noInternetConnection

    /// The request timed out. Offer a retry.
    case timeout

    // MARK: - HTTP Status Errors

    /// 400 — Request was malformed. Log and report to the server team.
    case badRequest

    /// 401 — Token expired or invalid. Trigger token refresh flow.
    case unauthorized

    /// 403 — Authenticated but not permitted. Show access-denied message.
    case forbidden

    /// 404 — Resource does not exist.
    case notFound

    /// 409 — Conflict. Common in banking: duplicate transfer, concurrent edit.
    case conflict

    /// 422 — Validation error from the server. Carry the status code for display.
    case unprocessableEntity

    /// 429 — Rate limited. Back off and retry after the specified delay.
    case rateLimited(retryAfter: TimeInterval?)

    /// 5xx — Server-side failure. Carry the status code for logging.
    case serverError(statusCode: Int)

    // MARK: - Client-Side Errors

    /// The server returned data that could not be decoded into the expected type.
    case decodingError(Error)

    /// URLSession returned an error (e.g. SSL failure, cancelled).
    case requestFailed(Error)

    /// The server returned an unexpected or unhandled HTTP status code.
    case unexpectedStatusCode(Int)

    /// An unknown error occurred. Should be rare — most cases are covered above.
    case unknown

    // MARK: - Equatable

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.noInternetConnection, .noInternetConnection): return true
        case (.timeout, .timeout):                           return true
        case (.badRequest, .badRequest):                     return true
        case (.unauthorized, .unauthorized):                 return true
        case (.forbidden, .forbidden):                       return true
        case (.notFound, .notFound):                         return true
        case (.conflict, .conflict):                         return true
        case (.unprocessableEntity, .unprocessableEntity):   return true
        case (.unknown, .unknown):                           return true
        case (.serverError(let a), .serverError(let b)):     return a == b
        case (.unexpectedStatusCode(let a), .unexpectedStatusCode(let b)): return a == b
        default: return false
        }
    }

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .noInternetConnection:
            return "No internet connection. Please check your network and try again."
        case .timeout:
            return "The request timed out. Please try again."
        case .badRequest:
            return "Invalid request. Please check your input."
        case .unauthorized:
            return "Your session has expired. Please log in again."
        case .forbidden:
            return "You don't have permission to perform this action."
        case .notFound:
            return "The requested resource was not found."
        case .conflict:
            return "A conflict occurred. Please refresh and try again."
        case .unprocessableEntity:
            return "The request could not be processed. Please check your input."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Too many requests. Please wait \(Int(seconds)) seconds and try again."
            }
            return "Too many requests. Please wait before trying again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .decodingError(let error):
            return "Failed to process the server response: \(error.localizedDescription)"
        case .requestFailed(let error):
            return "Request failed: \(error.localizedDescription)"
        case .unexpectedStatusCode(let code):
            return "Unexpected response from server (status \(code))."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }

    // MARK: - Recovery Suggestion

    public var recoverySuggestion: String? {
        switch self {
        case .noInternetConnection: return "Check your Wi-Fi or mobile data."
        case .timeout:              return "Try again on a stronger connection."
        case .unauthorized:         return "Log in again to continue."
        case .rateLimited:          return "Wait a moment before retrying."
        case .serverError:          return "If this persists, contact support."
        default:                    return nil
        }
    }

    // MARK: - Should Retry

    /// Whether this error type is worth retrying automatically.
    var isRetryable: Bool {
        switch self {
        case .timeout, .noInternetConnection, .serverError:
            return true
        default:
            return false
        }
    }

    // MARK: - HTTP Status Code Mapping

    /// Maps an HTTP status code to the appropriate NetworkError.
    static func from(statusCode: Int, headers: [AnyHashable: Any]? = nil) -> NetworkError {
        switch statusCode {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 422: return .unprocessableEntity
        case 429:
            let retryAfter = (headers?["Retry-After"] as? String).flatMap { TimeInterval($0) }
            return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .serverError(statusCode: statusCode)
        default:        return .unexpectedStatusCode(statusCode)
        }
    }

    /// Maps a URLError to the appropriate NetworkError.
    static func from(urlError: URLError) -> NetworkError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .noInternetConnection
        case .timedOut:
            return .timeout
        case .cancelled:
            return .requestFailed(urlError)
        default:
            return .requestFailed(urlError)
        }
    }
}
