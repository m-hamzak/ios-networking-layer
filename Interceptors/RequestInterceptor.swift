//
//  RequestInterceptor.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - RequestInterceptor Protocol
//
// An interceptor sits between the HTTPClient and the URLSession.
// It receives a URLRequest, can modify it, and returns the modified request.
//
// Use cases:
//   - Inject Authorization headers
//   - Add request IDs for tracing (useful in banking audit logs)
//   - Add device fingerprint headers
//   - Log outgoing requests
//   - Add language headers (Accept-Language: ar, en)
//
// Interceptors are applied in the order they are passed to HTTPClient.
// The output of interceptor N is the input of interceptor N+1.

public protocol RequestInterceptor {
    func intercept(_ request: URLRequest) async throws -> URLRequest
}

// MARK: - AuthorizationInterceptor
//
// Reads the current access token from SecureTokenVault and injects it
// as a Bearer token in the Authorization header.
//
// This interceptor runs on every request. The TokenRefreshInterceptor
// (applied after this one) handles the case where the token is expired.

public final class AuthorizationInterceptor: RequestInterceptor {

    public init() {}

    public func intercept(_ request: URLRequest) async throws -> URLRequest {
        var modified = request

        // Retrieve token without requiring biometric — the interceptor runs silently.
        // Biometric is only required for sensitive actions (transfers, balance view).
        if let token = try? await SecureTokenVault.shared.accessToken(requireBiometric: false) {
            modified.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return modified
    }
}

// MARK: - LanguageInterceptor
//
// Injects the current app language into every request via Accept-Language header.
// Banking backend APIs often use this to return localised error messages.

public final class LanguageInterceptor: RequestInterceptor {

    public init() {}

    public func intercept(_ request: URLRequest) async throws -> URLRequest {
        var modified = request
        // e.g. "ar, en;q=0.9"
        let language = LocalizationManager.shared.currentLanguage.rawValue
        modified.setValue("\(language), en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return modified
    }
}

// MARK: - RequestIDInterceptor
//
// Adds a unique X-Request-ID header to every request.
// Critical for banking apps — allows support teams to trace
// a specific request in server logs using the ID from the client log.

public final class RequestIDInterceptor: RequestInterceptor {

    public init() {}

    public func intercept(_ request: URLRequest) async throws -> URLRequest {
        var modified = request
        modified.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return modified
    }
}

// MARK: - DeviceInfoInterceptor
//
// Injects device metadata into request headers.
// Common in banking apps for fraud detection and session tracking.

public final class DeviceInfoInterceptor: RequestInterceptor {

    public init() {}

    public func intercept(_ request: URLRequest) async throws -> URLRequest {
        var modified = request

        let device = UIDevice.current
        modified.setValue(device.systemVersion,             forHTTPHeaderField: "X-OS-Version")
        modified.setValue(device.model,                     forHTTPHeaderField: "X-Device-Model")
        modified.setValue(appVersion,                       forHTTPHeaderField: "X-App-Version")
        modified.setValue(Bundle.main.bundleIdentifier ?? "", forHTTPHeaderField: "X-Bundle-ID")

        return modified
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

import UIKit
