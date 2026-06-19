//
//  SpeedLimitResolverTests.swift
//  SpeedySharedTests
//
//  Tests for the pure speed-limit resolution core: maxspeed parsing,
//  multi-source reconciliation, geo helpers, and US statutory defaults.
//

import Testing
import Foundation
import CoreLocation
@testable import SpeedyShared

struct SpeedLimitParserTests {

    @Test("parses mph values")
    func mph() {
        #expect(SpeedLimitParser.parseMaxspeed("35 mph") == 35)
        #expect(SpeedLimitParser.parseMaxspeed("55mph") == 55)
    }

    @Test("parses bare numbers as mph (US convention)")
    func bare() {
        #expect(SpeedLimitParser.parseMaxspeed("45") == 45)
    }

    @Test("converts km/h to mph")
    func kmh() {
        #expect(SpeedLimitParser.parseMaxspeed("50 km/h") == 31)
        #expect(SpeedLimitParser.parseMaxspeed("100 kph") == 62)
    }

    @Test("parses TomTom decimal formats")
    func tomtom() {
        #expect(SpeedLimitParser.parseMaxspeed("30.00MPH") == 30)
        #expect(SpeedLimitParser.parseMaxspeed("50.00KMPH") == 31)
    }

    @Test("rejects implicit and out-of-range values")
    func rejects() {
        #expect(SpeedLimitParser.parseMaxspeed("none") == nil)
        #expect(SpeedLimitParser.parseMaxspeed("signals") == nil)
        #expect(SpeedLimitParser.parseMaxspeed("DE:urban") == nil)
        #expect(SpeedLimitParser.parseMaxspeed("200 mph") == nil) // above bounds
        #expect(SpeedLimitParser.parseMaxspeed("") == nil)
    }
}

struct SpeedLimitReconcileTests {

    private func posted(_ mph: Int, _ source: SpeedLimitSource) -> SpeedLimitResult {
        SpeedLimitResult(speedLimitMph: mph, roadName: nil, source: source, confidence: .posted)
    }
    private func inferred(_ mph: Int, _ source: SpeedLimitSource) -> SpeedLimitResult {
        SpeedLimitResult(speedLimitMph: mph, roadName: nil, source: source, confidence: .inferred)
    }

    @Test("posted beats inferred")
    func postedBeatsInferred() {
        let r = SpeedLimitResolver.reconcile([
            inferred(25, .statutoryDefault),
            posted(40, .here)
        ])
        #expect(r?.speedLimitMph == 40)
        #expect(r?.source == .here)
    }

    @Test("agreement is preferred over highest-priority-alone")
    func agreementWins() {
        // TomTom says 50 (alone), OSM + HERE agree on 35.
        let r = SpeedLimitResolver.reconcile([
            posted(50, .tomtom),
            posted(35, .osmMaxspeed),
            posted(34, .here)
        ])
        #expect(r?.speedLimitMph == 35)
        #expect(r?.source == .osmMaxspeed)
    }

    @Test("no agreement falls to highest-priority source")
    func priorityFallback() {
        let r = SpeedLimitResolver.reconcile([
            posted(60, .here),
            posted(45, .tomtom)
        ])
        #expect(r?.speedLimitMph == 45)
        #expect(r?.source == .tomtom)
    }

    @Test("falls back to inferred when no posted readings")
    func inferredFallback() {
        let r = SpeedLimitResolver.reconcile([
            inferred(25, .statutoryDefault)
        ])
        #expect(r?.speedLimitMph == 25)
        #expect(r?.confidence == .inferred)
    }

    @Test("returns nil when nothing usable")
    func nothingUsable() {
        #expect(SpeedLimitResolver.reconcile([]) == nil)
        let r = SpeedLimitResolver.reconcile([
            SpeedLimitResult(speedLimitMph: nil, roadName: "X", source: .tomtom, confidence: .posted)
        ])
        #expect(r == nil)
    }
}

struct SpeedLimitGeoTests {

    @Test("bearing north and east")
    func bearings() {
        let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
        let north = CLLocationCoordinate2D(latitude: 37.01, longitude: -122.0)
        let east = CLLocationCoordinate2D(latitude: 37.0, longitude: -121.99)
        #expect(abs(SpeedLimitGeo.bearing(from: origin, to: north) - 0) < 1)
        #expect(abs(SpeedLimitGeo.bearing(from: origin, to: east) - 90) < 1)
    }

    @Test("heading alignment treats opposite directions as aligned")
    func alignment() {
        #expect(SpeedLimitGeo.headingAlignment(350, 170) < 1)   // same line
        #expect(abs(SpeedLimitGeo.headingAlignment(0, 90) - 90) < 1) // perpendicular
    }

    @Test("grid key collapses nearby coordinates")
    func gridKey() {
        let a = CLLocationCoordinate2D(latitude: 37.123451, longitude: -122.654321)
        let b = CLLocationCoordinate2D(latitude: 37.123459, longitude: -122.654329)
        #expect(SpeedLimitGeo.gridKey(a) == SpeedLimitGeo.gridKey(b))
    }
}

struct StatutoryDefaultTests {

    @Test("local streets are urban defaults")
    func localStreets() {
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "residential")) == 25)
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "living_street")) == 15)
    }

    @Test("motorway uses rural default and state overrides")
    func motorways() {
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "motorway")) == 70)
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "motorway", stateCode: "CA")) == 65)
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "motorway", stateCode: "TX")) == 75)
    }

    @Test("lit higher-class road is treated as urban")
    func litUrban() {
        let rural = StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "primary"))
        let urban = StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "primary", isLit: true))
        #expect(rural == 55)
        #expect(urban == 35)
    }

    @Test("non-drivable classes return nil")
    func nonDrivable() {
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "footway")) == nil)
        #expect(StatutoryDefaultSpeeds.defaultSpeed(for: .init(highway: "cycleway")) == nil)
    }

    @Test("statutory result is tagged inferred")
    func resultTagging() {
        let r = StatutoryDefaultSpeeds.result(for: .init(highway: "residential"), roadName: "Oak St")
        #expect(r?.confidence == .inferred)
        #expect(r?.source == .statutoryDefault)
        #expect(r?.speedLimitMph == 25)
        #expect(r?.roadName == "Oak St")
    }
}
