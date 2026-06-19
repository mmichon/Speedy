import UIKit

class SpeedyAppDelegate: NSObject, UIApplicationDelegate {
    var sharedLocationManager = LocationManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }


}

// Extension to make the location manager accessible
extension SpeedyAppDelegate {
    var locationManager: LocationManager {
        return sharedLocationManager
    }
}
