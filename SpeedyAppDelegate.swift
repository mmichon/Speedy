import UIKit
import SpeedyShared

class SpeedyAppDelegate: NSObject, UIApplicationDelegate {
    var sharedLocationManager = LocationManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set up app state monitoring for widget refresh
        setupAppStateMonitoring()
        return true
    }

    private func setupAppStateMonitoring() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Logger.log("App became active, forcing widget refresh", level: .info, category: "AppDelegate")
            SpeedyDataManager.shared.forceWidgetRefresh()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Logger.log("App will enter foreground, forcing widget refresh", level: .info, category: "AppDelegate")
            SpeedyDataManager.shared.forceWidgetRefresh()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.log("App will resign active (window closing/backgrounding)", level: .info, category: "AppDelegate")
            // Do not stop live activity on resign active; just notify location manager
            self?.sharedLocationManager.handleAppStateChange(isActive: false)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// Extension to make the location manager accessible
extension SpeedyAppDelegate {
    var locationManager: LocationManager {
        return sharedLocationManager
    }
}
