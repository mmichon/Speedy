//
//  StatutoryDefaultSpeeds.swift
//  SpeedyShared
//
//  US statutory default speed limits, inferred from an OSM road's `highway`
//  class and a few supporting tags. This REPLACES the old "guess 25/35"
//  constants: when no posted limit is available, we return the legal default
//  for that road class/context instead of a blind number, tagged `.inferred`
//  so the UI can show it distinctly.
//
//  Values are a US-focused subset derived from the OpenStreetMap
//  "Default speed limits" wiki (https://wiki.openstreetmap.org/wiki/Default_speed_limits)
//  and state statutes. The full international rule engine
//  (westnordost/osm-legal-default-speeds) is Kotlin/JS only; porting it wholesale
//  is unnecessary for US urban/highway use, so we use a compact, testable table.
//  Because results are `.inferred` and rendered distinctly, approximate values
//  are acceptable by design.
//

import Foundation

public struct StatutoryRoadContext {
    /// Raw OSM `highway=` value, e.g. "residential", "motorway".
    public let highway: String
    /// Whether the road is lit (`lit=yes`) — a strong urban indicator.
    public let isLit: Bool?
    /// `maxspeed:type` / `source:maxspeed`, e.g. "US:urban", "US:rural" when present.
    public let maxspeedType: String?
    /// Two-letter US state code when known (e.g. "CA", "TX").
    public let stateCode: String?

    public init(highway: String,
                isLit: Bool? = nil,
                maxspeedType: String? = nil,
                stateCode: String? = nil) {
        self.highway = highway
        self.isLit = isLit
        self.maxspeedType = maxspeedType
        self.stateCode = stateCode
    }
}

public enum StatutoryDefaultSpeeds {

    private enum Context { case urban, rural }

    /// National default speed limits (MPH) by OSM highway class and context.
    private static let urbanDefaults: [String: Int] = [
        "motorway": 55,
        "motorway_link": 45,
        "trunk": 50,
        "trunk_link": 40,
        "primary": 35,
        "primary_link": 30,
        "secondary": 35,
        "secondary_link": 30,
        "tertiary": 30,
        "tertiary_link": 25,
        "unclassified": 25,
        "residential": 25,
        "living_street": 15,
        "service": 15,
        "road": 25
    ]

    private static let ruralDefaults: [String: Int] = [
        "motorway": 70,
        "motorway_link": 50,
        "trunk": 60,
        "trunk_link": 45,
        "primary": 55,
        "primary_link": 45,
        "secondary": 55,
        "secondary_link": 45,
        "tertiary": 50,
        "tertiary_link": 40,
        "unclassified": 45,
        "residential": 25,
        "living_street": 15,
        "service": 15,
        "road": 45
    ]

    /// Per-state overrides for the values that vary most and matter for this
    /// app (rural freeway maxima, residential). Approximate; extend as needed.
    /// Keyed by state code → (highway class → mph) for the given context.
    private static let ruralStateOverrides: [String: [String: Int]] = [
        "TX": ["motorway": 75, "trunk": 70, "primary": 70],
        "MT": ["motorway": 80, "trunk": 70],
        "UT": ["motorway": 80],
        "NV": ["motorway": 80],
        "ID": ["motorway": 80],
        "WY": ["motorway": 80],
        "SD": ["motorway": 80],
        "OK": ["motorway": 75],
        "KS": ["motorway": 75],
        "ND": ["motorway": 75],
        "NM": ["motorway": 75],
        "CO": ["motorway": 75],
        "CA": ["motorway": 65, "trunk": 55],  // CA max is 65 mph statewide
        "OR": ["motorway": 65],
        "HI": ["motorway": 60],
        "MI": ["motorway": 70],
        "FL": ["motorway": 70]
    ]

    private static let urbanStateOverrides: [String: [String: Int]] = [
        // States whose statutory residential default isn't 25.
        "CA": ["residential": 25],
        "TX": ["residential": 30],
        "MI": ["residential": 25]
    ]

    /// Infer a statutory default for the given road context.
    /// Returns nil when the highway class isn't a drivable road we model.
    public static func defaultSpeed(for context: StatutoryRoadContext) -> Int? {
        let highway = context.highway.lowercased()

        // Non-drivable or pedestrian classes have no meaningful vehicle limit.
        let nonDrivable: Set<String> = ["footway", "cycleway", "path", "steps",
                                        "bridleway", "pedestrian", "track",
                                        "construction", "proposed", "raceway"]
        if nonDrivable.contains(highway) { return nil }

        let ctx = inferContext(context, highway: highway)
        let state = context.stateCode?.uppercased()

        if ctx == .rural {
            if let s = state, let v = ruralStateOverrides[s]?[highway] { return v }
            return ruralDefaults[highway]
        } else {
            if let s = state, let v = urbanStateOverrides[s]?[highway] { return v }
            return urbanDefaults[highway]
        }
    }

    /// Convenience wrapper producing a full `SpeedLimitResult`.
    public static func result(for context: StatutoryRoadContext,
                              roadName: String?) -> SpeedLimitResult? {
        guard let mph = defaultSpeed(for: context) else { return nil }
        return SpeedLimitResult(speedLimitMph: mph,
                                roadName: roadName,
                                source: .statutoryDefault,
                                confidence: .inferred)
    }

    // MARK: - Context inference

    private static func inferContext(_ context: StatutoryRoadContext, highway: String) -> Context {
        // Explicit maxspeed:type wins.
        if let type = context.maxspeedType?.lowercased() {
            if type.contains("urban") { return .urban }
            if type.contains("rural") { return .rural }
        }

        // Local-street classes are inherently urban/neighborhood.
        let inherentlyUrban: Set<String> = ["residential", "living_street",
                                            "service", "unclassified", "road"]
        if inherentlyUrban.contains(highway) { return .urban }

        // `lit=yes` is a strong urban signal for higher-class roads.
        if context.isLit == true { return .urban }

        // Default higher-class roads to rural (the safer assumption for a
        // through-road without urban indicators).
        return .rural
    }
}
