import SwiftUI
import Combine
import SpeedyShared

@main
struct SpeedyApp: App {
    @UIApplicationDelegateAdaptor(SpeedyAppDelegate.self) var appDelegate
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var isLoading = true
    @State private var cancellables = Set<AnyCancellable>()

    // Use the shared location manager from app delegate
    private var locationManager: LocationManager {
        return appDelegate.sharedLocationManager
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isLoading {
                    LoadingView()
                        .environmentObject(locationManager)
                        .environmentObject(networkMonitor)
                } else {
                    ContentView()
                        .environmentObject(locationManager)
                        .environmentObject(networkMonitor)
                }
            }
            .onAppear {
                locationManager.requestLocationPermission()

                // Initialize ads if enabled
                if UserDefaults.standard.bool(forKey: "adsEnabled") {
                    AdManager.shared.start()
                }

                // Force widget refresh on app startup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Test app group configuration
                    SpeedyDataManager.shared.testAppGroupConfiguration()

                    // Force save current data to widgets
                    locationManager.forceSaveCurrentDataToWidgets()

                    // Force widget refresh
                    SpeedyDataManager.shared.forceWidgetRefresh()
                }

                // Show loading screen for minimum time to ensure smooth transition
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.isLoading = false
                }
            }
        }
    }
}
