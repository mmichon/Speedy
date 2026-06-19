import SwiftUI
import Combine

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
                // Observe speedLimitKnown to dismiss loading screen (don't wait for road name)
                locationManager.$speedLimitKnown
                    .sink { speedLimitKnown in
                        if speedLimitKnown {
                            self.isLoading = false
                        }
                    }
                    .store(in: &self.cancellables)

                // Fallback timer to dismiss loading screen after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isLoading = false
                }
            }
        }
    }
}
