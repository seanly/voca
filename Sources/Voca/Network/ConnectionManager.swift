import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.Voca", category: "ConnectionManager")

/// Connection state machine for server mode degradation.
enum ConnectionState: Equatable {
    case localOnly      // No server URL configured
    case connecting     // Performing initial health check
    case online         // Server reachable, using server mode
    case offline        // Server unreachable, degraded to local mode
}

/// Manages the connection to dmr-plugin-voca server with automatic fallback.
final class ConnectionManager {
    static let shared = ConnectionManager()

    private(set) var state: ConnectionState = .localOnly
    var onStateChanged: ((ConnectionState) -> Void)?

    private var healthTimer: Timer?
    private var consecutiveFailures = 0
    private let maxFailuresBeforeBackoff = 3
    private let normalInterval: TimeInterval = 30
    private let backoffInterval: TimeInterval = 60

    private init() {
        updateState()
    }

    /// Re-evaluate connection state when settings change.
    func updateState() {
        let url = Settings.shared.serverURL
        if url.isEmpty || !Settings.shared.serverEnabled {
            transitionTo(.localOnly)
            stopHealthCheck()
        } else if state == .localOnly {
            transitionTo(.connecting)
            checkHealth()
            startHealthCheck()
        }
    }

    /// Whether the server should be used for the current request.
    var shouldUseServer: Bool {
        state == .online
    }

    // MARK: - Health Check

    func checkHealth() {
        let settings = Settings.shared
        guard !settings.serverURL.isEmpty else { return }

        let client = VocaClient(baseURL: settings.serverURL, authToken: settings.serverAuthToken)
        client.health { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.consecutiveFailures = 0
                    self.transitionTo(.online)
                } else {
                    self.consecutiveFailures += 1
                    self.transitionTo(.offline)
                    self.adjustHealthCheckInterval()
                }
            }
        }
    }

    private func startHealthCheck() {
        stopHealthCheck()
        healthTimer = Timer.scheduledTimer(withTimeInterval: normalInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func adjustHealthCheckInterval() {
        if consecutiveFailures >= maxFailuresBeforeBackoff {
            stopHealthCheck()
            healthTimer = Timer.scheduledTimer(withTimeInterval: backoffInterval, repeats: true) { [weak self] _ in
                self?.checkHealth()
            }
        }
    }

    private func transitionTo(_ newState: ConnectionState) {
        guard state != newState else { return }
        let oldState = state
        state = newState
        logger.info("Connection: \(String(describing: oldState)) → \(String(describing: newState))")
        onStateChanged?(newState)
    }
}
