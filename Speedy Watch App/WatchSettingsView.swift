import SwiftUI
import SpeedyShared

struct WatchSettingsView: View {
    @EnvironmentObject var locationManager: WatchLocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Units") {
                    Picker("Speed Units", selection: $locationManager.unitPreference) {
                        Text("Imperial (MPH)").tag(SpeedyShared.Unit.imperial)
                        Text("Metric (KPH)").tag(SpeedyShared.Unit.metric)
                    }
                    .pickerStyle(.wheel)
                    .onChange(of: locationManager.unitPreference) { _, newValue in
                        locationManager.updateUnitPreference(newValue)
                    }

                    Text("Current: \(locationManager.unitPreference.unitString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Status") {
                    HStack {
                        Text("Network")
                        Spacer()
                        Text(locationManager.isNetworkOnline ? "Online" : "Offline")
                            .foregroundColor(locationManager.isNetworkOnline ? .green : .red)
                    }

                    HStack {
                        Text("Speed Limit")
                        Spacer()
                        Text(locationManager.speedLimitKnown ? "Known" : "Unknown")
                            .foregroundColor(locationManager.speedLimitKnown ? .green : .orange)
                    }

                    HStack {
                        Text("Location")
                        Spacer()
                        Text(locationManager.locationStatus == .authorizedWhenInUse ? "Authorized" : "Not Authorized")
                            .foregroundColor(locationManager.locationStatus == .authorizedWhenInUse ? .green : .red)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("App")
                        Spacer()
                        Text("Speedy Watch")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    WatchSettingsView()
        .environmentObject(WatchLocationManager())
}
