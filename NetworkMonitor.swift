import Foundation
import Network
import Combine
import SpeedyShared

class NetworkMonitor: ObservableObject {
    @Published var isOnline: Bool = false
    private var initialCheckCompleted: Bool = false // New property
    private var appStartTime: Date = Date()
    private let soundDelayAfterStartup: TimeInterval = 10.0 // 10 seconds delay before allowing sounds
    private var timer: Timer?
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
    private var cancellables = Set<AnyCancellable>() // Added

    init() {
        startMonitoring()
        // Added: Observe network status changes and play sound
        $isOnline
            .dropFirst() // Don't play sound on initial setup
            .sink { isOnline in
                let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
                if soundAlertsEnabled && self.shouldAllowSounds {
                    if isOnline {
                        SoundManager.shared.playOnlineAlert()
                    } else {
                        SoundManager.shared.playOfflineAlert()
                    }
                } else if !self.shouldAllowSounds {
                    print("NetworkMonitor: Sounds disabled - app just started")
                }

                // Refresh widgets when network status changes
                DispatchQueue.main.async {
                    SpeedyDataManager.shared.forceWidgetRefresh()
                }

                // When coming online, trigger immediate speed limit lookup
                if isOnline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Notify LocationManager to refresh speed limit
                        NotificationCenter.default.post(name: NSNotification.Name("NetworkCameOnline"), object: nil)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func startMonitoring() {
        // Check immediately
        checkConnectivity()

        // Set up timer to check every 5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkConnectivity()
        }
    }

    private func checkConnectivity() {
        queue.async { [weak self] in
            let host = "8.8.8.8"
            let port: NWEndpoint.Port = 53 // DNS port
            let timeout: TimeInterval = 5.0 // Overall timeout for the connection attempt (increased for reliability)

            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            var connectionCompleted = false // Flag to ensure only one final state is processed

            connection.stateUpdateHandler = { state in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if connectionCompleted { return } // Already processed a final state

                    switch state {
                    case .ready:
                        connectionCompleted = true
                        if self.isOnline != true {
                            self.isOnline = true
                        }
                        self.initialCheckCompleted = true // Added
                        connection.cancel()
                    case .failed, .cancelled:
                        connectionCompleted = true
                        if self.isOnline != false {
                            self.isOnline = false
                            // Don't play sound on initial check - only on status changes
                        }
                        self.initialCheckCompleted = true
                        connection.cancel()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: self?.queue ?? .main)

            // Set a timeout for the entire connection attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard let self = self else { return }
                if !connectionCompleted {
                    // If the connection hasn't reached a final state (ready, failed, cancelled) within the timeout
                    connectionCompleted = true
                    if self.isOnline != false {
                        self.isOnline = false
                        // Don't play sound on initial check - only on status changes
                    }
                    self.initialCheckCompleted = true
                    connection.cancel()
                }
            }
        }
    }

    // Check if enough time has passed since app startup to allow sounds
    private var shouldAllowSounds: Bool {
        let timeSinceStartup = Date().timeIntervalSince(appStartTime)
        return timeSinceStartup >= soundDelayAfterStartup
    }

    // Reset startup time when app becomes active
    func resetStartupTime() {
        appStartTime = Date()
    }

    deinit {
        timer?.invalidate()
    }
}
