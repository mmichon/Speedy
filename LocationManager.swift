import Foundation
import CoreLocation
import Combine
import UIKit
import ActivityKit
import SpeedyShared
import CoreTelephony



class LocationManager: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var speedUpdateTimer: Timer?
    let speedLimitService = SpeedLimitService.shared
    private var activity: Activity<SpeedyWidgetAttributes>? = nil
    private var isLiveActivityActive: Bool = false
    // Set synchronously while an Activity.request is in flight. isLiveActivityActive
    // is only set once the async request resolves, so without this guard two callers
    // in the same run loop can both start an activity and create duplicates (which
    // also surface as multiple Live Activities on the Apple Watch Smart Stack).
    private var isStartingLiveActivity: Bool = false
    private var liveActivityUpdateTimer: Timer?
    private let movementThreshold: Double = 2.0 // MPH threshold to consider device moving
    private var stationaryStart: Date? = nil // when the device last became stationary
    private let liveActivityStationaryTimeout: TimeInterval = 5 // seconds parked before hiding the Live Activity


    var cancellables = Set<AnyCancellable>()


    @Published var currentSpeed: Double = 0.0
    @Published var speedLimit: Int = 0
    @Published var speedLimitOffset: Int = 0  // -20 to +20 MPH in 5 MPH increments
    @Published var isSpeeding: Bool = false
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentRoadName: String? {
        didSet {
            if let roadName = currentRoadName {
                Logger.log("Road name changed to: \(roadName)", level: .info, category: "LocationManager")
            } else {
                Logger.log("Road name cleared", level: .info, category: "LocationManager")
            }
        }
    }
    @Published var currentTown: String? {
        didSet {
            if let town = currentTown {
                Logger.log("Town changed to: \(town)", level: .info, category: "LocationManager")
            } else {
                Logger.log("Town cleared", level: .info, category: "LocationManager")
            }
        }
    }
    @Published var isLookingUpSpeedLimit: Bool = false
    @Published var alertMessage: String?
    @Published var shouldResetOffset: Bool = false
    @Published var speedLimitKnown: Bool = false
    /// True when the current speed limit is a statutory default (inferred from
    /// road class) rather than a posted/confirmed value.
    @Published var speedLimitIsInferred: Bool = false
    @Published var isNetworkOnline: Bool = true
    @Published var unitPreference: SpeedyShared.Unit = .imperial
    @Published var locationHistory: [CLLocation] = []
    @Published var testModeEnabled: Bool = false
    @Published var currentAltitude: Double = 0.0
    @Published var cellularSignalStrength: Int = 0
    @Published var hasGPSLock: Bool = false

    // MARK: - Public Properties
    var location: CLLocation? {
        return locationManager.location
    }

    // Persistent CoreTelephony handle to avoid transient XPC reconnects
    private var telephonyInfo: CTTelephonyNetworkInfo?

    // Speed smoothing for better GPS accuracy
    private var speedReadings: [Double] = []
    private let maxSpeedReadings = 5
    private var lastStationaryTime: Date = Date()
    private let stationaryThreshold: TimeInterval = 1.0 // 1 second of low speed to consider stationary

    // Smart road detection for better street name accuracy
    private var travelDirectionHistory: [Double] = []
    private let maxDirectionHistory = 10
    private var internalRoadName: String?
    private var lastRoadNameChange: Date = Date()
    private let roadNameStabilityThreshold: TimeInterval = 3.0 // 3 seconds before allowing road name change
    private var roadNameConfidence: Double = 0.0 // 0.0 to 1.0 confidence in current road name

    @Published var liveActivitiesEnabled: Bool = true

    private var lastSpeedLimitCheck = Date()
    private var wasSpeeding: Bool = false
    private var lastRoadNameCheck = Date()
    private var lastSpeedingAlertTime: Date = Date.distantPast
    private let speedingAlertCooldown: TimeInterval = 5.0 // 5 seconds between speeding alerts
    private var appStartTime: Date = Date()
    private let soundDelayAfterStartup: TimeInterval = 10.0 // 10 seconds delay before allowing sounds

    override init() {
        super.init()
        loadSavedSettings()
        setupLocationManager()
        startSpeedUpdates()
        setupSpeedLimitService()

        // Defer non-critical initialization to background
        DispatchQueue.global(qos: .background).async { [weak self] in
            // Start cellular signal strength monitoring
            self?.startCellularSignalMonitoring()

            // Reattach to any existing Live Activity so updates can flow post-launch
            if #available(iOS 16.1, *) {
                self?.rehydrateLiveActivity()
            }

            // Live activities will be started automatically when CarPlay is connected
            // No need to start them during app initialization
        }

        // Defer debug operations to background to avoid blocking app startup
        DispatchQueue.global(qos: .background).async {
            SpeedyDataManager.shared.debugWidgetData()
        }

        // Listen for network coming online to trigger speed limit lookup
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkCameOnline),
            name: NSNotification.Name("NetworkCameOnline"),
            object: nil
        )

        // Initialize road name if we have a location
        if locationManager.location != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.updateRoadName()
            }
        }
    }

    private func loadSavedSettings() {
        // Load saved speed limit offset
        speedLimitOffset = UserDefaults.standard.integer(forKey: "speedLimitOffset")

        // Load saved unit preference
        if let savedUnit = UserDefaults.standard.string(forKey: "unitPreference") {
            unitPreference = SpeedyShared.Unit(rawValue: savedUnit) ?? .imperial
        }

        // Load saved live activities preference
        liveActivitiesEnabled = UserDefaults.standard.bool(forKey: "liveActivitiesEnabled")

        // Load saved test mode setting
        testModeEnabled = UserDefaults.standard.bool(forKey: "testModeEnabled")

        // Load and apply screen wake setting
        let keepScreenOn = UserDefaults.standard.bool(forKey: "keepScreenOn")
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }

        // Apply test mode immediately if enabled
        if testModeEnabled {
            DispatchQueue.main.async {
                self.triggerSpeedUpdate()
            }
        }

        // Start live activities if enabled — but only once the device is actually
        // moving (manageLiveActivityBasedOnMovement gates on isDeviceMoving).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if #available(iOS 16.1, *) {
                if self.liveActivitiesEnabled {
                    self.manageLiveActivityBasedOnMovement()
                }
            }
        }
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0 // Update every 1 meter

#if targetEnvironment(simulator)
        // Use a predefined route for the simulator
        let gpxURL = Bundle.main.url(forResource: "Testroute", withExtension: "gpx")
        if let gpxURL = gpxURL {
            let gpxData = try? Data(contentsOf: gpxURL)
            if let gpxData = gpxData {
                let locations = GPXParser().parse(data: gpxData)
                if !locations.isEmpty {
                    locationManager.startUpdatingLocation()
                    // Simulate location updates
                    var index = 0
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                        if index < locations.count {
                            self.locationManager.delegate?.locationManager?(self.locationManager, didUpdateLocations: [locations[index]])
                            index += 1
                        } else {
                            timer.invalidate()
                        }
                    }
                }
            }
        }
#endif
    }

    private func setupSpeedLimitService() {
        // Subscribe to speed limit service updates
        speedLimitService.$currentSpeedLimit
            .sink { [weak self] newSpeedLimit in
                DispatchQueue.main.async {
                    if let newSpeedLimit = newSpeedLimit {
                        self?.speedLimit = newSpeedLimit
                        self?.speedLimitKnown = true
                    } else {
                        // Unknown — don't keep showing a stale/fabricated number.
                        self?.speedLimit = 0
                        self?.speedLimitKnown = false
                        self?.speedLimitIsInferred = false
                    }
                    self?.saveWidgetData() // Update widget data
                    self?.checkSpeedLimit()
                    if #available(iOS 16.1, *) {
                        self?.updateLiveActivity()
                    }
                }
            }
            .store(in: &cancellables)

        speedLimitService.$currentSpeedLimitIsInferred
            .sink { [weak self] inferred in
                DispatchQueue.main.async {
                    self?.speedLimitIsInferred = inferred
                    self?.saveWidgetData()
                }
            }
            .store(in: &cancellables)

        speedLimitService.$currentRoadName
            .compactMap { $0 }
            .sink { [weak self] roadName in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    // Check if road name has changed
                    if self.currentRoadName != roadName {
                        self.currentRoadName = roadName
                        if #available(iOS 16.1, *) {
                            self.updateLiveActivity()
                        }
                        self.saveWidgetData() // Update widget data

                        // If we have a location, trigger a speed limit lookup for the new road
                        if let location = self.locationManager.location {
                            self.log("Road name changed to '\(roadName)', triggering speed limit lookup", level: "INFO")
                            self.speedLimitService.forceLookupSpeedLimit(for: location.coordinate,
                                                                         course: location.course >= 0 ? location.course : nil)
                        }
                    } else {
                        // Road name is the same, just update it
                        self.currentRoadName = roadName
                        if #available(iOS 16.1, *) {
                            self.updateLiveActivity()
                        }
                        self.saveWidgetData() // Update widget data
                    }
                }
            }
            .store(in: &cancellables)

        speedLimitService.$currentCityName
            .compactMap { $0 }
            .sink { [weak self] cityName in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    // Update current town with city name from SpeedLimitService
                    if self.currentTown != cityName {
                        self.currentTown = cityName
                        self.saveWidgetData() // Update widget data
                        self.log("City name updated to: \(cityName)", level: "INFO")
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

    private func startSpeedUpdates() {
        // Update speed twice per second (every 0.5 seconds)
        speedUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateSpeed()
        }
    }

    private func updateSpeed() {
        guard let location = locationManager.location else { return }

        // Convert speed from m/s to MPH
        let speedInMPS = location.speed
        let speedInMPH = speedInMPS * 2.23694 // Convert m/s to MPH

        // Detect a stale location. The update timer fires every 0.5s but
        // distanceFilter (1m) means CoreLocation stops delivering new fixes once
        // we stop moving. In that case locationManager.location keeps returning
        // the last fix captured at the moment we stopped — which can carry a
        // residual speed (e.g. 2 MPH) — so the display gets stuck above 0.
        // Treat any fix older than the threshold as the vehicle being stationary.
        let locationAge = Date().timeIntervalSince(location.timestamp)
        let isStaleLocation = locationAge > 2.0

        // Enhanced speed threshold to prevent phantom speeds when stationary
        let speedThreshold = 1.0 // MPH - even more aggressive threshold for stationary detection

        // Additional check for very low speeds that are likely GPS noise
        let isLikelyStationary = isStaleLocation ||
                                speedInMPH <= speedThreshold ||
                                (speedInMPH <= 2.0 && location.horizontalAccuracy > 5.0) || // More aggressive detection
                                (speedInMPH <= 3.0 && location.horizontalAccuracy > 10.0) // Very poor GPS accuracy

        // Calculate smoothed speed
        var newSpeed = 0.0

        // Speed smoothing to reduce GPS noise
        if !isLikelyStationary {
            speedReadings.append(speedInMPH)
            if speedReadings.count > maxSpeedReadings {
                speedReadings.removeFirst()
            }

            if speedReadings.count >= 3 {
                // Use median of last 3+ readings for more stable speed
                let sortedReadings = speedReadings.sorted()
                let medianIndex = sortedReadings.count / 2
                newSpeed = sortedReadings[medianIndex]
            } else {
                newSpeed = speedInMPH
            }

            // Reset stationary timer when we detect movement
            lastStationaryTime = Date()
        } else {
            // If likely stationary, clear speed readings and track time
            speedReadings.removeAll()

            // Check if we've been stationary for a while
            let timeSinceStationary = Date().timeIntervalSince(lastStationaryTime)
            if timeSinceStationary >= stationaryThreshold {
                // Force speed to 0 immediately when stationary for threshold time
                newSpeed = 0.0
            } else {
                // During the transition period, immediately set to 0 for very low speeds
                // This prevents the "ghost speed" issue by immediately showing 0
                // when we detect the vehicle is likely stationary
                newSpeed = 0.0
            }
        }

        // Always update speed display, even when stationary (for test mode)
        DispatchQueue.main.async {
            // Only update speed if test mode is OFF, otherwise preserve the test speed
            if !self.testModeEnabled {
                // Additional validation: if GPS speed is negative or very low, force to 0
                if speedInMPS < 0 || speedInMPS < 0.5 { // Less than 0.5 m/s (about 1.1 mph)
                    newSpeed = 0.0
                }

                self.currentSpeed = newSpeed
                self.saveWidgetData() // Update widget data
                // Test Mode OFF: Using GPS speed

                // If speed is very low and not in test mode, immediately reset speeding state
                if newSpeed <= 1.0 {
                    self.isSpeeding = false
                    self.wasSpeeding = false
                    // Speed very low, resetting speeding state
                }
            } else {
                print("Test Mode ON: Preserving test speed: \(self.currentSpeed)")
            }

            // Update altitude
            self.currentAltitude = location.altitude

            self.checkSpeedLimit()
            if #available(iOS 16.1, *) {
                self.updateLiveActivity()
                self.manageLiveActivityBasedOnMovement()
            }
        }

        // Check if we should look up speed limit (every 10 seconds or when moving significantly)
        let timeSinceLastCheck = Date().timeIntervalSince(lastSpeedLimitCheck)

        if timeSinceLastCheck > 5.0 {
            lastSpeedLimitCheck = Date()
            lookupSpeedLimitForCurrentLocation(location.coordinate,
                                               course: location.course >= 0 ? location.course : nil)
        }

        let timeSinceLastRoadNameCheck = Date().timeIntervalSince(lastRoadNameCheck)
        if timeSinceLastRoadNameCheck > 5.0 {
            lastRoadNameCheck = Date()
            updateRoadName()
        }
    }

    private func checkSpeedLimit() {
        // Special case for test mode: always check speeding if test mode is enabled
        if self.testModeEnabled {
            // In test mode, use a default speed limit of 25 MPH to ensure speeding is detected
            let defaultSpeedLimit = 25
            let adjustedSpeedLimit = Double(defaultSpeedLimit) + Double(speedLimitOffset)
            let speedingThreshold = adjustedSpeedLimit
            let newIsSpeeding = currentSpeed > (speedingThreshold + 1.0) // Add 1 MPH buffer to prevent false positives

        // Fire a speeding alert when crossing into speeding (only if sound alerts are enabled)
        if newIsSpeeding && !wasSpeeding {
            let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
            print("Test Mode: Sound alerts enabled: \(soundAlertsEnabled)")
            if soundAlertsEnabled && shouldAllowSounds {
                // Check if enough time has passed since last alert
                let timeSinceLastAlert = Date().timeIntervalSince(lastSpeedingAlertTime)
                if timeSinceLastAlert >= speedingAlertCooldown {
                    print("Test Mode: Playing speeding alert sound...")
                    SoundManager.shared.playSpeedingAlert()
                    lastSpeedingAlertTime = Date()
                } else {
                    print("Test Mode: Speeding alert on cooldown. Skipping.")
                }
            } else if !shouldAllowSounds {
                print("Test Mode: Sounds disabled - app just started")
            }
        }

            wasSpeeding = newIsSpeeding
            isSpeeding = newIsSpeeding
            return
        }

        // Normal speed limit checking (when not in test mode)
        if isLookingUpSpeedLimit || !speedLimitKnown || !isNetworkOnline {
            // If we are looking up the speed limit, or it's unknown, or offline,
            // check if we should reset speeding state based on current speed
            if currentSpeed <= 1.5 { // If speed is very low (essentially stopped)
                isSpeeding = false
                wasSpeeding = false
                // Speed very low, resetting speeding state
            } else if !wasSpeeding {
                // Maintain current state if not already speeding
                isSpeeding = false
            }
            return
        }

        // Check if current speed exceeds speed limit + offset
        let adjustedSpeedLimit = Double(speedLimit) + Double(speedLimitOffset)
        let speedingThreshold = adjustedSpeedLimit
        let newIsSpeeding = currentSpeed > (speedingThreshold + 1.0) // Add 1 MPH buffer to prevent false positives

        // A large overshoot over the displayed limit is a strong signal we've moved
        // onto a faster road and the (lower) cached limit is stale. Force an immediate
        // re-fetch instead of waiting for the next 5s tick so the higher limit lands
        // quickly and the warning above resolves. The service's own throttle and the
        // isLookingUpSpeedLimit guard keep this from spamming the HERE API.
        if !isLookingUpSpeedLimit, currentSpeed > adjustedSpeedLimit + 12.0,
           let location = location {
            speedLimitService.forceLookupSpeedLimit(for: location.coordinate,
                                                     course: location.course >= 0 ? location.course : nil)
        }

        // Fire a speeding alert when crossing into speeding (only if sound alerts are enabled)
        if newIsSpeeding && !wasSpeeding {
            let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
            print("Sound alerts enabled: \(soundAlertsEnabled)")
            if soundAlertsEnabled && shouldAllowSounds {
                // Check if enough time has passed since last alert
                let timeSinceLastAlert = Date().timeIntervalSince(lastSpeedingAlertTime)
                if timeSinceLastAlert >= speedingAlertCooldown {
                    print("Playing speeding alert sound...")
                    SoundManager.shared.playSpeedingAlert()
                    lastSpeedingAlertTime = Date()
                } else {
                    print("Speeding alert on cooldown. Skipping.")
                }
            } else if !shouldAllowSounds {
                print("Sounds disabled - app just started")
            }
        }

        wasSpeeding = newIsSpeeding
        isSpeeding = newIsSpeeding
        saveWidgetData() // Update widget data
    }

    func updateSpeedLimitOffset(_ newOffset: Int, unit: SpeedyShared.Unit) { // Added unit parameter
        var offsetInMPH = newOffset
        if unit == .metric {
            offsetInMPH = Int(Double(newOffset) / 1.60934) // Convert KPH to MPH
        }

        let alertLimit = speedLimit + offsetInMPH // Use offsetInMPH
        if alertLimit <= 0 { // Changed < to <=
            alertMessage = "Alert speed limit cannot be 0 or less. Offset reset to 0. Current speed limit is \(speedLimit) \(unitPreference.unitString)."
            shouldResetOffset = true
            return
        }
        speedLimitOffset = offsetInMPH // Store in MPH
        alertMessage = nil
        shouldResetOffset = false
        checkSpeedLimit()
    }

    private func lookupSpeedLimitForCurrentLocation(_ coordinate: CLLocationCoordinate2D, course: Double? = nil) {
        Logger.log("lookupSpeedLimitForCurrentLocation called with coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .debug, category: "LocationManager")
        // Only lookup if we're not already looking up
        guard !isLookingUpSpeedLimit else {
            Logger.log("Already looking up speed limit. Skipping.", level: .debug, category: "LocationManager")
            return
        }

        // Look up speed limit for current location, passing GPS course so the
        // service can snap to the road actually being travelled.
        speedLimitService.lookupSpeedLimit(for: coordinate, course: course)
    }

    func refreshSpeedLimit() {
        guard let location = locationManager.location else { return }
        lookupSpeedLimitForCurrentLocation(location.coordinate, course: location.course >= 0 ? location.course : nil)
    }

    func forceRefreshSpeedLimit() {
        guard let location = locationManager.location else { return }
        log("Force refreshing speed limit", level: "INFO")

        // Clear the current speed limit to force a refresh
        speedLimit = 0
        speedLimitKnown = false

        // Force the speed limit service to refresh
        speedLimitService.forceRefreshSpeedLimit(for: location.coordinate)

        // Refresh widgets when forcing speed limit refresh
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    func updateUnitPreference(_ newUnit: SpeedyShared.Unit) {
        unitPreference = newUnit
        UserDefaults.standard.set(newUnit.rawValue, forKey: "unitPreference")
        saveWidgetData() // Update widget data with new unit
        // Recalculate speeds and limits based on new unit
        // This will be handled in updateSpeed and checkSpeedLimit
    }



    func triggerSpeedUpdate() {
        // Trigger a speed update to apply the new test mode setting
        // This method is called when test mode is toggled
        DispatchQueue.main.async {
            if self.testModeEnabled {
                // Set a high speed to trigger speeding condition
                self.currentSpeed = 100.0
                self.saveWidgetData() // Update widget data
                print("Test Mode ON: Set speed to 100 \(self.unitPreference.unitString) to trigger speeding")
            } else {
                // Reset to actual GPS speed
                if let location = self.locationManager.location {
                    let speedInMPS = location.speed
                    let speedInMPH = speedInMPS * 2.23694
                    self.currentSpeed = max(0, speedInMPH)
                    self.saveWidgetData() // Update widget data
                    // Test Mode OFF: Reset to GPS speed
                } else {
                    self.currentSpeed = 0.0
                    self.saveWidgetData() // Update widget data
                }

                // Force reset speeding state when test mode is turned off
                self.isSpeeding = false
                self.wasSpeeding = false
                // Test Mode OFF: Reset speeding state
            }

            print("Before checkSpeedLimit - Current speed: \(self.currentSpeed), Test mode: \(self.testModeEnabled)")
            self.checkSpeedLimit()
            print("After checkSpeedLimit - Is speeding: \(self.isSpeeding)")
            if #available(iOS 16.1, *) {
                self.updateLiveActivity()
                self.manageLiveActivityBasedOnMovement()
            }
            self.objectWillChange.send()
        }
    }

    // Method to manually test speeding condition
    func testSpeedingCondition() {
        print("=== Testing Speeding Condition ===")
        print("Current speed: \(currentSpeed)")
        print("Test mode enabled: \(testModeEnabled)")
        print("Speed limit: \(speedLimit)")
        print("Speed limit known: \(speedLimitKnown)")
        print("Network online: \(isNetworkOnline)")
        print("Is looking up speed limit: \(isLookingUpSpeedLimit)")
        print("Current speeding state: \(isSpeeding)")
        print("================================")

        // Force a speed check
        checkSpeedLimit()
        print("After forced check - Is speeding: \(isSpeeding)")

        // Also test directly setting speeding state
        if testModeEnabled {
            print("Test mode enabled - directly setting speeding to true")
            isSpeeding = true
            wasSpeeding = true
            objectWillChange.send()

            // Refresh widgets when testing speeding condition
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    // Method to manually toggle speeding state for testing
    func toggleSpeedingState() {
        isSpeeding.toggle()
        wasSpeeding = isSpeeding
        print("Manually toggled speeding state to: \(isSpeeding)")
        objectWillChange.send()

        // Refresh widgets when manually toggling speeding state
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Method to force reset speeding state
    func resetSpeedingState() {
        isSpeeding = false
        wasSpeeding = false
        print("Forced reset of speeding state to false")
        objectWillChange.send()

        // Refresh widgets when resetting speeding state
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    func getRoadNameConfidence() -> Double {
        return roadNameConfidence
    }

    func getCurrentTravelDirection() -> Double? {
        return getDominantTravelDirection()
    }

    @available(iOS 16.1, *)
    func updateLiveActivitiesPreference(_ enabled: Bool) {
        liveActivitiesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "liveActivitiesEnabled")

        // If disabled, stop any active live activity
        if !enabled && isLiveActivityActive {
            stopLiveActivity()
        }

        // Refresh widgets when live activity preference changes
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    @available(iOS 16.1, *)
    func startLiveActivity() {
        // Only allow starting when app is in foreground to avoid visibility errors
        if UIApplication.shared.applicationState != .active {
            Logger.log("Deferring live activity start; app is not in foreground", level: .info, category: "LocationManager")
            return
        }
        // Bail if an activity is already active or a start is already in flight.
        // This runs synchronously on the main thread, so a second caller in the same
        // run loop sees the in-flight flag and won't create a duplicate activity.
        if isLiveActivityActive || isStartingLiveActivity {
            print("Live activity already active or starting, skipping start request")
            return
        }
        // Check if we already have an active activity
        if let existingActivity = activity, existingActivity.activityState == .active {
            print("Live activity already active, skipping start request")
            return
        }

        // Check if there are any other active activities for this app
        let activeActivities = Activity<SpeedyWidgetAttributes>.activities.filter { $0.activityState == .active }
        if !activeActivities.isEmpty {
            print("Found existing active live activities, stopping them first")
            for activeActivity in activeActivities {
                Task {
                    await activeActivity.end(ActivityContent(state: SpeedyWidgetAttributes.ContentState(
                        currentSpeed: Int(currentSpeed),
                        speedLimit: speedLimit,
                        roadName: currentRoadName ?? "Unknown Road",
                        isSpeeding: isSpeeding,
                        unit: unitPreference.unitString,
                        isOnline: true,
                        batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : 1.0,
                        signalType: formattedCellularSignalStrength(),
                        altitude: formattedAltitude(),
                        isLiveMode: true
                    ), staleDate: nil))
                }
            }
            // Clear our reference
            activity = nil
            isLiveActivityActive = false
        }


        guard liveActivitiesEnabled else {
            Logger.log("Live activities are disabled by user preference", level: .info, category: "LocationManager")
            return
        }

        // Check if ActivityKit is available
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logger.log("Live activities are not enabled in system settings", level: .warning, category: "LocationManager")
            return
        }

        let attributes = SpeedyWidgetAttributes(appName: "Speedy")
        let state = SpeedyWidgetAttributes.ContentState(
            currentSpeed: Int(currentSpeed),
            speedLimit: speedLimit,
            roadName: currentRoadName ?? "Unknown Road",
            isSpeeding: isSpeeding,
            unit: unitPreference.unitString,
            isOnline: true,
            batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : 1.0,
            signalType: formattedCellularSignalStrength(),
            altitude: formattedAltitude(),
            isLiveMode: true
        )

        Logger.log("Starting live activity with state: speed=\(state.currentSpeed), limit=\(state.speedLimit), road=\(state.roadName), speeding=\(state.isSpeeding)", level: .info, category: "LocationManager")

        // Mark a start as in flight before the async request so concurrent callers bail.
        isStartingLiveActivity = true

        Task {
            do {
                let newActivity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
                await MainActor.run {
                    self.activity = newActivity
                    self.isLiveActivityActive = true
                    self.isStartingLiveActivity = false
                    self.startLiveActivityUpdateTimer()
                }


                // Refresh widgets when live activity starts
                SpeedyDataManager.shared.forceWidgetRefresh()
            } catch {
                Logger.log("Error starting live activity: \(error.localizedDescription)", level: .error, category: "LocationManager")
                Logger.log("Error details: \(error)", level: .error, category: "LocationManager")
                await MainActor.run {
                    self.isLiveActivityActive = false
                    self.isStartingLiveActivity = false
                    self.stopLiveActivityUpdateTimer()
                }
            }
        }
    }

    @available(iOS 16.1, *)
    private func rehydrateLiveActivity() {
        // If we already have one, nothing to do
        if activity != nil { return }


        // Get all active activities
        let activeActivities = Activity<SpeedyWidgetAttributes>.activities.filter { $0.activityState == .active }

        if activeActivities.count > 1 {
            // Multiple active activities - keep only the most recent one
            print("Found multiple active live activities (\(activeActivities.count)), cleaning up")
            let sortedActivities = activeActivities.sorted(by: { (activity1: Activity<SpeedyWidgetAttributes>, activity2: Activity<SpeedyWidgetAttributes>) in
                activity1.id < activity2.id
            })
            let keepActivity = sortedActivities.last!

            // End all but the most recent
            for activityToEnd in sortedActivities.dropLast() {
                Task {
                    await activityToEnd.end(ActivityContent(state: SpeedyWidgetAttributes.ContentState(
                        currentSpeed: Int(currentSpeed),
                        speedLimit: speedLimit,
                        roadName: currentRoadName ?? "Unknown Road",
                        isSpeeding: isSpeeding,
                        unit: unitPreference.unitString,
                        isOnline: true,
                        batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : 1.0,
                        signalType: formattedCellularSignalStrength(),
                        altitude: formattedAltitude(),
                        isLiveMode: true
                    ), staleDate: nil))
                }
            }

            // Use the most recent activity
            DispatchQueue.main.async { [weak self] in
                self?.activity = keepActivity
                self?.isLiveActivityActive = true
                self?.startLiveActivityUpdateTimer()
                self?.updateLiveActivity()
            }
        } else if let existing = activeActivities.first {
            // Single active activity - use it
            DispatchQueue.main.async { [weak self] in
                self?.activity = existing
                self?.isLiveActivityActive = true
                self?.startLiveActivityUpdateTimer()
                self?.updateLiveActivity()
            }
        }
    }

    @available(iOS 16.1, *)
    func updateLiveActivity() {
        // Ensure we have or create an activity
        if activity == nil || activity?.activityState != .active {
            rehydrateLiveActivity()
        }

        let state = SpeedyWidgetAttributes.ContentState(
            currentSpeed: Int(currentSpeed),
            speedLimit: speedLimit,
            roadName: currentRoadName ?? "Unknown Road",
            isSpeeding: isSpeeding,
            unit: unitPreference.unitString,
            isOnline: true,
            batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : 1.0,
            signalType: formattedCellularSignalStrength(),
            altitude: formattedAltitude(),
            isLiveMode: true,
            speedLimitIsInferred: speedLimitIsInferred
        )

        // Update all active activities to ensure CarPlay/lock screen stay in sync
        let activeActivities = Activity<SpeedyWidgetAttributes>.activities.filter { $0.activityState == .active }
        if activeActivities.isEmpty {
            // Do NOT resurrect a Live Activity here. Starting and stopping is owned
            // solely by manageLiveActivityBasedOnMovement() so that a Live Activity
            // stopped after parking stays stopped instead of being restarted on the
            // next location update / timer tick.
            return
        }

        Task {
            for act in activeActivities {
                await act.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
            }
        }
    }

        @available(iOS 16.1, *)
        private func manageLiveActivityBasedOnMovement() {
        // Only manage live activities if the user has enabled them
        guard liveActivitiesEnabled else {
            // If live activities are disabled but one is active, stop it
            if isLiveActivityActive {
                stopLiveActivity()
            }
            return
        }


        // Only show the Live Activity (Dynamic Island / lock screen) while the
        // device is actually moving. Hide it after a sustained stationary period so
        // it doesn't linger when parked, but tolerate brief stops (red lights, GPS
        // dips) without flickering.
        if isDeviceMoving {
            stationaryStart = nil
            if !isLiveActivityActive {
                startLiveActivity()
            }
        } else {
            if stationaryStart == nil {
                stationaryStart = Date()
            }
            if isLiveActivityActive,
               let since = stationaryStart,
               Date().timeIntervalSince(since) >= liveActivityStationaryTimeout {
                stopLiveActivity()
            }
        }
    }

    @available(iOS 16.1, *)
    func stopLiveActivity() {
        guard let activity = activity else { return }

        let state = SpeedyWidgetAttributes.ContentState(
            currentSpeed: Int(currentSpeed),
            speedLimit: speedLimit,
            roadName: currentRoadName ?? "Unknown Road",
            isSpeeding: isSpeeding,
            unit: unitPreference.unitString,
            isOnline: true,
            batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : 1.0,
            signalType: formattedCellularSignalStrength(),
            altitude: formattedAltitude(),
            isLiveMode: true
        )

        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil))
            self.activity = nil
            self.isLiveActivityActive = false
            self.isStartingLiveActivity = false
            print("Live activity stopped")
            self.stopLiveActivityUpdateTimer()

            // Refresh widgets when live activity stops
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    // MARK: - Live Activity Update Timer
    @available(iOS 16.1, *)
    private func startLiveActivityUpdateTimer() {
        // Avoid multiple timers
        liveActivityUpdateTimer?.invalidate()
        liveActivityUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isLiveActivityActive {
                self.updateLiveActivity()
            }
        }
    }

    @available(iOS 16.1, *)
    private func stopLiveActivityUpdateTimer() {
        liveActivityUpdateTimer?.invalidate()
        liveActivityUpdateTimer = nil
    }

    // Manual control for testing
    @available(iOS 16.1, *)
    func toggleLiveActivity() {
        // Toggle the user preference
        liveActivitiesEnabled.toggle()

        // Save the preference
        UserDefaults.standard.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled")

        print("Live activities preference toggled to: \(liveActivitiesEnabled)")

        if liveActivitiesEnabled {
            // User enabled live activities - start if not already active
            if !isLiveActivityActive {
                startLiveActivity()
            }
        } else {
            // User disabled live activities - stop if active
            if isLiveActivityActive {
                stopLiveActivity()
            }
        }

        // Refresh widgets when live activity preference changes
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Check if live activity is currently active
    var isActivityActive: Bool {
        return isLiveActivityActive
    }


    // Debug function to check live activity status
    @available(iOS 16.1, *)
    func debugLiveActivityStatus() {
        print("=== Live Activity Debug Info ===")
        print("User preference enabled: \(liveActivitiesEnabled)")
        print("Internal state active: \(isLiveActivityActive)")
        print("Activity object exists: \(activity != nil)")

        let authInfo = ActivityAuthorizationInfo()
        print("System activities enabled: \(authInfo.areActivitiesEnabled)")

        if let currentActivity = activity {
            print("Current activity ID: \(currentActivity.id)")
            print("Activity state: \(currentActivity.activityState)")
        }
        print("================================")

        // Refresh widgets when debugging live activity status
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Test function to manually start live activity
    @available(iOS 16.1, *)
    func testStartLiveActivity() {
        print("=== Testing Live Activity Start ===")
        // Force start a live activity for testing
        if activity == nil {
            startLiveActivity()
        } else {
            print("Live activity already exists, stopping first...")
            stopLiveActivity()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startLiveActivity()
            }
        }
        print("================================")

        // Refresh widgets when testing live activity
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Check if device is currently moving
    var isDeviceMoving: Bool {
        return currentSpeed > movementThreshold
    }

    // Check if enough time has passed since app startup to allow sounds
    private var shouldAllowSounds: Bool {
        let timeSinceStartup = Date().timeIntervalSince(appStartTime)
        return timeSinceStartup >= soundDelayAfterStartup
    }

    // Handle app state changes
    @available(iOS 16.1, *)
    func handleAppStateChange(isActive: Bool) {
        if isActive {
            // Reset startup time when app becomes active to allow sounds after delay
            appStartTime = Date()

            // App became active - start live activity if enabled and not already active
            if liveActivitiesEnabled && !isLiveActivityActive {
                startLiveActivity()
            }

            // Refresh widgets when app becomes active
            SpeedyDataManager.shared.forceWidgetRefresh()
        } else {
            // App became inactive - keep activity running, but pause internal updates
            if isLiveActivityActive {
                Logger.log("App became inactive, pausing live activity updates (keeping activity running)", level: .info, category: "LocationManager")
                stopLiveActivityUpdateTimer()
            }
        }
    }

    @objc private func handleNetworkCameOnline() {
        print("Network came online, triggering immediate speed limit lookup")
        if let location = locationManager.location {
            // Force a speed limit lookup when network comes online
            speedLimitService.forceLookupSpeedLimit(for: location.coordinate,
                                                     course: location.course >= 0 ? location.course : nil)
        }
    }

    deinit {
        speedUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Logging

    fileprivate func log(_ message: String, level: String = "INFO") {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        print("\(timestamp) [\(level)] LocationManager: \(message)")
    }

    // Method to manually test speed limit refresh
    func testSpeedLimitRefresh() {
        print("=== Testing Speed Limit Refresh ===")
        print("Before refresh - Speed limit: \(speedLimit), Road: \(currentRoadName ?? "nil")")

        // Force refresh the speed limit
        forceRefreshSpeedLimit()

        print("After refresh - Speed limit: \(speedLimit), Road: \(currentRoadName ?? "nil")")
        print("================================")

        // Refresh widgets when testing speed limit refresh
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Method to debug Live Activity status
    @available(iOS 16.1, *)
    func debugLiveActivity() {
        print("=== Live Activity Debug Info ===")
        print("Live activities enabled: \(liveActivitiesEnabled)")
        print("Live activity active: \(isLiveActivityActive)")
        print("Activity object: \(activity != nil ? "exists" : "nil")")
        print("Live activities preference saved: \(UserDefaults.standard.bool(forKey: "liveActivitiesEnabled"))")
        print("================================")

        // Refresh widgets when debugging live activity
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Method to debug speed limit issues
    func debugSpeedLimit() {
        print("=== Speed Limit Debug Info ===")
        print("Current speed limit: \(speedLimit)")
        print("Speed limit known: \(speedLimitKnown)")
        print("Is looking up speed limit: \(isLookingUpSpeedLimit)")
        print("Current road name: \(currentRoadName ?? "nil")")
        print("Network online: \(isNetworkOnline)")
        print("Speed limit service current limit: \(speedLimitService.currentSpeedLimit ?? -1)")
        print("Speed limit service current road: \(speedLimitService.currentRoadName ?? "nil")")
        print("Speed limit service loading: \(speedLimitService.isLoading)")
        print("Speed limit service error: \(speedLimitService.errorMessage ?? "none")")
        print("================================")

        // Refresh widgets when debugging speed limit
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Method to test widget data sharing
    func testWidgetDataSharing() {
        print("=== Testing Widget Data Sharing ===")

        // Test saving some sample data
        let testSpeed = 65
        let testLimit = 55
        let testRoad = "Test Highway"
        let testUnit = "MPH"

        print("Saving test data: Speed=\(testSpeed), Limit=\(testLimit), Road=\(testRoad)")

        SpeedyDataManager.shared.saveWidgetData(
            currentSpeed: testSpeed,
            speedLimit: testLimit,
            roadName: testRoad,
            isSpeeding: testSpeed > testLimit,
            unit: testUnit,
            batteryLevel: 0.85,
            altitude: "1,234 ft"
        )

        // Test loading the data back
        if let loadedData = SpeedyDataManager.shared.loadWidgetData() {
            print("Successfully loaded test data: \(loadedData)")
        } else {
            print("Failed to load test data")
        }

        print("================================")

        // Refresh widgets when testing widget data sharing
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    // Method to force save current data to widgets
    func forceSaveCurrentDataToWidgets() {
        print("=== Force Saving Current Data to Widgets ===")
        print("Current speed: \(currentSpeed)")
        print("Speed limit: \(speedLimit)")
        print("Road name: \(currentRoadName ?? "nil")")
        print("Is speeding: \(isSpeeding)")
        print("Unit: \(unitPreference.unitString)")

        // Force save current data
        saveWidgetData()

        // Force widget refresh
        SpeedyDataManager.shared.forceWidgetRefresh()

        print("Data saved and widgets refreshed")
        print("================================")
    }

    // Method to test widget extension directly
    func testWidgetExtensionDirectly() {
        print("=== Testing Widget Extension Directly ===")

        // Save test data
        SpeedyDataManager.shared.saveWidgetData(
            currentSpeed: 75,
            speedLimit: 55,
            roadName: "Test Highway",
            isSpeeding: true,
            unit: "MPH",
            batteryLevel: 0.85,
            altitude: "1,234 ft"
        )

        // Force multiple widget refreshes
        for i in 1...5 {
            print("Widget refresh attempt \(i)")
            SpeedyDataManager.shared.forceWidgetRefresh()
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("Widget extension test completed")
        print("================================")
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationManager: CLLocationManagerDelegate {
    private func degreesToRadians(_ degrees: Double) -> Double { return degrees * .pi / 180.0 }
    private func radiansToDegrees(_ radians: Double) -> Double { return radians * 180.0 / .pi }

    private func getDominantTravelDirection() -> Double? {
        guard travelDirectionHistory.count >= 3 else { return nil }

        // Group directions into 45-degree sectors to find the most common direction
        var directionSectors: [Int: Int] = [:]

        for direction in travelDirectionHistory {
            let sector = Int((direction + 22.5) / 45.0) % 8 // 8 sectors of 45 degrees each
            directionSectors[sector, default: 0] += 1
        }

        // Find the most common sector
        let mostCommonSector = directionSectors.max(by: { $0.value < $1.value })?.key ?? 0

        // Calculate the average direction within the most common sector
        let sectorStart = Double(mostCommonSector) * 45.0
        let sectorEnd = sectorStart + 45.0

        var sectorDirections: [Double] = []
        for direction in travelDirectionHistory {
            let normalizedDirection = direction < 0 ? direction + 360.0 : direction
            if normalizedDirection >= sectorStart && normalizedDirection < sectorEnd {
                sectorDirections.append(direction)
            }
        }

        if sectorDirections.isEmpty { return nil }

        // Return the median direction for stability
        let sortedDirections = sectorDirections.sorted()
        let medianIndex = sortedDirections.count / 2
        return sortedDirections[medianIndex]
    }

    private func isRoadParallelToTravelDirection(roadBearing: Double, travelDirection: Double) -> Bool {
        let angleDifference = abs(roadBearing - travelDirection)
        let normalizedDifference = min(angleDifference, 360.0 - angleDifference)

        // Road is parallel if it's within 30 degrees of travel direction
        return normalizedDifference <= 30.0
    }

    private func isRoadPerpendicularToTravelDirection(roadBearing: Double, travelDirection: Double) -> Bool {
        let angleDifference = abs(roadBearing - travelDirection)
        let normalizedDifference = min(angleDifference, 360.0 - angleDifference)

        // Road is perpendicular if it's within 15 degrees of 90 degrees from travel direction
        return abs(normalizedDifference - 90.0) <= 15.0
    }

    private func getBearingBetween(point1: CLLocation, point2: CLLocation) -> Double {
        let lat1 = degreesToRadians(point1.coordinate.latitude)
        let lon1 = degreesToRadians(point1.coordinate.longitude)

        let lat2 = degreesToRadians(point2.coordinate.latitude)
        let lon2 = degreesToRadians(point2.coordinate.longitude)

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)

        return radiansToDegrees(radiansBearing)
    }

    private func standardizeRoadName(_ name: String) -> String {
        var standardizedName = name

        // Common abbreviations
        standardizedName = standardizedName.replacingOccurrences(of: "Street", with: "St", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Avenue", with: "Ave", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Boulevard", with: "Blvd", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Road", with: "Rd", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Drive", with: "Dr", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Lane", with: "Ln", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Place", with: "Pl", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Court", with: "Ct", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Terrace", with: "Ter", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Parkway", with: "Pkwy", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Circle", with: "Cir", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Highway", with: "Hwy", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Freeway", with: "Fwy", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Expressway", with: "Expy", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Square", with: "Sq", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Trail", with: "Trl", options: .caseInsensitive)
        standardizedName = standardizedName.replacingOccurrences(of: "Way", with: "Wy", options: .caseInsensitive)

        // Add more as needed

        return standardizedName
    }

    private func updateRoadName() {
        guard locationHistory.count >= 2 else { return }

        let now = Date()
        if now.timeIntervalSince(lastRoadNameCheck) < 5 {
            return
        }
        lastRoadNameCheck = now

        let lastLocation = locationHistory[locationHistory.count - 1]
        let previousLocation = locationHistory[locationHistory.count - 2]

        // Calculate current travel direction
        let currentBearing = getBearingBetween(point1: previousLocation, point2: lastLocation)

        // Add to direction history for smoothing
        travelDirectionHistory.append(currentBearing)
        if travelDirectionHistory.count > maxDirectionHistory {
            travelDirectionHistory.removeFirst()
        }

        // Get dominant travel direction over time
        let dominantDirection = getDominantTravelDirection()

        // Check if we should allow road name changes (stability check)

        geocoder.reverseGeocodeLocation(lastLocation) { [weak self] (placemarks, error) in
            guard let self = self, error == nil else { return }

            var bestPlacemark: CLPlacemark? = nil
            var bestScore = Double.leastNormalMagnitude

            for placemark in placemarks ?? [] {
                guard let placemarkLocation = placemark.location,
                      let roadName = placemark.thoroughfare else { continue }

                // Calculate road bearing from current location to road location
                let roadBearing = self.getBearingBetween(point1: lastLocation, point2: placemarkLocation)

                // Score the road based on multiple factors
                var score = 0.0

                // Factor 1: Distance to road (closer is better)
                let distance = lastLocation.distance(from: placemarkLocation)
                let distanceScore = max(0, 100 - distance) / 100.0 // 0 to 1, closer is better
                score += distanceScore * 0.3

                // Factor 2: Road orientation vs travel direction (parallel is better)
                if let dominantDirection = dominantDirection {
                    if self.isRoadParallelToTravelDirection(roadBearing: roadBearing, travelDirection: dominantDirection) {
                        score += 0.4 // High score for parallel roads
                    } else if self.isRoadPerpendicularToTravelDirection(roadBearing: roadBearing, travelDirection: dominantDirection) {
                        score -= 0.3 // Penalty for perpendicular roads (cross streets)
                    } else {
                        score += 0.1 // Neutral score for other orientations
                    }
                }

                // Factor 3: Road name stability (keep current road if possible)
                if let currentRoad = self.internalRoadName, roadName == currentRoad {
                    score += 0.2 // Bonus for keeping current road name
                }

                // Factor 4: Road type preference (major roads over minor ones)
                if let roadType = placemark.thoroughfare {
                    let majorRoadTypes = ["Highway", "Freeway", "Expressway", "Boulevard", "Avenue"]
                    let isMajorRoad = majorRoadTypes.contains { roadType.contains($0) }
                    score += isMajorRoad ? 0.1 : 0.0
                }

                // Update best placemark if this one has a higher score
                if score > bestScore {
                    bestScore = score
                    bestPlacemark = placemark
                }
            }

            if let bestPlacemark = bestPlacemark, let roadName = bestPlacemark.thoroughfare {
                let standardizedRoadName = self.standardizeRoadName(roadName)

                // Only update if road name actually changed or we have no current road
                if standardizedRoadName != self.internalRoadName {
                    DispatchQueue.main.async {
                        // Update the private property first
                        self.internalRoadName = standardizedRoadName
                        self.lastRoadNameChange = now
                        self.roadNameConfidence = min(1.0, bestScore)
                        // Update the published property
                        self.currentRoadName = standardizedRoadName
                        self.saveWidgetData() // Update widget data
                        print("Road name updated to: \(standardizedRoadName) (confidence: \(self.roadNameConfidence))")
                    }
                }

                // Extract town/city information
                DispatchQueue.main.async {
                    let town = bestPlacemark.locality ?? bestPlacemark.administrativeArea ?? bestPlacemark.subLocality
                    if town != self.currentTown {
                        self.currentTown = town
                        self.saveWidgetData() // Update widget data
                    }
                }
            } else {
                // No road found, but don't clear current road name immediately
                DispatchQueue.main.async {
                    if self.internalRoadName != nil {
                        // Reduce confidence but keep road name for a bit
                        self.roadNameConfidence = max(0.0, self.roadNameConfidence - 0.1)

                        // Only clear if confidence is very low
                        if self.roadNameConfidence <= 0.1 {
                            self.internalRoadName = nil
                            self.currentRoadName = nil
                            self.resetSpeedLimitForUnknownRoad()
                            print("Road name cleared due to low confidence")
                        }
                    }
                }
            }
        }
    }

    private func resetSpeedLimitForUnknownRoad() {
        speedLimit = 0
        speedLimitKnown = false
        // Reset speeding state since we don't know the speed limit
        isSpeeding = false
        wasSpeeding = false
        print("Road unknown, resetting speed limit and speeding state")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Mark GPS lock as acquired on valid location update
        if location.horizontalAccuracy >= 0 {
            if !hasGPSLock { self.log("GPS lock acquired (accuracy: \(location.horizontalAccuracy)m)", level: "INFO") }
            hasGPSLock = true
        }

        if let lastLocation = locationHistory.last {
            let distance = location.distance(from: lastLocation)
            // Lowered from 500m so freeway on-ramps / arterial transitions trigger a
            // fresh speed-limit lookup quickly instead of waiting on the 5s timer.
            if distance > 150 {
                speedLimitService.forceLookupSpeedLimit(for: location.coordinate,
                                                         course: location.course >= 0 ? location.course : nil)
                updateRoadName()
            }
        }

        // Add the new location to the history
        locationHistory.append(location)

        // Keep the history to a reasonable size
        if locationHistory.count > 10 {
            locationHistory.removeFirst()
        }

        updateRoadName()

        // Refresh widgets on location updates to ensure real-time data
        DispatchQueue.main.async {
            SpeedyDataManager.shared.forceWidgetRefresh()
        }

        // Additional widget refresh after a short delay to ensure data is saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.locationStatus = status

            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationManager.startUpdatingLocation()
                // Immediately attempt to get road name and speed limit on startup
                if let location = self.locationManager.location {
                    // Force immediate speed limit lookup on startup
                    self.speedLimitService.forceLookupSpeedLimit(for: location.coordinate,
                                                                 course: location.course >= 0 ? location.course : nil)
                    self.updateRoadName()
                    if location.horizontalAccuracy >= 0 { self.hasGPSLock = true }
                }
                // Refresh widgets when location access is granted
                DispatchQueue.main.async {
                    SpeedyDataManager.shared.forceWidgetRefresh()
                }
            case .denied, .restricted:
                self.locationManager.stopUpdatingLocation()
                if self.hasGPSLock { self.log("GPS lock lost due to authorization change", level: "WARN") }
                self.hasGPSLock = false
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if hasGPSLock { self.log("GPS lock lost due to error: \(error.localizedDescription)", level: "WARN") }
        hasGPSLock = false

        if let clError = error as? CLError, clError.code == .locationUnknown {
            self.log("Location manager error: kCLErrorDomain locationUnknown", level: "ERROR")
        } else {
            self.log("Location manager error: \(error.localizedDescription)", level: "ERROR")
        }
    }

    // MARK: - Helper Methods for Display

    func formattedAltitude() -> String {
        let altitudeInMeters = currentAltitude
        if unitPreference == .metric {
            // Convert to meters (already in meters)
            return String(format: "%.0f m", altitudeInMeters)
        } else {
            // Convert to feet
            let altitudeInFeet = altitudeInMeters * 3.28084
            return String(format: "%.0f ft", altitudeInFeet)
        }
    }

    func formattedCellularSignalStrength() -> String {
        switch cellularSignalStrength {
        case 0:
            return "No Signal"
        case 1:
            return "2G"
        case 2:
            return "3G"
        case 3:
            return "LTE"
        case 4:
            return "5G"
        default:
            // Fallback for simulator or restricted environments
            #if targetEnvironment(simulator)
            return "LTE"
            #else
            return "GPS"
            #endif
        }
    }

    func cellularSignalStrengthColorName() -> String {
        switch cellularSignalStrength {
        case 0:
            return "red"      // No signal
        case 1:
            return "orange"   // 2G - older, slower network
        case 2:
            return "yellow"   // 3G - moderate network
        case 3:
            return "orange"        // 4G - good network (changed from lightblue to orange)
        case 4:
            return "green"    // 5G - best network
        default:
            return "gray"
        }
    }

    // MARK: - Manual Signal Refresh (for debugging)
    func refreshCellularSignal() {
        print("LocationManager: Manually refreshing cellular signal strength")
        updateCellularSignalStrength()
    }

    private func startCellularSignalMonitoring() {
        // Only start cellular monitoring on physical devices, not simulator
        #if !targetEnvironment(simulator)
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // For widget extensions, assume cellular connection if we have any network
                self.cellularSignalStrength = self.hasCellularConnection() ? 3 : 0
            }
            return
        }

        self.telephonyInfo = CTTelephonyNetworkInfo()
        // Check signal strength immediately
        updateCellularSignalStrength()

        // Start a timer to check cellular signal strength every 5 seconds
        // Use main thread for timer to ensure proper execution
        DispatchQueue.main.async { [weak self] in
            Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.updateCellularSignalStrength()
            }
        }
        #else
        // For simulator, set a default signal type (independent of network status)
        DispatchQueue.main.async {
            self.cellularSignalStrength = 3 // Default to 4G for simulator
        }
        #endif
    }

    private func updateCellularSignalStrength() {
        // Ensure we're on the main thread for CTTelephonyNetworkInfo
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Use persistent CoreTelephony instance if available
            guard let networkInfo = self.telephonyInfo else {
                // If we can't get telephony info, check if we have any cellular connection
                // This is independent of network connectivity (which can fail due to DNS, routing, etc.)
                self.cellularSignalStrength = self.hasCellularConnection() ? 3 : 0
                return
            }

            // Get the current radio access technology
            if let currentRadioTech = networkInfo.serviceCurrentRadioAccessTechnology?.values.first {
                // Determine signal quality based on radio technology
                // This is a best-effort approach since iOS doesn't provide direct signal strength
                var signalQuality: Int = 0

                switch currentRadioTech {
                case CTRadioAccessTechnologyGPRS,
                     CTRadioAccessTechnologyEdge:
                    // 2G networks - typically lower signal quality
                    signalQuality = 1
                case CTRadioAccessTechnologyWCDMA,
                     CTRadioAccessTechnologyHSDPA,
                     CTRadioAccessTechnologyHSUPA:
                    // 3G networks - moderate signal quality
                    signalQuality = 2
                case CTRadioAccessTechnologyLTE:
                    // 4G networks - good signal quality
                    signalQuality = 3
                case CTRadioAccessTechnologyNRNSA,
                     CTRadioAccessTechnologyNR:
                    // 5G networks - excellent signal quality
                    signalQuality = 4
                default:
                    // Unknown or no network
                    signalQuality = 0
                }

                // Additional check: if we have radio technology info, we can be more confident about signal
                if signalQuality == 0 {
                    // If we have radio technology info but no signal quality determined,
                    // assume at least fair signal
                    signalQuality = 2
                }

                self.cellularSignalStrength = signalQuality
            } else {
                // No radio technology info, but check if we have cellular connection
                self.cellularSignalStrength = self.hasCellularConnection() ? 2 : 0
            }
        }
    }

    // MARK: - Cellular Connection Detection
    private func hasCellularConnection() -> Bool {
        // Check if we have any cellular carrier information
        if let networkInfo = telephonyInfo {
            // Use radio access technology as the primary indicator
            // This is more reliable than carrier name APIs which are deprecated
            if let radioAccessTechnology = networkInfo.currentRadioAccessTechnology {
                // If we have radio access technology info, we have cellular connection
                return !radioAccessTechnology.isEmpty
            }
        }

        // Additional check: if we have radio access technology, we likely have cellular
        if let networkInfo = telephonyInfo,
           let radioTech = networkInfo.serviceCurrentRadioAccessTechnology?.values.first,
           !radioTech.isEmpty {
            return true
        }

        return false
    }

    // MARK: - Widget Data Management
    private func saveWidgetData() {
        // Convert speed to appropriate unit
        let speedInDisplayUnit: Int
        let unitString: String

        switch unitPreference {
        case .imperial:
            speedInDisplayUnit = Int(currentSpeed)
            unitString = unitPreference.unitString
        case .metric:
            speedInDisplayUnit = Int(currentSpeed * 1.60934) // Convert MPH to KPH
            unitString = unitPreference.unitString
        @unknown default:
            // Fallback to imperial if somehow we get an unknown case
            speedInDisplayUnit = Int(currentSpeed)
            unitString = Unit.imperial.unitString
        }

        // Get battery level
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel

        // Format altitude
        let altitudeString = String(format: "%.0f ft", currentAltitude * 3.28084) // Convert meters to feet

        // Get signal type
        let signalTypeString = formattedCellularSignalStrength()

        // Save data to shared container for widget
        SpeedyDataManager.shared.saveWidgetData(
            currentSpeed: speedInDisplayUnit,
            speedLimit: speedLimit,
            roadName: currentRoadName ?? "Unknown Road",
            isSpeeding: isSpeeding,
            unit: unitString,
            batteryLevel: batteryLevel >= 0 ? batteryLevel : 1.0,
            altitude: altitudeString,
            signalType: signalTypeString,
            speedLimitIsInferred: speedLimitIsInferred
        )

        // Force additional widget refresh for critical updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SpeedyDataManager.shared.forceWidgetRefresh()
        }

        // Schedule additional widget refresh for background updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            SpeedyDataManager.shared.forceWidgetRefresh()
        }

        // Also update live activity if active
        if isLiveActivityActive {
            if #available(iOS 16.1, *) {
                updateLiveActivity()
            }
        }
    }
}
