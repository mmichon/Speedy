//
//  SpeedLimitResolver.swift
//  SpeedyShared
//
//  Shared, pure (network-free) building blocks for multi-source speed-limit
//  resolution. Lives in SpeedyShared so the iOS app, the Watch app, and the
//  widget all parse and reconcile speed limits identically. Everything here is
//  deterministic and unit-testable.
//

import Foundation
import CoreLocation

// MARK: - Source & Confidence

/// Where a speed-limit reading came from. Order is also the tie-break priority
/// for *posted* readings (lower `rawValue` wins ties).
public enum SpeedLimitSource: Int, Codable, CaseIterable, Sendable {
    case tomtom = 0        // Commercial-grade posted limits (TomTom)
    case osmMaxspeed = 1   // OpenStreetMap `maxspeed` tag (a real posted sign)
    case here = 2          // HERE posted limits
    case statutoryDefault = 3 // Inferred legal default from road class — NOT a posted sign

    public var displayName: String {
        switch self {
        case .tomtom: return "TomTom"
        case .osmMaxspeed: return "OpenStreetMap"
        case .here: return "HERE"
        case .statutoryDefault: return "Statutory default"
        }
    }
}

/// How much we trust the value. `.posted` means it reflects an actual posted
/// sign in a data source; `.inferred` means it was derived from road class via
/// statutory defaults and should be shown distinctly (e.g. dimmed / "~").
public enum SpeedLimitConfidence: Int, Codable, Sendable {
    case inferred = 0
    case posted = 1
}

// MARK: - Result

public struct SpeedLimitResult: Equatable, Sendable {
    public let speedLimitMph: Int?
    public let roadName: String?
    public let source: SpeedLimitSource
    public let confidence: SpeedLimitConfidence

    public init(speedLimitMph: Int?,
                roadName: String?,
                source: SpeedLimitSource,
                confidence: SpeedLimitConfidence) {
        self.speedLimitMph = speedLimitMph
        self.roadName = roadName
        self.source = source
        self.confidence = confidence
    }

    /// A result carries a usable speed limit only if it actually has a number.
    public var hasSpeedLimit: Bool { speedLimitMph != nil }
}

// MARK: - Sanity bounds

public enum SpeedLimitBounds {
    /// Plausible US posted-limit range. Values outside this are rejected as
    /// bad data rather than displayed.
    public static let minMph = 5
    public static let maxMph = 85

    public static func isPlausible(_ mph: Int) -> Bool {
        mph >= minMph && mph <= maxMph
    }
}

// MARK: - maxspeed parsing

public enum SpeedLimitParser {
    /// Parse a `maxspeed`-style value into MPH. Handles OSM forms ("35 mph",
    /// "30", "50 km/h") and TomTom forms ("30.00MPH", "50.00KMPH"). Implicit/zone
    /// tags ("none", "signals", "DE:urban") return nil — those are covered by
    /// statutory defaults.
    public static func parseMaxspeed(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return nil }
        if value == "none" || value == "signals" || value == "variable" || value == "walk" {
            return nil
        }

        // Leading numeric portion (tolerates decimals like "30.00").
        let digits = value.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number > 0 else { return nil }

        let isMetric = value.contains("km") || (value.contains("kph") && !value.contains("mph"))
        let mph = isMetric ? Int((number * 0.621371).rounded()) : Int(number.rounded())
        return SpeedLimitBounds.isPlausible(mph) ? mph : nil
    }
}

// MARK: - Geo helpers

public enum SpeedLimitGeo {
    /// Initial bearing (degrees, 0–360, 0 = north) from `a` to `b`.
    public static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute difference between two headings, accounting for the
    /// fact that a road has no direction: 350° vs 170° are "the same line".
    /// Returns 0–90.
    public static func headingAlignment(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 180)
        if diff > 90 { diff = 180 - diff }
        return diff
    }

    /// Grid-snapped cache key. ~4 decimal places ≈ 11 m, so consecutive GPS
    /// fixes along a road collapse to the same key and the cache actually hits.
    public static func gridKey(_ c: CLLocationCoordinate2D, precision: Int = 4) -> String {
        let factor = pow(10.0, Double(precision))
        let lat = (c.latitude * factor).rounded() / factor
        let lon = (c.longitude * factor).rounded() / factor
        return String(format: "%.\(precision)f,%.\(precision)f", lat, lon)
    }
}

// MARK: - Reconciliation

public enum SpeedLimitResolver {
    /// Choose the best speed limit from a set of provider results.
    ///
    /// Rules (see plan):
    ///  1. Posted readings always beat inferred ones.
    ///  2. Among posted readings, if two or more agree within `agreementMph`,
    ///     prefer the agreed value (using the highest-priority agreeing source).
    ///  3. Otherwise prefer the highest-priority source (TomTom → OSM → HERE).
    ///  4. Only fall back to an inferred (statutory) reading when no posted
    ///     reading exists. Never invent a number.
    ///
    /// Returns nil when nothing usable is available (caller should show "unknown").
    public static func reconcile(_ results: [SpeedLimitResult],
                                 agreementMph: Int = 5) -> SpeedLimitResult? {
        let usable = results.filter { result in
            guard let mph = result.speedLimitMph else { return false }
            return SpeedLimitBounds.isPlausible(mph)
        }
        guard !usable.isEmpty else { return nil }

        let posted = usable.filter { $0.confidence == .posted }
            .sorted { $0.source.rawValue < $1.source.rawValue }

        if !posted.isEmpty {
            // Look for agreement among posted readings.
            for candidate in posted {
                let cMph = candidate.speedLimitMph!
                let agreeing = posted.filter { abs($0.speedLimitMph! - cMph) <= agreementMph }
                if agreeing.count >= 2 {
                    // Highest-priority source among the agreeing set.
                    return agreeing.min { $0.source.rawValue < $1.source.rawValue }
                }
            }
            // No agreement: trust the highest-priority posted source.
            return posted.first
        }

        // No posted readings — fall back to the best inferred one.
        return usable
            .filter { $0.confidence == .inferred }
            .min { $0.source.rawValue < $1.source.rawValue }
    }
}
