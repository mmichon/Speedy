import Foundation
import CoreLocation
import Combine
import SpeedyShared
import WatchKit



enum SpeedTrend {
    case increasing
    case decreasing
    case stable
}

class WatchLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    let locationManager = CLLocationManager()
    let speedLimitService = SpeedLimitService.shared

    var cancellables = Set<AnyCancellable>()

    @Published var currentSpeed: Double = 0.0
    @Published var speedLimit: Int = 0
    @Published var isSpeeding: Bool = false
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLookingUpSpeedLimit: Bool = false
    @Published var speedLimitKnown: Bool = false
    @Published var currentRoadName: String = ""
    @Published var unitPreference: SpeedyShared.Unit = .imperial
    @Published var isNetworkOnline: Bool = true
    @Published var speedTrend: SpeedTrend = .stable
    @Published var currentAltitude: Double = 0.0
    @Published var batteryLevel: Float = 1.0
    @Published var isCharging: Bool = false

    private var lastSpeedLimitCheck = Date()
    private var lastRoadNameCheck = Date()
    private var wasSpeeding: Bool = false
    private var previousSpeed: Double = 0.0

    override init() {
        super.init()
        loadSavedSettings()
        setupLocationManager()
        setupSpeedLimitService()
        setupBatteryMonitoring()
    }

    private func loadSavedSettings() {
        // Load saved unit preference
        if let savedUnit = UserDefaults.standard.string(forKey: "unitPreference") {
            unitPreference = SpeedyShared.Unit(rawValue: savedUnit) ?? .imperial
        }
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0 // Update every 1 meter
        locationManager.startUpdatingLocation()
    }

    private func setupSpeedLimitService() {
        // Subscribe to speed limit service updates
        speedLimitService.$currentSpeedLimit
            .compactMap { $0 }
            .sink { [weak self] (newSpeedLimit: Int) in
                DispatchQueue.main.async {
                    self?.speedLimit = newSpeedLimit
                    self?.speedLimitKnown = true // Set to true when a speed limit is received
                    self?.checkSpeedLimit()
                }
            }
            .store(in: &cancellables)

        speedLimitService.$currentRoadName
            .sink { [weak self] (roadName: String?) in
                DispatchQueue.main.async {
                    if let roadName = roadName, !roadName.isEmpty {
                        self?.currentRoadName = roadName
                    }
                }
            }
            .store(in: &cancellables)

        speedLimitService.$isLoading
            .sink { [weak self] isLoading in
                DispatchQueue.main.async {
                    self?.isLookingUpSpeedLimit = isLoading
                }
            }
            .store(in: &cancellables)
    }

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func updateSpeed() {
        guard let location = locationManager.location else { return }

        // Convert speed from m/s to MPH
        let speedInMPS = location.speed
        let speedInMPH = speedInMPS * 2.23694 // Convert m/s to MPH

        // Update altitude
        currentAltitude = location.altitude

        // Speed threshold to prevent phantom speeds when stationary
        let speedThreshold = unitPreference == SpeedyShared.Unit.imperial ? 1.0 : 1.6 // MPH or KPH threshold

        var newSpeed = 0.0
        if speedInMPH > speedThreshold {
            newSpeed = speedInMPH
        }

        // Only update if we have a valid speed (positive and reasonable)
        if newSpeed >= 0 && newSpeed < 700 {
            DispatchQueue.main.async {
                // Update speed trend
                let speedDifference = newSpeed - self.previousSpeed
                if abs(speedDifference) > 0.5 { // Threshold to avoid noise
                    if speedDifference > 0 {
                        self.speedTrend = .increasing
                    } else {
                        self.speedTrend = .decreasing
                    }
                } else {
                    self.speedTrend = .stable
                }

                self.previousSpeed = newSpeed
                self.currentSpeed = newSpeed
                self.checkSpeedLimit()
            }
        }

        // Check if we should look up speed limit (every 5 seconds or when moving significantly)
        let timeSinceLastCheck = Date().timeIntervalSince(lastSpeedLimitCheck)
        let timeSinceLastRoadCheck = Date().timeIntervalSince(lastRoadNameCheck)

        if timeSinceLastCheck > 5.0 {
            lastSpeedLimitCheck = Date()
            lookupSpeedLimitForCurrentLocation(location.coordinate)
        }

        if timeSinceLastRoadCheck > 10.0 {
            lastRoadNameCheck = Date()
            lookupRoadNameForCurrentLocation(location.coordinate)
        }
    }

    private func checkSpeedLimit() {
        if isLookingUpSpeedLimit || !speedLimitKnown {
            if !wasSpeeding {
                isSpeeding = false
            }
            return
        }
        let speedingThreshold = Double(speedLimit)
        let newIsSpeeding = currentSpeed > (speedingThreshold + 1.0) // Add 1 MPH buffer to prevent false positives

        print("Watch Speed Check - Current speed: \(currentSpeed), Speed limit: \(speedLimit), Threshold: \(speedingThreshold), Buffer: +1.0, Is speeding: \(newIsSpeeding)")

        // Play sound alert when crossing into speeding (only if sound alerts are enabled)
        if newIsSpeeding && !wasSpeeding {
            let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
            if soundAlertsEnabled {
                SoundManager.shared.playSpeedingAlert()
            }
        }

        wasSpeeding = newIsSpeeding
        isSpeeding = newIsSpeeding
    }

    private func lookupSpeedLimitForCurrentLocation(_ coordinate: CLLocationCoordinate2D) {
        guard !isLookingUpSpeedLimit else {
            return
        }
        speedLimitService.lookupSpeedLimit(for: coordinate)
    }

    private func lookupRoadNameForCurrentLocation(_ coordinate: CLLocationCoordinate2D) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            DispatchQueue.main.async {
                if let roadName = placemarks?.first?.thoroughfare {
                    self?.currentRoadName = roadName
                } else {
                    self?.currentRoadName = ""
                    // If road name is unknown, speed limit should also be unknown
                    self?.speedLimit = 0
                    self?.speedLimitKnown = false
                }
            }
        }
    }

    func refreshSpeedLimit() {
        guard let location = locationManager.location else { return }
        lookupSpeedLimitForCurrentLocation(location.coordinate)
    }

    func refreshRoadName() {
        guard let location = locationManager.location else { return }
        lookupRoadNameForCurrentLocation(location.coordinate)
    }

    // Computed properties for displayed speeds
    var displayedCurrentSpeed: Int {
        if unitPreference == SpeedyShared.Unit.metric {
            return Int(currentSpeed * 1.60934)
        } else {
            return Int(currentSpeed)
        }
    }

    var displayedSpeedLimit: Int {
        if unitPreference == SpeedyShared.Unit.metric {
            return Int(Double(speedLimit) * 1.60934)
        } else {
            return speedLimit
        }
    }

    var unitString: String {
        unitPreference.rawValue
    }

    var unitSuffix: String {
        switch unitPreference {
        case .imperial: return "mph"
        case .metric: return "kph"
        }
    }

    func formattedAltitude() -> String {
        let meters = currentAltitude
        if unitPreference == .metric {
            return String(format: "%.0f m", meters)
        } else {
            let feet = meters * 3.28084
            return String(format: "%.0f ft", feet)
        }
    }

    private var batteryTimer: Timer?

    private func setupBatteryMonitoring() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        updateBatteryInfo()
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateBatteryInfo()
        }
    }

    private func updateBatteryInfo() {
        let device = WKInterfaceDevice.current()
        let level = device.batteryLevel
        if level >= 0 {
            batteryLevel = level
        } else {
            batteryLevel = 1.0
        }
        let state = device.batteryState
        isCharging = state == .charging || state == .full
    }

    func updateUnitPreference(_ newUnit: SpeedyShared.Unit) {
        unitPreference = newUnit
        UserDefaults.standard.set(newUnit.rawValue, forKey: "unitPreference")
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateSpeed()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.locationStatus = status

            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationManager.startUpdatingLocation()
            case .denied, .restricted:
                self.locationManager.stopUpdatingLocation()
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            print("Location manager failed with error: The operation couldn't be completed. (kCLErrorDomain error 0.)")
        } else {
            print("Location manager failed with error: \(error.localizedDescription)")
        }
    }
}
