//
//  RetryPolicy.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - RetryPolicy
//
// Configurable retry behaviour for failed network requests.
//
// In banking apps, retrying blindly is dangerous:
//   - Never retry POST/PUT/DELETE without idempotency keys (could cause duplicate transfers)
//   - Only retry on transient errors: timeout, no internet, 5xx server errors
//   - Use exponential backoff with jitter to avoid thundering-herd on server recovery
//
// This policy is applied inside HTTPClient.performWithRetry().

public struct RetryPolicy {

    // MARK: - Delay Strategy

    public enum DelayStrategy {
        /// Retry immediately with no delay.
        case immediate

        /// Retry after a fixed delay every time.
        case constant(seconds: TimeInterval)

        /// Retry after an exponentially increasing delay: base * 2^attempt
        case exponential(base: TimeInterval)

        /// Exponential backoff with random jitter to spread out retry storms.
        /// This is the recommended strategy for production banking apps.
        case exponentialJitter(base: TimeInterval, maxDelay: TimeInterval)

        func delay(for attempt: Int) -> TimeInterval {
            switch self {
            case .immediate:
                return 0

            case .constant(let seconds):
                return seconds

            case .exponential(let base):
                return base * pow(2.0, Double(attempt - 1))

            case .exponentialJitter(let base, let maxDelay):
                let exponential = base * pow(2.0, Double(attempt - 1))
                let jitter      = Double.random(in: 0...(exponential * 0.5))  // up to 50% jitter
                return min(exponential + jitter, maxDelay)
            }
        }
    }

    // MARK: - Configuration

    /// Maximum number of retry attempts. The initial request is attempt 1.
    public let maxAttempts: Int

    /// The delay strategy between retry attempts.
    public let strategy: DelayStrategy

    /// The set of errors that are eligible for retry.
    /// Defaults to transient errors only.
    public let retryableErrors: Set<NetworkErrorType>

    // MARK: - Init

    public init(
        maxAttempts: Int,
        strategy: DelayStrategy,
        retryableErrors: Set<NetworkErrorType> = NetworkErrorType.transient
    ) {
        self.maxAttempts     = maxAttempts
        self.strategy        = strategy
        self.retryableErrors = retryableErrors
    }

    // MARK: - Decision

    /// Returns true if the error should be retried on the given attempt number.
    public func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        return retryableErrors.contains(NetworkErrorType(from: error))
    }

    /// Returns the delay in seconds before the next attempt.
    public func delay(for attempt: Int) -> TimeInterval {
        strategy.delay(for: attempt)
    }
}

// MARK: - NetworkErrorType
//
// A lightweight classification of NetworkError used in retry decisions.
// NetworkError has associated values (e.g. serverError(statusCode:)) that make
// it hard to store in a Set directly — this bridges that gap.

public enum NetworkErrorType: Hashable {
    case noInternetConnection
    case timeout
    case serverError
    case badRequest
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case other

    init(from error: NetworkError) {
        switch error {
        case .noInternetConnection:     self = .noInternetConnection
        case .timeout:                  self = .timeout
        case .serverError:              self = .serverError
        case .badRequest:               self = .badRequest
        case .unauthorized:             self = .unauthorized
        case .forbidden:                self = .forbidden
        case .notFound:                 self = .notFound
        case .rateLimited:              self = .rateLimited
        default:                        self = .other
        }
    }

    /// Errors that are safe to retry automatically — transient by nature.
    static let transient: Set<NetworkErrorType> = [
        .noInternetConnection,
        .timeout,
        .serverError
    ]
}

// MARK: - Preset Policies

public extension RetryPolicy {

    /// Sensible default: 3 attempts, exponential backoff with jitter, transient errors only.
    static let `default` = RetryPolicy(
        maxAttempts: 3,
        strategy:    .exponentialJitter(base: 1.0, maxDelay: 10.0)
    )

    /// No retries — for user-initiated actions where you want immediate feedback.
    static let none = RetryPolicy(
        maxAttempts: 1,
        strategy:    .immediate
    )

    /// Banking preset — conservative: 2 attempts, longer delays, no retry on 4xx.
    /// Use this for sensitive operations (transfers, payments) where duplicate
    /// execution must be avoided.
    static let banking = RetryPolicy(
        maxAttempts: 2,
        strategy:    .exponentialJitter(base: 2.0, maxDelay: 8.0),
        retryableErrors: [.noInternetConnection, .timeout]
        // Note: .serverError is excluded — a 5xx on a payment endpoint
        // may have already processed the request server-side.
    )

    /// Aggressive — for read-only data that is cheap to retry (e.g. pulling exchange rates).
    static let aggressive = RetryPolicy(
        maxAttempts: 5,
        strategy:    .exponentialJitter(base: 0.5, maxDelay: 15.0),
        retryableErrors: NetworkErrorType.transient
    )
}
