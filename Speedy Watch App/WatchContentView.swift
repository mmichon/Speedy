import SwiftUI
import CoreLocation

struct WatchContentView: View {
    @EnvironmentObject var locationManager: WatchLocationManager
    @StateObject private var networkMonitor = WatchNetworkMonitor()
    @State private var isFlashing: Bool = false
    @State private var showingSettings = false

    private var batteryIconName: String {
        if locationManager.isCharging { return "battery.100.bolt" }
        switch locationManager.batteryLevel {
        case 0.0..<0.1: return "battery.0"
        case 0.1..<0.25: return "battery.25"
        case 0.25..<0.5: return "battery.50"
        case 0.5..<0.75: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryColor: Color {
        if locationManager.isCharging { return .green }
        switch locationManager.batteryLevel {
        case 0.0..<0.2: return .red
        case 0.2..<0.4: return .orange
        default: return .white
        }
    }

    var body: some View {
        ZStack {
            // Background - Same gradient as iPhone app
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.8),
                    Color.purple.opacity(0.6)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Top Controls
            VStack {
                HStack {
                    Spacer()

                    // Refresh Button
                    Button(action: {
                        if locationManager.locationManager.location != nil {
                            locationManager.refreshSpeedLimit()
                            locationManager.refreshRoadName()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Settings Button
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                Spacer()
            }

            VStack(spacing: 6) {
                // Speedy Logo - Same style as iPhone app
                Text("Speedy")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(gradient: Gradient(colors: [Color.white, Color.blue.opacity(0.6)]), startPoint: .top, endPoint: .bottom))
                    .shadow(radius: 3)
                    .padding(.bottom, 4)

                // Current Speed - Large and Prominent
                VStack(spacing: 2) {
                    Text("CURRENT")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .textCase(.uppercase)

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(locationManager.displayedCurrentSpeed)")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundColor(locationManager.isSpeeding ? .red : .white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)

                        Text(locationManager.unitSuffix)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.gray)

                        // Speed trend indicator
                        if locationManager.speedTrend != .stable {
                            Image(systemName: locationManager.speedTrend == .increasing ? "arrow.up" : "arrow.down")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(locationManager.speedTrend == .increasing ? .green : .orange)
                        }
                    }

                    EmptyView()
                }

                // Speed Limit - Secondary but Clear
                VStack(spacing: 2) {
                    Text("LIMIT")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .textCase(.uppercase)

                    if locationManager.speedLimitKnown && locationManager.speedLimit > 0 {
                        Text("\(locationManager.displayedSpeedLimit)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(locationManager.isSpeeding ? .red : .white.opacity(0.9))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(locationManager.unitSuffix)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.gray)
                    } else {
                        Text("--")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(locationManager.unitSuffix)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.gray)
                    }
                }

                // Road Name and Loading Indicator
                if locationManager.isLookingUpSpeedLimit {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.6)
                        Text("Looking up...")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                    )
                } else if !locationManager.currentRoadName.isEmpty {
                    VStack(spacing: 2) {
                        Text(locationManager.currentRoadName)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.1))
                    )
                }

                // Status Indicators - Compact Row
                HStack(spacing: 12) {
                    // Network Status - Changed to wifi emoji and ONLINE/OFFLINE text
                    HStack(spacing: 4) {
                        Text("📶")
                            .font(.system(size: 12))
                        Text(networkMonitor.isOnline ? "ONLINE" : "OFFLINE")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    // Speed Limit Status - Changed to speedometer emoji with red/green coloring
                    HStack(spacing: 4) {
                        Text("🚗")
                            .font(.system(size: 12))
                            .foregroundColor(locationManager.speedLimitKnown ? .green : .red)
                        Text(locationManager.speedLimitKnown ? "KNOWN" : "UNKNOWN")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(locationManager.speedLimitKnown ? .green : .red)
                    }

                    // Battery Level
                    HStack(spacing: 4) {
                        Image(systemName: locationManager.isCharging ? "battery.100.bolt" : batteryIconName)
                            .foregroundColor(locationManager.isCharging ? .green : batteryColor)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(Int(round(locationManager.batteryLevel * 100)))%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    // Altitude
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.white.opacity(0.9))
                            .font(.system(size: 12, weight: .medium))
                        Text(locationManager.formattedAltitude())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    }


                }

                // Location Permission Warning
                if locationManager.locationStatus != .authorizedWhenInUse && locationManager.locationStatus != .authorizedAlways {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            Text("Location Required")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.orange)
                        }

                        Text("App cannot function without location access")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)

                        Button(action: {
                            locationManager.requestLocationPermission()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 10))
                                Text("Enable Location")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.orange.opacity(0.6), lineWidth: 1)
                            )
                    )
                }

                // Speeding Warning - Prominent
                if locationManager.isSpeeding {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                        Text("SPEEDING!")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.red.opacity(0.6), lineWidth: 1)
                            )
                    )
                    .scaleEffect(isFlashing ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isFlashing)
                    .onAppear {
                        isFlashing = true
                    }
                    .onDisappear {
                        isFlashing = false
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .onAppear {
            locationManager.requestLocationPermission()
        }
        .onChange(of: networkMonitor.isOnline) { _, newValue in
            locationManager.isNetworkOnline = newValue
        }
        .onChange(of: locationManager.isSpeeding) { _, newValue in
            if newValue {
                // Haptic feedback when speeding is detected
                // Note: Haptic feedback is automatic in watchOS for alerts

                // Play sound alert for speeding (only if sound alerts are enabled)
                let soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
                if soundAlertsEnabled {
                    SoundManager.shared.playSpeedingAlert()
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            WatchSettingsView()
                .environmentObject(locationManager)
        }
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchLocationManager())
}