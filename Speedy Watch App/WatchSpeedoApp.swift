import SwiftUI

@main
struct WatchSpeedyApp: App {
    @StateObject private var locationManager = WatchLocationManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(locationManager)
        }
    }
}
