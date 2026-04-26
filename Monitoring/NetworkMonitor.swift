//
//  NetworkMonitor.swift
//  ios-networking-layer
//
//  Created by Hamza Khalid on 26/04/2026.
//

import Foundation
import Network
import SwiftUI
import Combine

// MARK: - NetworkMonitor
//
// Monitors internet connectivity in real time using NWPathMonitor.
// Publishes connection status changes so the UI can react immediately.
//
// In banking apps, the offline state is critical:
//   - Show an offline banner rather than letting requests fail silently
//   - Queue operations for when connectivity returns (e.g. pending transfers)
//   - Don't allow transfers or sensitive operations when offline
//
// Usage (SwiftUI):
//   @EnvironmentObject var monitor: NetworkMonitor
//   if !monitor.isConnected { OfflineBannerView() }
//
// Usage (UIKit):
//   NotificationCenter.default.addObserver(self, selector: #selector(connectivityChanged),
//       name: .connectivityDidChange, object: nil)

// MARK: - Notification Name

extension Notification.Name {
    static let connectivityDidChange = Notification.Name("NetworkMonitor.connectivityDidChange")
}

// MARK: - ConnectionType

public enum ConnectionType {
    case wifi
    case cellular
    case ethernet
    case unknown
    case none
}

// MARK: - NetworkMonitor

public final class NetworkMonitor: ObservableObject {

    // MARK: - Singleton

    public static let shared = NetworkMonitor()
    private init() {}

    // MARK: - Published State

    @Published public private(set) var isConnected: Bool = true
    @Published public private(set) var connectionType: ConnectionType = .unknown
    @Published public private(set) var isExpensive: Bool = false    // Cellular / hotspot
    @Published public private(set) var isConstrained: Bool = false  // Low Data Mode

    // MARK: - Private

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.app.network.monitor", qos: .background)
    private var isStarted = false

    // MARK: - Monitoring

    public func startMonitoring() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let connected      = path.status == .satisfied
            let type           = self.connectionType(from: path)
            let expensive      = path.isExpensive
            let constrained    = path.isConstrained

            DispatchQueue.main.async {
                let wasConnected = self.isConnected
                self.isConnected     = connected
                self.connectionType  = type
                self.isExpensive     = expensive
                self.isConstrained   = constrained

                // Only fire notification on actual status change
                if wasConnected != connected {
                    NotificationCenter.default.post(
                        name: .connectivityDidChange,
                        object: connected
                    )
                }
            }
        }

        monitor.start(queue: queue)
    }

    public func stopMonitoring() {
        monitor.cancel()
        isStarted = false
    }

    // MARK: - Connection Type Resolution

    private func connectionType(from path: NWPath) -> ConnectionType {
        guard path.status == .satisfied else { return .none }

        if path.usesInterfaceType(.wifi)     { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }

        return .unknown
    }

    // MARK: - Convenience

    /// Returns true if connected on a non-metered, high-speed connection.
    public var isOnWifi: Bool {
        connectionType == .wifi || connectionType == .ethernet
    }

    /// Returns true if on cellular — useful to decide whether to load heavy resources.
    public var isOnCellular: Bool {
        connectionType == .cellular
    }
}

// MARK: - SwiftUI View Modifier

public struct RequiresNetworkModifier: ViewModifier {
    @ObservedObject private var monitor = NetworkMonitor.shared
    let offlineView: AnyView

    public func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if !monitor.isConnected {
                offlineView
            }
        }
    }
}

public extension View {

    /// Shows an offline banner at the top of the view when there is no internet connection.
    func showOfflineBanner() -> some View {
        modifier(RequiresNetworkModifier(offlineView: AnyView(OfflineBannerView())))
    }

    /// Disables the view and shows an offline message when there is no internet connection.
    func requiresNetwork() -> some View {
        modifier(RequiresNetworkModifier(offlineView: AnyView(OfflineBannerView())))
            .disabled(!NetworkMonitor.shared.isConnected)
    }
}

// MARK: - Offline Banner View

struct OfflineBannerView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("No internet connection")
                .font(.subheadline)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.9))
        .cornerRadius(8)
        .padding(.top, 8)
        .shadow(radius: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(), value: true)
    }
}

// MARK: - UIKit Integration

public extension NetworkMonitor {

    /// Observe in UIViewController:
    /// NotificationCenter.default.addObserver(self,
    ///     selector: #selector(connectivityChanged(_:)),
    ///     name: .connectivityDidChange,
    ///     object: nil)
    ///
    /// @objc func connectivityChanged(_ notification: Notification) {
    ///     let isConnected = notification.object as? Bool ?? false
    ///     updateUI(connected: isConnected)
    /// }

    /// Checks if a network operation should proceed.
    /// Throws NetworkError.noInternetConnection if offline.
    func assertConnected() throws {
        guard isConnected else {
            throw NetworkError.noInternetConnection
        }
    }
}
