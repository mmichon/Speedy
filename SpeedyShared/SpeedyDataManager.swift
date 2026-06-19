//
//  SpeedyDataManager.swift
//  SpeedyShared
//
//  Created by Michael Michon on 8/19/25.
//

import Foundation
import WidgetKit
import Combine
import UIKit

public class SpeedyDataManager: ObservableObject {
    public static let shared = SpeedyDataManager()

    private let userDefaults = UserDefaults.sharedAppGroup
    private var periodicRefreshTimer: Timer?
    private var liveModeRefreshTimer: Timer?
    private var isLiveModeActive: Bool = false

    private init() {
        // Set up app state monitoring for widget refresh
        setupAppStateMonitoring()
    }

    // MARK: - Save Data
    public func saveWidgetData(currentSpeed: Int, speedLimit: Int, roadName: String, isSpeeding: Bool, unit: String, batteryLevel: Float = 1.0, altitude: String = "0 ft", signalType: String = "GPS", speedLimitIsInferred: Bool = false) {

        let widgetData = SpeedyWidgetData(
            currentSpeed: currentSpeed,
            speedLimit: speedLimit,
            roadName: roadName,
            isSpeeding: isSpeeding,
            unit: unit
        )

        // Save individual values for backward compatibility
        userDefaults.set(currentSpeed, forKey: SpeedyDataKeys.currentSpeed)
        userDefaults.set(speedLimit, forKey: SpeedyDataKeys.speedLimit)
        userDefaults.set(roadName, forKey: SpeedyDataKeys.roadName)
        userDefaults.set(isSpeeding, forKey: SpeedyDataKeys.isSpeeding)
        userDefaults.set(unit, forKey: SpeedyDataKeys.unit)
        userDefaults.set(batteryLevel, forKey: SpeedyDataKeys.batteryLevel)
        userDefaults.set(altitude, forKey: SpeedyDataKeys.altitude)
        userDefaults.set(signalType, forKey: SpeedyDataKeys.signalType)
        userDefaults.set(speedLimitIsInferred, forKey: SpeedyDataKeys.speedLimitIsInferred)
        userDefaults.set(Date(), forKey: SpeedyDataKeys.lastUpdated)

        // Save the complete widget data object
        if let encodedData = try? JSONEncoder().encode(widgetData) {
            userDefaults.set(encodedData, forKey: SpeedyDataKeys.widgetData)
        } else {
            print("SpeedyDataManager: Failed to encode widget data")
        }

        userDefaults.synchronize()

        // Enhanced widget refresh mechanism
        refreshAllWidgets()
    }

    // MARK: - Enhanced Widget Refresh
    private func refreshAllWidgets() {
        // Force immediate timeline reload for all widgets
        WidgetCenter.shared.reloadAllTimelines()

        // Reload live activity widget with delay to ensure proper refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            WidgetCenter.shared.reloadTimelines(ofKind: "SpeedyWidgetLiveActivity")
        }

        // Additional refresh after a longer delay to catch any missed updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Schedule periodic refresh to ensure widgets stay updated
        schedulePeriodicWidgetRefresh()
    }

    private func schedulePeriodicWidgetRefresh() {
        // Cancel any existing timer
        periodicRefreshTimer?.invalidate()

        // Create a new timer that refreshes widgets every 5 seconds
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.performBackgroundWidgetRefresh()
        }
    }

    private func performBackgroundWidgetRefresh() {
        // Start a background task to ensure widget refresh completes
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WidgetRefresh") {
            // Clean up background task
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        // Perform widget refresh
        WidgetCenter.shared.reloadAllTimelines()

        // End background task after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
    }

    // MARK: - Manual Widget Refresh
    public func forceWidgetRefresh() {
        refreshAllWidgets()
    }

    // MARK: - Widget Status Check
    public func checkWidgetStatus() {
        print("SpeedyDataManager: Checking widget status...")

        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let configurations):
                print("SpeedyDataManager: Found \(configurations.count) widget configurations")
                for config in configurations {
                    print("SpeedyDataManager: Widget kind: \(config.kind), family: \(config.family)")
                }
            case .failure(let error):
                print("SpeedyDataManager: Error getting widget configurations: \(error)")
            }
        }
    }

    // MARK: - Aggressive Widget Refresh
    public func forceAggressiveWidgetRefresh() {
        print("SpeedyDataManager: Starting aggressive widget refresh...")

        // Method 1: Standard reload
        WidgetCenter.shared.reloadAllTimelines()

        // Method 2: Reload live activity widget with delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WidgetCenter.shared.reloadTimelines(ofKind: "SpeedyWidgetLiveActivity")
        }

        // Method 3: Force reload all again after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Method 4: Check widget status and try again
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.checkWidgetStatus()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Force Widget Refresh by Data Update
    public func forceWidgetRefreshByDataUpdate() {
        print("SpeedyDataManager: Forcing widget refresh by updating data...")

        // Get current data
        if let currentData = loadWidgetData() {
            // Save the same data with a new timestamp to force refresh
            saveWidgetData(
                currentSpeed: currentData.currentSpeed,
                speedLimit: currentData.speedLimit,
                roadName: currentData.roadName,
                isSpeeding: currentData.isSpeeding,
                unit: currentData.unit,
                batteryLevel: 0.85, // Use a fixed battery level for testing
                altitude: "1,234 ft", // Use a fixed altitude for testing
                signalType: "GPS"
            )
        } else {
            // If no data exists, save test data
            saveWidgetData(
                currentSpeed: 0,
                speedLimit: 0,
                roadName: "Unknown Road",
                isSpeeding: false,
                unit: "MPH",
                batteryLevel: 0.85,
                altitude: "1,234 ft",
                signalType: "GPS"
            )
        }
    }

    // MARK: - App State Monitoring
    private func setupAppStateMonitoring() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("SpeedyDataManager: App became active, refreshing widgets")
            self.checkWidgetStatus()
            self.refreshAllWidgets()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.refreshAllWidgets()
        }
    }

    // MARK: - Load Data
    public func loadWidgetData() -> SpeedyWidgetData? {

        // Try to load the complete widget data object first
        if let data = userDefaults.data(forKey: SpeedyDataKeys.widgetData),
           let widgetData = try? JSONDecoder().decode(SpeedyWidgetData.self, from: data) {
            return widgetData
        }

        // Fallback to individual values
        let currentSpeed = userDefaults.integer(forKey: SpeedyDataKeys.currentSpeed)
        let speedLimit = userDefaults.integer(forKey: SpeedyDataKeys.speedLimit)
        let roadName = userDefaults.string(forKey: SpeedyDataKeys.roadName) ?? "Unknown Road"
        let isSpeeding = userDefaults.bool(forKey: SpeedyDataKeys.isSpeeding)
        let unit = userDefaults.string(forKey: SpeedyDataKeys.unit) ?? Unit.imperial.unitString
        let lastUpdated = userDefaults.object(forKey: SpeedyDataKeys.lastUpdated) as? Date ?? Date()

        return SpeedyWidgetData(
            currentSpeed: currentSpeed,
            speedLimit: speedLimit,
            roadName: roadName,
            isSpeeding: isSpeeding,
            unit: unit,
            lastUpdated: lastUpdated
        )
    }

    // MARK: - Clear Data
    public func clearWidgetData() {
        userDefaults.removeObject(forKey: SpeedyDataKeys.currentSpeed)
        userDefaults.removeObject(forKey: SpeedyDataKeys.speedLimit)
        userDefaults.removeObject(forKey: SpeedyDataKeys.roadName)
        userDefaults.removeObject(forKey: SpeedyDataKeys.isSpeeding)
        userDefaults.removeObject(forKey: SpeedyDataKeys.unit)
        userDefaults.removeObject(forKey: SpeedyDataKeys.signalType)
        userDefaults.removeObject(forKey: SpeedyDataKeys.lastUpdated)
        userDefaults.removeObject(forKey: SpeedyDataKeys.widgetData)
        userDefaults.synchronize()
    }

    // MARK: - Test App Group Configuration
    public func testAppGroupConfiguration() {
        print("SpeedyDataManager: Testing App Group configuration...")
        print("SpeedyDataManager: App Group ID: \(UserDefaults.appGroupIdentifier)")
        print("SpeedyDataManager: Shared UserDefaults suite: \(UserDefaults.sharedAppGroup)")

        // Test writing and reading data
        let testKey = "testAppGroup"
        let testValue = "App Group Test - \(Date())"

        userDefaults.set(testValue, forKey: testKey)
        userDefaults.synchronize()

        let readValue = userDefaults.string(forKey: testKey)
        print("SpeedyDataManager: Test write/read - Wrote: \(testValue), Read: \(readValue ?? "nil")")

        // Clean up test data
        userDefaults.removeObject(forKey: testKey)
        userDefaults.synchronize()
    }

    // MARK: - Debug Widget Data
    public func debugWidgetData() {
        print("SpeedyDataManager: Debugging widget data...")

        // Check individual values
        let currentSpeed = userDefaults.integer(forKey: SpeedyDataKeys.currentSpeed)
        let speedLimit = userDefaults.integer(forKey: SpeedyDataKeys.speedLimit)
        let roadName = userDefaults.string(forKey: SpeedyDataKeys.roadName) ?? "nil"
        let isSpeeding = userDefaults.bool(forKey: SpeedyDataKeys.isSpeeding)
        let unit = userDefaults.string(forKey: SpeedyDataKeys.unit) ?? "nil"
        let batteryLevel = userDefaults.float(forKey: SpeedyDataKeys.batteryLevel)
        let altitude = userDefaults.string(forKey: SpeedyDataKeys.altitude) ?? "nil"
        let signalType = userDefaults.string(forKey: SpeedyDataKeys.signalType) ?? "nil"
        let lastUpdated = userDefaults.object(forKey: SpeedyDataKeys.lastUpdated) as? Date ?? Date.distantPast

        print("SpeedyDataManager: Current Speed: \(currentSpeed)")
        print("SpeedyDataManager: Speed Limit: \(speedLimit)")
        print("SpeedyDataManager: Road Name: \(roadName)")
        print("SpeedyDataManager: Is Speeding: \(isSpeeding)")
        print("SpeedyDataManager: Unit: \(unit)")
        print("SpeedyDataManager: Battery Level: \(batteryLevel)")
        print("SpeedyDataManager: Altitude: \(altitude)")
        print("SpeedyDataManager: Signal Type: \(signalType)")
        print("SpeedyDataManager: Last Updated: \(lastUpdated)")

        // Check if we can load the complete widget data
        if let widgetData = loadWidgetData() {
            print("SpeedyDataManager: Successfully loaded complete widget data")
            print("SpeedyDataManager: Widget Data - Speed: \(widgetData.currentSpeed), Limit: \(widgetData.speedLimit), Road: \(widgetData.roadName)")
        } else {
            print("SpeedyDataManager: Failed to load complete widget data")
        }

        // Test app group configuration
        testAppGroupConfiguration()

        // Check widget status
        checkWidgetStatus()
    }

    // MARK: - Live Mode Management
    public func startLiveMode() {
        print("SpeedyDataManager: Starting live mode with 1-second refresh")
        isLiveModeActive = true

        // Cancel any existing live mode timer
        liveModeRefreshTimer?.invalidate()

        // Start 1-second refresh timer for live mode
        liveModeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.performLiveModeRefresh()
        }
    }

    public func stopLiveMode() {
        print("SpeedyDataManager: Stopping live mode")
        isLiveModeActive = false
        liveModeRefreshTimer?.invalidate()
        liveModeRefreshTimer = nil
    }

    private func performLiveModeRefresh() {
        guard isLiveModeActive else { return }

        // Force home-screen widget timelines to refresh in live mode.
        // Note: the Live Activity itself is NOT refreshed here — it updates via
        // Activity.update() in LocationManager. ActivityConfigurations have no
        // timeline "kind", so reloadTimelines(ofKind:) for them would be a no-op.
        WidgetCenter.shared.reloadAllTimelines()

        // Live mode refresh performed (log suppressed)
    }

    public func isLiveModeRunning() -> Bool {
        return isLiveModeActive
    }

    // MARK: - Cleanup
    deinit {
        periodicRefreshTimer?.invalidate()
        liveModeRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
