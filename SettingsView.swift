import SwiftUI
import SpeedyShared

struct SettingsView: View {
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSpeedLimitOffset: Int = 0
    @State private var keepScreenOn: Bool = false
    @State private var soundAlertsEnabled: Bool = false
    @AppStorage("adsEnabled") private var adsEnabled: Bool = false
    @StateObject private var speedLimitService = SpeedLimitService.shared
    @State private var showCacheClearedMessage: Bool = false

    private let speedLimitOffsets = Array(stride(from: -20, through: 20, by: 5))

    private var displayedSpeedLimit: Int {
        if locationManager.unitPreference == .metric {
            return Int(Double(locationManager.speedLimit) * 1.60934)
        } else {
            return locationManager.speedLimit
        }
    }

    private var displayedSpeedLimitOffset: Int {
        if locationManager.unitPreference == .metric {
            return Int(Double(locationManager.speedLimitOffset) * 1.60934)
        } else {
            return locationManager.speedLimitOffset
        }
    }

    private func displayedOffset(for offset: Int) -> String {
        let convertedOffset: Int
        if locationManager.unitPreference == .metric {
            convertedOffset = Int(Double(offset) * 1.60934)
        } else {
            convertedOffset = offset
        }
        return "\(convertedOffset > 0 ? "+" : "")\(convertedOffset) \(locationManager.unitPreference.unitString)"
    }

    var body: some View {
        NavigationView {
            Form {
                speedLimitOffsetSection
                displaySettingsSection
                monetizationSection
                unitSettingsSection
                soundSettingsSection
                hereApiUsageSection
                debugSection
                appInformationSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSettings()
            }
            .onChange(of: locationManager.shouldResetOffset) { _, newValue in
                if newValue {
                    selectedSpeedLimitOffset = 0
                    locationManager.shouldResetOffset = false
                }
            }
        }
    }

    // MARK: - View Sections

    private var speedLimitOffsetSection: some View {
        Section(header: Text("Speed Limit Offset")) {
            Picker("Speed Limit Offset", selection: $selectedSpeedLimitOffset) {
                ForEach(speedLimitOffsets, id: \.self) { offset in
                    Text(displayedOffset(for: offset))
                        .tag(offset)
                }
            }
            .pickerStyle(WheelPickerStyle())
            .onChange(of: selectedSpeedLimitOffset) { _, newValue in
                handleSpeedLimitOffsetChange(newValue)
            }

            HStack {
                Text("Current Speed Limit:")
                Spacer()
                Text("\(displayedSpeedLimit) \(locationManager.unitPreference.unitString)")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Alert Limit:")
                Spacer()
                Text("\(displayedSpeedLimit + displayedSpeedLimitOffset) \(locationManager.unitPreference.unitString)")
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .cornerRadius(8)
            }

            if let message = locationManager.alertMessage {
                Text(message)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }

    private var displaySettingsSection: some View {
        Section(header: Text("Display Settings")) {
            Toggle("Keep Screen On", isOn: $keepScreenOn)
                .onChange(of: keepScreenOn) { _, newValue in
                    handleKeepScreenOnChange(newValue)
                }

            if #available(iOS 16.1, *) {
                Toggle("Live Activities", isOn: $locationManager.liveActivitiesEnabled)
                    .onChange(of: locationManager.liveActivitiesEnabled) { _, newValue in
                        locationManager.updateLiveActivitiesPreference(newValue)
                    }

                Text("Shows speed information in Dynamic Island and Lock Screen")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var monetizationSection: some View {
        Section(header: Text("Monetization")) {
            Toggle("Enable Ads (support development)", isOn: $adsEnabled)
                .onChange(of: adsEnabled) { _, newValue in
                    handleAdsEnabledChange(newValue)
                }
            Text("Shows a small banner ad at the bottom when enabled.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var unitSettingsSection: some View {
        Section(header: Text("Unit Settings")) {
            Picker("Unit Preference", selection: $locationManager.unitPreference) {
                ForEach(SpeedyShared.Unit.allCases) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: locationManager.unitPreference) { _, newValue in
                locationManager.updateUnitPreference(newValue)
            }

            Text("Current: \(locationManager.unitPreference.unitString)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var soundSettingsSection: some View {
        Section(header: Text("Sound Settings")) {
            Toggle("Sound Alerts", isOn: $soundAlertsEnabled)
                .onChange(of: soundAlertsEnabled) { _, newValue in
                    handleSoundAlertsChange(newValue)
                }

            Text("Plays a ping sound when exceeding the speed limit")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var hereApiUsageSection: some View {
        Section(header: Text("HERE API Usage")) {
            HEREUsageView()
        }
    }

    private var debugSection: some View {
        Section(header: Text("Debug")) {
            Button("Toggle Test Mode: \(locationManager.testModeEnabled ? "ON" : "OFF")") {
                handleTestModeToggle()
            }
            .foregroundColor(locationManager.testModeEnabled ? .red : .primary)
            .fontWeight(locationManager.testModeEnabled ? .bold : .regular)

            if locationManager.testModeEnabled {
                Text("Test Mode Active: Speed set to 100 \(locationManager.unitPreference.unitString) to trigger speeding indicators")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Clear Speed Limit Cache") {
                handleCacheClear()
            }
            .foregroundColor(.orange)
            .fontWeight(.medium)

            if showCacheClearedMessage {
                Text("✅ Cache cleared! Fresh speed limit lookup initiated.")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Clears all cached speed limit data and forces a fresh lookup from APIs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var appInformationSection: some View {
        Section(header: Text("App Information")) {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Methods

    private func loadSettings() {
        selectedSpeedLimitOffset = UserDefaults.standard.integer(forKey: "speedLimitOffset")
        keepScreenOn = UserDefaults.standard.bool(forKey: "keepScreenOn")
        soundAlertsEnabled = UserDefaults.standard.bool(forKey: "soundAlertsEnabled")
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }

    private func handleSpeedLimitOffsetChange(_ newValue: Int) {
        locationManager.updateSpeedLimitOffset(newValue, unit: locationManager.unitPreference)
        if locationManager.alertMessage == nil {
            UserDefaults.standard.set(newValue, forKey: "speedLimitOffset")
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    private func handleKeepScreenOnChange(_ newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: "keepScreenOn")
        UIApplication.shared.isIdleTimerDisabled = newValue
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    private func handleAdsEnabledChange(_ newValue: Bool) {
        if newValue {
            AdManager.shared.start()
        }
    }

    private func handleSoundAlertsChange(_ newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: "soundAlertsEnabled")
        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    private func handleTestModeToggle() {
        locationManager.testModeEnabled.toggle()
        UserDefaults.standard.set(locationManager.testModeEnabled, forKey: "testModeEnabled")
        locationManager.triggerSpeedUpdate()
    }

    private func handleCacheClear() {
        print("[DEBUG] SettingsView: Manual cache clear initiated by user")

        speedLimitService.clearSpeedLimitCache()
        print("[DEBUG] SettingsView: Speed limit cache cleared")

        APICacheManager.shared.clearCache()
        print("[DEBUG] SettingsView: API cache cleared")

        if let location = locationManager.location {
            print("[DEBUG] SettingsView: Forcing fresh speed limit lookup for current location")
            speedLimitService.forceRefreshSpeedLimit(for: location.coordinate)
        } else {
            print("[DEBUG] SettingsView: No current location available for fresh lookup")
        }

        SpeedyDataManager.shared.forceWidgetRefresh()
        print("[DEBUG] SettingsView: Widget refresh triggered")

        showCacheClearedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showCacheClearedMessage = false
        }
    }
}

// MARK: - HERE API Usage View
struct HEREUsageView: View {
    @StateObject private var speedLimitService = SpeedLimitService.shared
    @State private var usageStats: HEREUsageStats?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let stats = usageStats {
                // Monthly usage
                HStack {
                    Text("This Month:")
                    Spacer()
                    Text("\(stats.monthlyUsage) / 225,000")
                        .foregroundColor(usageColor(stats.usagePercentage))
                }

                // Progress bar
                ProgressView(value: Double(stats.monthlyUsage), total: 225000)
                    .progressViewStyle(LinearProgressViewStyle(tint: usageColor(stats.usagePercentage)))

                // Daily usage
                HStack {
                    Text("Today:")
                    Spacer()
                    Text("\(stats.dailyUsage) / 7,500")
                        .foregroundColor(.secondary)
                }

                // Status message
                HStack {
                    Text("Status:")
                    Spacer()
                    Text(speedLimitService.getHEREStatusMessage())
                        .foregroundColor(usageColor(stats.usagePercentage))
                        .font(.caption)
                }

                // Reset date
                Text("Resets: \(stats.nextResetDate, formatter: dateFormatter)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Projected usage
                if stats.projectedMonthlyUsage > 225000 {
                    Text("⚠️ Projected to exceed limit this month")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                Text("Loading usage statistics...")
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            loadUsageStats()
        }
    }

    private func loadUsageStats() {
        usageStats = speedLimitService.getHEREUsageStats()
    }

    private func usageColor(_ percentage: Double) -> Color {
        switch percentage {
        case 0.9...1.0: return .red
        case 0.75..<0.9: return .orange
        default: return .green
        }
    }
}

#Preview {
    SettingsView(locationManager: LocationManager())
}
