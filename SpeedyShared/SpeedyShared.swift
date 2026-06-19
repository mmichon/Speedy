//
//  SpeedyShared.swift
//  SpeedyShared
//
//  Created by Michael Michon on 8/19/25.
//

import Foundation

public enum Unit: String, CaseIterable, Identifiable {
    case imperial = "Imperial"
    case metric = "Metric"

    public var id: String { self.rawValue }

    // Computed properties for backward compatibility
    public var isImperial: Bool { self == .imperial }
    public var isMetric: Bool { self == .metric }

    // Unit display strings
    public var unitString: String {
        switch self {
        case .imperial:
            return "MPH"
        case .metric:
            return "KPH"
        }
    }
}

// MARK: - Shared Data Model
public struct SpeedyWidgetData: Codable {
    public let currentSpeed: Int
    public let speedLimit: Int
    public let roadName: String
    public let isSpeeding: Bool
    public let unit: String
    public let lastUpdated: Date

    public init(currentSpeed: Int, speedLimit: Int, roadName: String, isSpeeding: Bool, unit: String, lastUpdated: Date = Date()) {
        self.currentSpeed = currentSpeed
        self.speedLimit = speedLimit
        self.roadName = roadName
        self.isSpeeding = isSpeeding
        self.unit = unit
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Shared UserDefaults Extension
public extension UserDefaults {
    static let shared: UserDefaults = {
        guard let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let sharedDefaults = UserDefaults(suiteName: groupIdentifier) else {
            // Fallback to standard UserDefaults if App Group is not configured
            return UserDefaults.standard
        }
        return sharedDefaults
    }()

    static let appGroupIdentifier = "group.com.speedy.app"

    static let sharedAppGroup: UserDefaults = {
        return UserDefaults(suiteName: appGroupIdentifier) ?? UserDefaults.standard
    }()
}

// MARK: - Shared Data Keys
public struct SpeedyDataKeys {
    public static let currentSpeed = "currentSpeed"
    public static let speedLimit = "speedLimit"
    public static let roadName = "roadName"
    public static let isSpeeding = "isSpeeding"
    public static let unit = "unit"
    public static let batteryLevel = "batteryLevel"
    public static let altitude = "altitude"
    public static let signalType = "signalType"
    public static let lastUpdated = "lastUpdated"
    public static let widgetData = "widgetData"
    public static let speedLimitIsInferred = "speedLimitIsInferred"
}
