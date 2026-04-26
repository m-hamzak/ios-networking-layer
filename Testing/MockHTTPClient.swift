//
//  MockHTTPClient.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation

// MARK: - MockHTTPClient
//
// A test double for HTTPClientProtocol that lets you:
//   - Stub responses for specific endpoint types
//   - Track which endpoints were called and how many times
//   - Inject errors to test error-handling paths
//   - Simulate delays to test loading states
//
// Because HTTPClient is hidden behind HTTPClientProtocol, you can inject
// MockHTTPClient into any ViewModel or UseCase for unit testing
// without making a single real network request.
//
// Usage in XCTest:
//   let mock = MockHTTPClient()
//   mock.stub(AccountsEndpoint.getAccounts, with: [account1, account2])
//   let viewModel = AccountsViewModel(client: mock)
//   await viewModel.loadAccounts()
//   XCTAssertEqual(viewModel.accounts.count, 2)
//   XCTAssertEqual(mock.callCount(for: AccountsEndpoint.getAccounts), 1)

// MARK: - MockHTTPClient

public final class MockHTTPClient: HTTPClientProtocol {

    // MARK: - Response Registry

    // Keyed by the endpoint's path — flexible enough for most test scenarios.
    private var stubs: [String: Any] = [:]
    private var errors: [String: NetworkError] = [:]
    private var delays: [String: TimeInterval] = [:]

    // MARK: - Call Tracking

    private var callCounts: [String: Int] = [:]
    private var lastRequests: [String: APIEndpoint] = [:]

    // MARK: - Global Fallback

    /// If set, all un-stubbed requests throw this error.
    public var defaultError: NetworkError?

    /// If set, all requests are delayed by this many seconds.
    public var globalDelay: TimeInterval = 0

    // MARK: - Stubbing

    /// Stub a successful response for an endpoint.
    public func stub<T: Encodable>(_ endpoint: APIEndpoint, with response: T) {
        stubs[endpoint.path] = response
    }

    /// Stub an array response for an endpoint.
    public func stub<T: Encodable>(_ endpoint: APIEndpoint, with response: [T]) {
        stubs[endpoint.path] = response
    }

    /// Stub a failure for an endpoint.
    public func stub(_ endpoint: APIEndpoint, withError error: NetworkError) {
        errors[endpoint.path] = error
    }

    /// Add a simulated delay for an endpoint (useful for testing loading states).
    public func stub(_ endpoint: APIEndpoint, delay: TimeInterval) {
        delays[endpoint.path] = delay
    }

    /// Remove all stubs — useful in tearDown().
    public func reset() {
        stubs.removeAll()
        errors.removeAll()
        delays.removeAll()
        callCounts.removeAll()
        lastRequests.removeAll()
    }

    // MARK: - HTTPClientProtocol

    public func send<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        track(endpoint)

        await simulateDelay(for: endpoint)

        if let error = errors[endpoint.path] {
            throw error
        }

        if let defaultError {
            throw defaultError
        }

        guard let stub = stubs[endpoint.path] else {
            fatalError("""
            MockHTTPClient: No stub registered for path '\(endpoint.path)'.
            Register a stub with mock.stub(endpoint, with: response) before calling this endpoint.
            """)
        }

        // Re-encode and decode to simulate the real JSONDecoder behaviour.
        // This catches encoding mismatches in your models during tests.
        return try reEncode(stub)
    }

    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        track(endpoint)

        await simulateDelay(for: endpoint)

        if let error = errors[endpoint.path] {
            throw error
        }

        if let defaultError {
            throw defaultError
        }
    }

    // MARK: - Call Inspection

    /// Returns the number of times an endpoint was called.
    public func callCount(for endpoint: APIEndpoint) -> Int {
        callCounts[endpoint.path] ?? 0
    }

    /// Returns true if the endpoint was called at least once.
    public func wasCalled(_ endpoint: APIEndpoint) -> Bool {
        callCount(for: endpoint) > 0
    }

    /// Returns the last endpoint instance that was passed for a given path.
    public func lastRequest(for endpoint: APIEndpoint) -> APIEndpoint? {
        lastRequests[endpoint.path]
    }

    // MARK: - Private Helpers

    private func track(_ endpoint: APIEndpoint) {
        callCounts[endpoint.path, default: 0] += 1
        lastRequests[endpoint.path] = endpoint
    }

    private func simulateDelay(for endpoint: APIEndpoint) async {
        let delay = delays[endpoint.path] ?? globalDelay
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func reEncode<T: Decodable>(_ value: Any) throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy  = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy  = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        guard let encodable = value as? Encodable else {
            throw NetworkError.decodingError(
                NSError(domain: "MockHTTPClient", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Stub value is not Encodable"
                ])
            )
        }

        let data = try encoder.encode(AnyEncodable(encodable))
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Example XCTest Usage

/*

import XCTest

class AccountsViewModelTests: XCTestCase {

    var mock: MockHTTPClient!
    var viewModel: AccountsViewModel!

    override func setUp() {
        super.setUp()
        mock = MockHTTPClient()
        viewModel = AccountsViewModel(client: mock)
    }

    override func tearDown() {
        mock.reset()
        super.tearDown()
    }

    // Test: successful accounts load
    func testLoadAccountsSuccess() async throws {
        let stubAccounts = [
            Account(id: "1", name: "Current Account", balance: 1500.0, currency: "BHD", iban: "BH29BMAG1299123456BH00"),
            Account(id: "2", name: "Savings Account",  balance: 5000.0, currency: "BHD", iban: "BH29BMAG1299123456BH01")
        ]

        mock.stub(AccountsEndpoint.getAccounts, with: stubAccounts)

        await viewModel.loadAccounts()

        XCTAssertEqual(viewModel.accounts.count, 2)
        XCTAssertEqual(viewModel.accounts.first?.name, "Current Account")
        XCTAssertNil(viewModel.error)
        XCTAssertTrue(mock.wasCalled(AccountsEndpoint.getAccounts))
    }

    // Test: network error shows correct error state
    func testLoadAccountsNoInternet() async throws {
        mock.stub(AccountsEndpoint.getAccounts, withError: .noInternetConnection)

        await viewModel.loadAccounts()

        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertEqual(viewModel.error, .noInternetConnection)
    }

    // Test: loading state is shown during fetch
    func testLoadingStateShownDuringFetch() async throws {
        mock.stub(AccountsEndpoint.getAccounts, delay: 0.5)
        mock.stub(AccountsEndpoint.getAccounts, with: [Account]())

        XCTAssertFalse(viewModel.isLoading)
        let task = Task { await viewModel.loadAccounts() }
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        XCTAssertTrue(viewModel.isLoading)
        await task.value
        XCTAssertFalse(viewModel.isLoading)
    }

    // Test: endpoint called exactly once
    func testEndpointCalledOnce() async {
        mock.stub(AccountsEndpoint.getAccounts, with: [Account]())
        await viewModel.loadAccounts()
        XCTAssertEqual(mock.callCount(for: AccountsEndpoint.getAccounts), 1)
    }
}

*/
