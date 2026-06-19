//
//  SpeedySharedTests.swift
//  SpeedySharedTests
//
//  Created by Michael Michon on 8/19/25.
//

import Testing
import Foundation
@testable import SpeedyShared

// Serialized: these cases share the app-group UserDefaults, so running them in
// parallel races on the same keys.
@Suite(.serialized)
struct SpeedySharedTests {

    @Test("Unit.unitString returns correct display strings")
    func unitStringValues() async throws {
        #expect(Unit.imperial.unitString == "MPH")
        #expect(Unit.metric.unitString == "KPH")
    }

    @Test("SpeedyDataManager saves and loads widget data correctly")
    func speedyDataManagerSaveLoadClear() async throws {
        // Ensure a clean slate
        let manager = SpeedyDataManager.shared
        manager.clearWidgetData()

        // Save sample data
        let speed = 65
        let limit = 55
        let road = "Main St"
        let isSpeeding = true
        let unit = Unit.imperial.unitString

        manager.saveWidgetData(
            currentSpeed: speed,
            speedLimit: limit,
            roadName: road,
            isSpeeding: isSpeeding,
            unit: unit,
            batteryLevel: 0.75,
            altitude: "123 ft",
            signalType: "4G"
        )

        // Load and verify
        let loaded = manager.loadWidgetData()
        #expect(loaded != nil)
        #expect(loaded?.currentSpeed == speed)
        #expect(loaded?.speedLimit == limit)
        #expect(loaded?.roadName == road)
        #expect(loaded?.isSpeeding == isSpeeding)
        #expect(loaded?.unit == unit)

        // Also verify raw UserDefaults entries exist
        let ud = UserDefaults.sharedAppGroup
        #expect(ud.integer(forKey: SpeedyDataKeys.currentSpeed) == speed)
        #expect(ud.integer(forKey: SpeedyDataKeys.speedLimit) == limit)
        #expect(ud.string(forKey: SpeedyDataKeys.roadName) == road)
        #expect(ud.bool(forKey: SpeedyDataKeys.isSpeeding) == isSpeeding)
        #expect(ud.string(forKey: SpeedyDataKeys.unit) == unit)
        #expect(ud.data(forKey: SpeedyDataKeys.widgetData) != nil)

        // Clear and verify defaults
        manager.clearWidgetData()
        let cleared = manager.loadWidgetData()
        #expect(cleared != nil)
        #expect(cleared?.currentSpeed == 0)
        #expect(cleared?.speedLimit == 0)
        #expect(cleared?.roadName == "Unknown Road")
        #expect(cleared?.isSpeeding == false)
        #expect(cleared?.unit == Unit.imperial.unitString)
    }

    @Test("End-to-end widget data flow update does not crash and preserves data")
    func widgetDataFlowIntegration() async throws {
        let manager = SpeedyDataManager.shared
        manager.clearWidgetData()

        // Save baseline
        manager.saveWidgetData(
            currentSpeed: 10,
            speedLimit: 25,
            roadName: "Test Rd",
            isSpeeding: false,
            unit: Unit.metric.unitString
        )

        // Perform forced refresh via data update path
        manager.forceWidgetRefreshByDataUpdate()

        // Verify we can still load coherent data afterward
        let loaded = manager.loadWidgetData()
        #expect(loaded != nil)
        #expect(loaded?.roadName.count ?? 0 > 0)
        #expect(loaded?.unit == Unit.metric.unitString)

        // Cleanup
        manager.clearWidgetData()
    }

}
