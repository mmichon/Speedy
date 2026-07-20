import SwiftUI
import CoreLocation
import UIKit
import SpeedyShared

struct ContentView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @State private var showingSettings = false
    @State private var isFlashing: Bool = false
    @State private var batteryLevel: Float = 1.0
    @State private var isCharging: Bool = false
    @State private var showingSpeedLimitInfo = false
    @AppStorage("adsEnabled") private var adsEnabled: Bool = false

    private let batteryMonitor = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        ZStack {
            // Background
            backgroundView

            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .safeAreaInset(edge: .bottom) {
            if adsEnabled {
                GeometryReader { proxy in
                    BannerAdView(adUnitId: "ca-app-pub-9597683900798061/8396712104", availableWidth: proxy.size.width)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(Color(UIColor.systemBackground))
                }
                .frame(height: 50)
            }
        }
        .onChange(of: locationManager.isSpeeding) { _, newValue in
            if newValue {
                isFlashing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isFlashing = false
                }
            }
        }
        .onChange(of: networkMonitor.isOnline) { _, newValue in
            locationManager.isNetworkOnline = newValue

            // Refresh widgets when network status changes
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
        .onAppear {
            locationManager.requestLocationPermission()
            UIDevice.current.isBatteryMonitoringEnabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                updateBatteryInfo()
            }
        }
        .onReceive(batteryMonitor) { _ in
            updateBatteryInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            updateBatteryInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            updateBatteryInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            let keepScreenOn = UserDefaults.standard.bool(forKey: "keepScreenOn")
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            locationManager.handleAppStateChange(isActive: true)
            networkMonitor.resetStartupTime()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            locationManager.handleAppStateChange(isActive: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // App is about to become inactive (window closing, going to background, etc.)
            locationManager.handleAppStateChange(isActive: false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App window is active
                locationManager.handleAppStateChange(isActive: true)
                networkMonitor.resetStartupTime()
            case .inactive, .background:
                // App window is inactive or in background (including when window closes)
                locationManager.handleAppStateChange(isActive: false)
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(locationManager: locationManager)
        }
    }

    // MARK: - Background View
    var backgroundView: some View {
        ZStack {
            // Deep base
            Color.black

            // Soft radial glow that tints toward the current speed state
            RadialGradient(
                gradient: Gradient(colors: [
                    speedColor.opacity(0.35),
                    speedColor.opacity(0.10),
                    Color.clear
                ]),
                center: .center,
                startRadius: 40,
                endRadius: 520
            )
            .animation(.easeInOut(duration: 0.6), value: speedColor)

            // Subtle diagonal depth
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.04),
                    Color.clear,
                    Color.black.opacity(0.4)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if isFlashing {
                Color.red.opacity(0.35)
                    .animation(.easeInOut(duration: 0.1), value: isFlashing)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Portrait Layout
    var portraitLayout: some View {
        VStack(spacing: 0) {
            // Top status bar
            topStatusBar
                .padding(.top, 20)
                .padding(.horizontal, 20)

            Spacer()

            // Main speed display
            mainSpeedDisplay
                .padding(.horizontal, 20)

            Spacer()

            // Bottom info panel
            bottomInfoPanel
                .padding(.horizontal, 20)
                .padding(.bottom, 40)

            // Banner is rendered via safeAreaInset(bottom)
        }
    }

    // MARK: - Landscape Layout
    var landscapeLayout: some View {
        HStack(spacing: 0) {
            // Left side - Speed display
            GeometryReader { proxy in
                ScrollView {
                    VStack {
                        Spacer(minLength: 0)
                        mainSpeedDisplay
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity)

            // Right side - Info and controls
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        topStatusBar
                            .padding(.top, 12)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 0)

                        bottomInfoPanel
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)

                        Spacer(minLength: 0)

                        // Banner is rendered via safeAreaInset(bottom)
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Top Status Bar
    var topStatusBar: some View {
        VStack(spacing: verticalSizeClass == .compact ? 16 : 14) {
            // Top row with logo and controls
            HStack(spacing: verticalSizeClass == .compact ? 16 : 12) {
                // App title
                Text("SPEEDY")
                    .font(.system(size: verticalSizeClass == .compact ? 24 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        gradient: Gradient(colors: [Color.white, Color.blue.opacity(0.8)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ))

                Spacer()

                // Live Activities toggle button
                Button(action: {
                    if #available(iOS 16.1, *) {
                        locationManager.toggleLiveActivity()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: locationManager.liveActivitiesEnabled ? "livephoto" : "livephoto.slash")
                            .foregroundColor(locationManager.liveActivitiesEnabled ? .green : .gray)
                            .font(.caption)
                        Text(locationManager.liveActivitiesEnabled ? "LIVE" : "LIVE OFF")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(locationManager.liveActivitiesEnabled ? .green : .gray)
                    }
                    .padding(.horizontal, verticalSizeClass == .compact ? 8 : 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(locationManager.liveActivitiesEnabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(locationManager.liveActivitiesEnabled ? Color.green.opacity(0.5) : Color.gray.opacity(0.5), lineWidth: 1)
                            )
                    )
                }



                // Settings button
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(verticalSizeClass == .compact ? 8 : 6)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
            }

            // Status indicators row
            HStack(spacing: 10) {
                statusChip(icon: signalStrengthIcon, text: signalStrengthText, tint: signalStrengthColor)
                statusChip(icon: batteryIconName, text: "\(Int(round(batteryLevel * 100)))%", tint: batteryColor)
                if locationManager.hasGPSLock {
                    statusChip(icon: "mountain.2.fill", text: locationManager.formattedAltitude(), tint: .white.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Main Speed Display
    var mainSpeedDisplay: some View {
        let gaugeSize: CGFloat = verticalSizeClass == .compact ? 200 : 280

        return VStack(spacing: 24) {
            SpeedGaugeView(
                progress: gaugeProgress,
                color: speedColor,
                size: gaugeSize
            ) {
                VStack(spacing: 2) {
                    Text("\(displayedCurrentSpeed)")
                        .font(.system(size: gaugeSize * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: speedColor.opacity(0.6), radius: 12)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayedCurrentSpeed)

                    Text(unitString)
                        .font(.system(size: gaugeSize * 0.085, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(4)
                }
            }

            // Speeding warning
            if locationManager.isSpeeding {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                        .font(.title2)
                    Text("SPEEDING")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(2)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color.red.gradient)
                        .shadow(color: .red.opacity(0.6), radius: 16)
                )
                .scaleEffect(locationManager.isSpeeding ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: locationManager.isSpeeding)
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("CURRENT SPEED")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(4)
            }
        }
        .animation(.easeInOut, value: locationManager.isSpeeding)
    }

    // MARK: - Bottom Info Panel
    var bottomInfoPanel: some View {
        let compact = verticalSizeClass == .compact

        return VStack(spacing: compact ? 10 : 16) {
            // Road name (hidden if no GPS lock)
            if locationManager.hasGPSLock, let roadName = locationManager.currentRoadName, !roadName.isEmpty {
                infoPill(icon: "road.lanes", text: roadName)
            }

            // Current town (hidden if no GPS lock)
            if locationManager.hasGPSLock, let town = locationManager.currentTown, !town.isEmpty {
                infoPill(icon: "building.2.fill", text: town)
            }

            // Speed limit info (hidden if no GPS lock)
            if locationManager.hasGPSLock, locationManager.speedLimit > 0 {
                HStack(spacing: 20) {
                    // Iconic speed-limit road sign
                    SpeedLimitSign(
                        value: displayedSpeedLimit,
                        isInferred: locationManager.speedLimitIsInferred,
                        metric: locationManager.unitPreference == .metric,
                        scale: compact ? 0.78 : 1.0
                    )

                    // Alert threshold card
                    VStack(spacing: 6) {
                        Text("ALERT AT")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .tracking(2)
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text("\(displayedAlertLimit)")
                                .font(.system(size: compact ? 32 : 40, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(unitString)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 10 : 18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                }
            }

            // Location permission warning
            if locationManager.locationStatus != .authorizedWhenInUse && locationManager.locationStatus != .authorizedAlways {
                VStack(spacing: 12) {
                    // Warning icon and title
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.title2)
                        Text("Location Access Required")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }

                    // Main warning message
                    VStack(spacing: 6) {
                        Text("⚠️ This app cannot function without location access!")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        Text("Location permissions are essential for:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "speedometer")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Displaying your current speed")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }

                            HStack(spacing: 8) {
                                Image(systemName: "road.lanes")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Showing road names and speed limits")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }

                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                Text("Alerting you when speeding")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .padding(.leading, 20)
                    }

                    // Action buttons
                    VStack(spacing: 8) {
                        Button(action: {
                            if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsUrl)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.fill")
                                    .font(.caption)
                                Text("Open Settings")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.blue)
                            )
                        }

                        Button(action: {
                            locationManager.requestLocationPermission()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "location.fill")
                                    .font(.caption)
                                Text("Request Permission Again")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                                    )
                            )
                        }
                    }

                    // Helpful tip
                    Text("💡 Tip: In Settings, go to Privacy & Security → Location Services → Speedy → Allow While Using App")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.orange.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                        )
                )
            }
        }
    }

    // MARK: - Helper Computed Properties

    private var signalStrengthIcon: String {
        switch locationManager.cellularSignalStrength {
        case 0:
            return "antenna.radiowaves.left.and.right.slash"
        case 1:
            return "antenna.radiowaves.left"
        case 2:
            return "antenna.radiowaves.left.and.right"
        case 3:
            return "antenna.radiowaves.left.and.right"
        case 4:
            return "antenna.radiowaves.left.and.right"
        default:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var signalStrengthColor: Color {
        switch locationManager.cellularSignalStrength {
        case 0:
            return .red      // No signal
        case 1:
            return .orange   // 2G - older, slower network
        case 2:
            return .yellow   // 3G - moderate network
        case 3:
            return .orange   // 4G - good network (changed from blue to orange)
        case 4:
            return .green    // 5G - best network
        default:
            return .gray
        }
    }

    private var signalStrengthText: String {
        return locationManager.formattedCellularSignalStrength()
    }

    private var batteryIconName: String {
        if isCharging {
            return "battery.100.bolt"
        }

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

    private var batteryColor: Color {
        if isCharging {
            return .green
        }

        switch batteryLevel {
        case 0.0..<0.2:
            return .red
        case 0.2..<0.4:
            return .orange
        default:
            return .white
        }
    }

    private var displayedCurrentSpeed: Int {
        if locationManager.unitPreference == .metric {
            return Int(locationManager.currentSpeed * 1.60934)
        } else {
            return Int(locationManager.currentSpeed)
        }
    }

    private var displayedSpeedLimit: Int {
        if locationManager.unitPreference == .metric {
            return Int(Double(locationManager.speedLimit) * 1.60934)
        } else {
            return locationManager.speedLimit
        }
    }

    private var displayedAlertLimit: Int {
        let alertLimit = locationManager.speedLimit + locationManager.speedLimitOffset
        if locationManager.unitPreference == .metric {
            return Int(Double(alertLimit) * 1.60934)
        } else {
            return alertLimit
        }
    }

    private var unitString: String {
        locationManager.unitPreference.unitString
    }

    /// Speedometer fill fraction (0...1). Scales relative to the alert limit
    /// when a speed limit is known, otherwise a sensible top speed.
    private var gaugeProgress: Double {
        let speed = Double(displayedCurrentSpeed)
        let maxScale: Double
        if locationManager.speedLimit > 0 {
            // Full sweep a bit past the alert threshold so going over pins it.
            maxScale = max(Double(displayedAlertLimit) * 1.15, 1)
        } else {
            maxScale = locationManager.unitPreference == .metric ? 160 : 100
        }
        return min(max(speed / maxScale, 0), 1)
    }

    /// Color that reflects how close the driver is to the limit:
    /// calm blue when no limit, green under, yellow approaching, red over.
    private var speedColor: Color {
        guard locationManager.speedLimit > 0 else { return Color(red: 0.25, green: 0.6, blue: 1.0) }
        if locationManager.isSpeeding { return .red }
        let ratio = Double(displayedCurrentSpeed) / Double(max(displayedSpeedLimit, 1))
        switch ratio {
        case ..<0.85: return .green
        case 0.85..<1.0: return .yellow
        default: return .orange
        }
    }

    // MARK: - Reusable UI Builders

    private func statusChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(speedColor)
            Text(text)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, verticalSizeClass == .compact ? 9 : 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    // MARK: - Helper Functions

    private func updateBatteryInfo() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        let rawBatteryLevel = UIDevice.current.batteryLevel
        if rawBatteryLevel >= 0 {
            batteryLevel = rawBatteryLevel
        } else {
            batteryLevel = 1.0
        }

        let batteryState = UIDevice.current.batteryState
        isCharging = batteryState == .charging || batteryState == .full

        // Refresh widgets when battery level changes
        SpeedyDataManager.shared.forceWidgetRefresh()
    }
}

// MARK: - Circular Speed Gauge

/// A modern 270° speedometer ring with a glowing progress arc and a center
/// content slot (the speed readout).
struct SpeedGaugeView<Content: View>: View {
    let progress: Double
    let color: Color
    let size: CGFloat
    @ViewBuilder var content: Content

    // 270° sweep, gap centered at the bottom.
    private let trimEnd: CGFloat = 0.75
    private let rotation: Double = 135

    private var lineWidth: CGFloat { size * 0.075 }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(rotation))

            // Tick marks
            ForEach(0..<10) { i in
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 2.5, height: size * 0.035)
                    .offset(y: -size / 2 + lineWidth + size * 0.05)
                    .rotationEffect(.degrees(135 + Double(i) * 30))
            }

            // Progress arc
            Circle()
                .trim(from: 0, to: trimEnd * progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.7), color]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
                .shadow(color: color.opacity(0.7), radius: 12)
                .animation(.easeOut(duration: 0.4), value: progress)

            content
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Speed Limit Sign

/// An iconic speed-limit road sign: a US-style rectangular sign for imperial
/// units and a European red-ring roundel for metric. Inferred (statutory)
/// limits are dimmed and marked with a "~".
struct SpeedLimitSign: View {
    let value: Int
    let isInferred: Bool
    let metric: Bool
    /// Shrinks the whole sign (frame, fonts, strokes) for compact-height layouts.
    var scale: CGFloat = 1.0

    private var valueText: String { isInferred ? "~\(value)" : "\(value)" }

    var body: some View {
        Group {
            if metric {
                roundel
            } else {
                usSign
            }
        }
        .opacity(isInferred ? 0.75 : 1.0)
        .frame(maxWidth: .infinity)
    }

    // European red-ring roundel
    private var roundel: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(Color.red, lineWidth: 11 * scale)
                .padding(7 * scale)
            Text(valueText)
                .font(.system(size: 42 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 8 * scale)
        }
        .frame(width: 118 * scale, height: 118 * scale)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    // US-style white rectangular sign
    private var usSign: some View {
        VStack(spacing: 2 * scale) {
            Text("SPEED")
                .font(.system(size: 14 * scale, weight: .heavy, design: .rounded))
            Text("LIMIT")
                .font(.system(size: 14 * scale, weight: .heavy, design: .rounded))
            Text(valueText)
                .font(.system(size: 46 * scale, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .foregroundStyle(.black)
        .frame(width: 110 * scale, height: 132 * scale)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .stroke(Color.black, lineWidth: 3 * scale)
                        .padding(6 * scale)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }
}

#Preview {
    ContentView()
        .environmentObject(LocationManager())
        .environmentObject(NetworkMonitor())
}
