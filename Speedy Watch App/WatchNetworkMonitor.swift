import Foundation
import Network
import Combine

class WatchNetworkMonitor: ObservableObject {
    @Published var isOnline: Bool = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var wasOnline: Bool = true // Track previous state for sound alerts

    init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newOnlineStatus = path.status == .satisfied

                // Only play sound if status actually changed
                if self.isOnline != newOnlineStatus {
                    self.isOnline = newOnlineStatus

                    // Play appropriate sound alert
                    let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
                    if soundAlertsEnabled {
                        if newOnlineStatus {
                            SoundManager.shared.playOnlineAlert()
                        } else {
                            SoundManager.shared.playOfflineAlert()
                        }
                    }
                } else {
                    self.isOnline = newOnlineStatus
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
