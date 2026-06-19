//
//  SpeedyWidgetControl.swift
//  SpeedyWidget
//
//  Created by Michael Michon on 8/19/25.
//

import AppIntents
import SwiftUI
import WidgetKit

// Note: Control Widgets are only available in iOS 18.0+
// This file is kept for future use but disabled for iOS 16.1 compatibility
#if os(iOS) && compiler(>=5.9)
@available(iOS 18.0, *)
struct SpeedyWidgetControl: ControlWidget {
    static let kind: String = "com.mmichon.Speedy.SpeedyWidget"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Start Timer",
                isOn: value.isRunning,
                action: StartTimerIntent(value.name)
            ) { isRunning in
                Label(isRunning ? "On" : "Off", systemImage: "timer")
            }
        }
        .displayName("Timer")
        .description("A an example control that runs a timer.")
    }
}

@available(iOS 18.0, *)
extension SpeedyWidgetControl {
    struct Value {
        var isRunning: Bool
        var name: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: TimerConfiguration) -> Value {
            SpeedyWidgetControl.Value(isRunning: false, name: configuration.timerName)
        }

        func currentValue(configuration: TimerConfiguration) async throws -> Value {
            let isRunning = true // Check if the timer is running
            return SpeedyWidgetControl.Value(isRunning: isRunning, name: configuration.timerName)
        }
    }
}

@available(iOS 18.0, *)
struct TimerConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Timer Name Configuration"

    @Parameter(title: "Timer Name", default: "Timer")
    var timerName: String
}

@available(iOS 18.0, *)
struct StartTimerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start a timer"

    @Parameter(title: "Timer Name")
    var name: String

    @Parameter(title: "Timer is running")
    var value: Bool

    init() {}

    init(_ name: String) {
        self.name = name
    }

    func perform() async throws -> some IntentResult {
        // Start the timer…
        return .result()
    }
}
#else
// Placeholder for iOS versions < 18.0
struct SpeedyWidgetControl: Widget {
    let kind: String = "com.mmichon.Speedy.SpeedyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            Text("Control Widgets require iOS 18.0+")
                .padding()
        }
        .configurationDisplayName("Speedy Control")
        .description("Control widget for Speedy app")
        .supportedFamilies([.systemSmall])
    }

    struct Provider: TimelineProvider {
        typealias Entry = SimpleEntry

        func placeholder(in context: Context) -> SimpleEntry {
            SimpleEntry(date: Date())
        }

        func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
            completion(SimpleEntry(date: Date()))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
            let entry = SimpleEntry(date: Date())
            let timeline = Timeline(entries: [entry], policy: .never)
            completion(timeline)
        }
    }

    struct SimpleEntry: TimelineEntry {
        let date: Date
    }
}
#endif
