//
//  SpeedyWidgetLiveActivity.swift
//  SpeedyWidget
//
//  Created by Michael Michon on 8/19/25.
//

import ActivityKit
import WidgetKit
import SwiftUI
import SpeedyShared

// MARK: - Live Activity Widget
//
// Exactly ONE ActivityConfiguration is registered for SpeedyWidgetAttributes. On
// iOS 18.4+ / iOS 26 the system automatically forwards this Live Activity to the
// CarPlay dashboard (no CarPlay entitlement required); a single, healthy
// configuration is what makes that forwarding — and lock screen / Dynamic Island
// rendering — reliable.
//
// NOTE (future enhancement): iOS 18.0 adds `.supplementalActivityFamilies([.small])`
// + the `\.activityFamily` environment value to render a layout tuned for the small
// CarPlay slot. It can't be applied here without either registering a duplicate
// configuration (the bug this file fixes) or dropping the Live Activity on iOS 17.x,
// because `supplementalActivityFamilies` changes the configuration's opaque type and
// WidgetBundleBuilder has no `buildEither`/`#unavailable` to gate it. Until the app's
// deployment target moves to iOS 18.0, CarPlay uses the forwarded standard layout.

/// Live Activity (lock screen + Dynamic Island; forwarded to CarPlay on iOS 18.4+).
@available(iOS 16.1, *)
struct SpeedyWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedyWidgetAttributes.self) { context in
            StandardLockScreenView(context: context)
        } dynamicIsland: { context in
            speedyDynamicIsland(context: context)
        }
    }
}

// MARK: - Lock Screen / CarPlay Content

/// Standard lock screen / banner presentation (also forwarded to CarPlay).
@available(iOS 16.1, *)
struct StandardLockScreenView: View {
    let context: ActivityViewContext<SpeedyWidgetAttributes>

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // Speed display - clean and focused
                HStack(spacing: 20) {
                    // Current speed
                    VStack(spacing: 4) {
                        Text("CURRENT")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.8))
                        Text("\(context.state.currentSpeed)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 60, alignment: .center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(unitSuffix(from: context.state.unit))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.gray)
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: 60)

                    // Speed limit
                    VStack(spacing: 4) {
                        Text(context.state.speedLimitIsInferred ? "EST. LIMIT" : "LIMIT")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.8))
                        Text("\(context.state.speedLimitIsInferred ? "~" : "")\(context.state.speedLimit)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(context.state.speedLimitIsInferred ? 0.7 : 1.0))
                            .frame(width: 60, alignment: .center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(unitSuffix(from: context.state.unit))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.gray)
                    }
                }

                // Road name
                if !context.state.roadName.isEmpty && context.state.roadName != "Unknown Road" {
                    Text(context.state.roadName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                // Status indicators row: signal type and altitude
                HStack(spacing: 12) {
                    // Signal Type Indicator
                    HStack(spacing: 4) {
                        Image(systemName: signalIcon(for: context.state.signalType))
                            .font(.caption)
                            .foregroundColor(signalColor(for: context.state.signalType))
                        Text(context.state.signalType)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(8)

                    // Altitude Indicator
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                        Text(context.state.altitude)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .containerBackground(speedingGradient(isSpeeding: context.state.isSpeeding), for: .widget)
        .activityBackgroundTint(Color.clear)
        .activitySystemActionForegroundColor(Color.white)
    }
}

// MARK: - Dynamic Island

@available(iOS 16.1, *)
func speedyDynamicIsland(context: ActivityViewContext<SpeedyWidgetAttributes>) -> DynamicIsland {
    DynamicIsland {
        // Expanded view - shows all indicators
        DynamicIslandExpandedRegion(.leading) {
            // Speed and speed limit
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text("SPEED")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.8))
                    Text("\(context.state.currentSpeed)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(unitSuffix(from: context.state.unit))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                VStack(spacing: 2) {
                    Text(context.state.speedLimitIsInferred ? "EST. LIMIT" : "LIMIT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.8))
                    Text("\(context.state.speedLimitIsInferred ? "~" : "")\(context.state.speedLimit)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(context.state.isSpeeding ? .red : .white.opacity(context.state.speedLimitIsInferred ? 0.7 : 1.0))
                    Text(unitSuffix(from: context.state.unit))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }

        DynamicIslandExpandedRegion(.trailing) {
            // Battery and signal indicators
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: batteryIconName(for: context.state.batteryLevel))
                        .font(.caption)
                        .foregroundColor(batteryColor(for: context.state.batteryLevel))
                    Text("\(Int(context.state.batteryLevel * 100))%")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }

                HStack(spacing: 4) {
                    Image(systemName: signalIcon(for: context.state.signalType))
                        .font(.caption)
                        .foregroundColor(signalColor(for: context.state.signalType))
                    Text(context.state.signalType)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
            }
        }

        DynamicIslandExpandedRegion(.center) {
            if !context.state.roadName.isEmpty && context.state.roadName != "Unknown Road" {
                Text(context.state.roadName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        DynamicIslandExpandedRegion(.bottom) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                Text(context.state.altitude)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
        }
    } compactLeading: {
        // Compact leading - current speed
        Text("\(context.state.currentSpeed)")
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .minimumScaleFactor(0.8)
    } compactTrailing: {
        // Compact trailing - speed limit
        Text("\(context.state.speedLimitIsInferred ? "~" : "")\(context.state.speedLimit)")
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(context.state.isSpeeding ? .red : .white.opacity(context.state.speedLimitIsInferred ? 0.7 : 1.0))
            .minimumScaleFactor(0.8)
    } minimal: {
        // Minimal - just speed with color coding
        Text("\(context.state.currentSpeed)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(context.state.isSpeeding ? .red : .white)
            .minimumScaleFactor(0.8)
    }
    .keylineTint(context.state.isSpeeding ? Color.red : Color.blue)
}

// MARK: - Helpers

private func speedingGradient(isSpeeding: Bool) -> LinearGradient {
    LinearGradient(
        gradient: Gradient(colors: [
            isSpeeding ? Color.red.opacity(0.8) : Color.blue.opacity(0.8),
            isSpeeding ? Color.orange.opacity(0.6) : Color.cyan.opacity(0.6)
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Normalizes the stored unit string into a short suffix ("mph" / "kph").
private func unitSuffix(from unitString: String) -> String {
    let normalized = unitString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("mph") || normalized == "imperial" { return "mph" }
    if normalized.contains("kmh") || normalized.contains("km/h") || normalized == "metric" { return "kph" }
    return unitString.uppercased()
}

private func signalIcon(for signalType: String) -> String {
    let normalized = signalType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "gps":
        return "location.circle.fill"
    case "cell", "cellular", "5g", "4g", "lte", "3g", "2g":
        return "antenna.radiowaves.left.and.right"
    case "wifi", "wi-fi":
        return "wifi"
    case "offline", "no signal", "none":
        return "wifi.slash"
    default:
        return "questionmark.circle"
    }
}

private func signalColor(for signalType: String) -> Color {
    let normalized = signalType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "gps":
        return .blue
    case "5g":
        return .green
    case "4g", "lte":
        return .orange
    case "3g":
        return .yellow
    case "2g":
        return .red
    case "offline", "no signal", "none":
        return .red
    default:
        return .gray
    }
}

private func batteryIconName(for batteryLevel: Float) -> String {
    switch batteryLevel {
    case 0.0..<0.1:
        return "battery.0"
    case 0.1..<0.25:
        return "battery.25"
    case 0.25..<0.5:
        return "battery.50"
    case 0.5..<0.75:
        return "battery.75"
    default:
        return "battery.100"
    }
}

private func batteryColor(for batteryLevel: Float) -> Color {
    switch batteryLevel {
    case 0.0..<0.2:
        return .red
    case 0.2..<0.4:
        return .orange
    default:
        return .white
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 16.1, *)
extension SpeedyWidgetAttributes.ContentState {
    fileprivate static var speeding: SpeedyWidgetAttributes.ContentState {
        SpeedyWidgetAttributes.ContentState(
            currentSpeed: 65,
            speedLimit: 55,
            roadName: "Main Street",
            isSpeeding: true,
            unit: SpeedyShared.Unit.imperial.unitString,
            isOnline: true,
            batteryLevel: 0.85,
            signalType: "5G",
            altitude: "1,234 ft",
            isLiveMode: true
        )
    }

    fileprivate static var normal: SpeedyWidgetAttributes.ContentState {
        SpeedyWidgetAttributes.ContentState(
            currentSpeed: 50,
            speedLimit: 55,
            roadName: "Main Street",
            isSpeeding: false,
            unit: SpeedyShared.Unit.imperial.unitString,
            isOnline: true,
            batteryLevel: 0.65,
            signalType: "4G",
            altitude: "856 ft",
            isLiveMode: true
        )
    }
}
#endif
