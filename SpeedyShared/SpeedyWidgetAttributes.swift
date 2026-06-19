
import Foundation

// ActivityKit is only available in iOS 16.1+
#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
public struct SpeedyWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var currentSpeed: Int
        public var speedLimit: Int
        public var roadName: String
        public var isSpeeding: Bool
        public var unit: String
        public var isOnline: Bool
        public var batteryLevel: Float
        public var signalType: String
        public var altitude: String
        public var isLiveMode: Bool
        /// True when `speedLimit` is a statutory default (inferred), not posted.
        public var speedLimitIsInferred: Bool

        public init(currentSpeed: Int, speedLimit: Int, roadName: String, isSpeeding: Bool, unit: String, isOnline: Bool = true, batteryLevel: Float = 1.0, signalType: String = "GPS", altitude: String = "0 ft", isLiveMode: Bool = true, speedLimitIsInferred: Bool = false) {
            self.currentSpeed = currentSpeed
            self.speedLimit = speedLimit
            self.roadName = roadName
            self.isSpeeding = isSpeeding
            self.unit = unit
            self.isOnline = isOnline
            self.batteryLevel = batteryLevel
            self.signalType = signalType
            self.altitude = altitude
            self.isLiveMode = isLiveMode
            self.speedLimitIsInferred = speedLimitIsInferred
        }
    }

    public var appName: String

    public init(appName: String) {
        self.appName = appName
    }
}
#endif

// Fallback for iOS versions < 16.1
public struct SpeedyWidgetAttributesFallback: Codable, Hashable {
    public struct ContentState: Codable, Hashable {
        public var currentSpeed: Int
        public var speedLimit: Int
        public var roadName: String
        public var isSpeeding: Bool
        public var unit: String
        public var isOnline: Bool
        public var batteryLevel: Float
        public var signalType: String
        public var altitude: String
        public var isLiveMode: Bool
        /// True when `speedLimit` is a statutory default (inferred), not posted.
        public var speedLimitIsInferred: Bool

        public init(currentSpeed: Int, speedLimit: Int, roadName: String, isSpeeding: Bool, unit: String, isOnline: Bool = true, batteryLevel: Float = 1.0, signalType: String = "GPS", altitude: String = "0 ft", isLiveMode: Bool = true, speedLimitIsInferred: Bool = false) {
            self.currentSpeed = currentSpeed
            self.speedLimit = speedLimit
            self.roadName = roadName
            self.isSpeeding = isSpeeding
            self.unit = unit
            self.isOnline = isOnline
            self.batteryLevel = batteryLevel
            self.signalType = signalType
            self.altitude = altitude
            self.isLiveMode = isLiveMode
            self.speedLimitIsInferred = speedLimitIsInferred
        }
    }

    public var appName: String

    public init(appName: String) {
        self.appName = appName
    }
}
