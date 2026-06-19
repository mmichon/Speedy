# Speedy - iOS Speed Tracking App

A SwiftUI-based iOS app that tracks your current speed and automatically detects speed limits using GPS coordinates.

## 🚗 Features

- **Real-time Speed Tracking**: Updates your current speed every 0.5 seconds, with smoothing and stationary detection to prevent phantom speeds
- **Automatic Speed Limit Detection**: Uses HERE API (primary) with OpenStreetMap fallback (Overpass + Nominatim) to look up the current road's speed limit
- **Speed Limit Warnings**: Visual and audible alerts when you exceed the adjusted speed limit (with a buffer to prevent false positives)
- **Configurable Speed Limit Offset**: Set your alert threshold relative to the posted limit (e.g. +5 MPH)
- **Units Toggle**: Switch between MPH and KPH (metric/imperial)
- **Road Name Display**: Shows the current road name when available
- **Live Activities & Dynamic Island**: Live speed/limit display on the lock screen and Dynamic Island (iOS 16.1+), automatically shown while moving and hidden a few seconds after you stop
- **CarPlay Live Mode**: Live Activity is forwarded to the CarPlay dashboard on iOS 18.4+
- **Apple Watch App**: Companion watchOS app with its own speed and speed-limit display
- **Home Screen & Control Widgets**: WidgetKit widgets including a Control Center widget
- **Sound Alerts**: Audible speeding alerts via `SoundManager` (with a startup grace period)
- **Speed Limit Caching**: Local cache to reduce API calls and provide offline fallback
- **API Rate Limiting**: Built-in HERE API rate limiter and network monitoring
- **GPX Test Mode**: Play back a recorded GPX route for testing without driving
- **Customizable Speed Limits**: Manually override auto-detected speed limits
- **Beautiful UI**: Modern gradient design with smooth animations
- **Location Permissions**: Proper handling of location access requests

## 🛠️ Requirements

- iOS 15.0+ (core app)
- iOS 16.1+ for Live Activities/Dynamic Island/CarPlay live mode
- Xcode 14.1+ (for iOS 16.1 SDK)
- Swift 5.7+
- iPhone or iPad with GPS capabilities

## 📱 Setup Instructions

### 1. Open the Project
- Open `Speedy.xcodeproj` in Xcode
- Select your target device or simulator

### 2. Configure Bundle Identifier
- In Xcode, select your project
- Go to the "Signing & Capabilities" tab
- Update the Bundle Identifier to something unique (e.g., `com.yourname.Speedy`)

### 3. Configure API Keys (for speed limits)
- See `HERE_API_SETUP.md` for obtaining a HERE key (TomTom is optional)
- Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` (this file is gitignored)
- Fill in `HERE_API_KEY` (and optionally `TOMTOM_API_KEY`)
- The keys are injected into `Info.plist` at build time (`$(HERE_API_KEY)` / `$(TOMTOM_API_KEY)`) and read at runtime via `SpeedLimitService.infoPlistKey(...)` — no source edits needed

### 4. Build and Run
- Press `Cmd + R` to build and run the app
- The app will request location permissions when first launched

## 🎯 Usage

### 1. **Grant Location Access**
- When prompted, allow the app to access your location
- This is required for speed tracking functionality

### 2. **View Current Speed**
- The main screen displays your current speed in large, easy-to-read numbers
- Speed updates every 0.5 seconds for real-time feedback

### 3. **Automatic Speed Limit Detection**
- The app automatically detects speed limits using HERE API with OpenStreetMap fallback
- Speed limits are updated every ~5 seconds (configurable) and when you change roads
- Current road name is displayed when available

### 4. **Manual Speed Limit Override**
- Tap the gear icon in the top-right corner
- Use the picker to manually set a speed limit
- Tap "Refresh Speed Limit" to re-detect from GPS
- Tap "Apply Speed Limit" to save manual override

### 5. **Speed Warnings**
- The app will automatically warn you when you exceed the adjusted speed limit (your configured offset, with a small buffer to prevent false positives)
- A red "SPEEDING!" warning appears with an animated triangle icon

## 🏗️ Technical Details

### Architecture
- **SwiftUI**: Modern declarative UI framework
- **MVVM Pattern**: Clean separation of concerns
- **Combine**: Reactive programming for data binding
- **ActivityKit / WidgetKit**: Live Activities, Dynamic Island, and home/Control Center widgets
- **Shared Framework**: `SpeedyShared` holds models and data shared between the app, widget, and watch targets (via an App Group)

### Key Components
- `SpeedyApp.swift`: Main app entry point
- `ContentView.swift`: Primary UI with speed display and warnings
- `LocationManager.swift`: GPS location handling, speed calculations, and Live Activity lifecycle
- `SpeedLimitService.swift`: Automatic speed limit detection using GPS coordinates
- `SpeedLimitCache.swift`: Local caching of speed-limit lookups
- `HERERateLimiter.swift`: Rate limiting for HERE API requests
- `NetworkMonitor.swift`: Connectivity monitoring for online/offline behavior
- `SoundManager.swift`: Audible speeding alerts
- `AdManager.swift`: Google Mobile Ads integration
- `GPXParser.swift`: GPX route playback for test mode
- `SettingsView.swift`: Speed limit, offset, and unit configuration interface
- `SpeedyWidget/`: WidgetKit extension (Live Activity, Dynamic Island, Control widget)
- `Speedy Watch App/`: Companion watchOS app
- `SpeedyShared/`: Shared models/data manager used across targets

### Location Services
- Uses `CoreLocation` framework for GPS access
- Implements `CLLocationManagerDelegate` for location updates
- Timer-based speed updates every 0.5 seconds for consistent UI updates
- Automatic speed limit checking with configurable thresholds

### Speed Limit Detection
- **HERE API First**: Route Matching API v8 for accurate speed limits and road names
- **OpenStreetMap Fallbacks**: Overpass (speed limits) and Nominatim (road names)
- **GPS-based Lookups**: Automatically detects speed limits based on current coordinates
- **Smart Updates**: Refreshes speed limits every ~5 seconds and on road changes
- **Fallback Support**: Manual speed limit override when automatic detection fails
- **Road Information**: Displays current road name when available

### Permissions
- `NSLocationWhenInUseUsageDescription`: Required for location access
- `NSLocationAlwaysAndWhenInUseUsageDescription`: Alternative permission option

## 🔧 Troubleshooting

### Location Not Working
- Ensure location services are enabled on your device
- Check that the app has location permissions
- Verify GPS signal strength (indoor use may be limited)

### Speed Not Updating
- The app requires movement to calculate speed
- Ensure you're in a vehicle or moving at a reasonable speed
- Check that location permissions are granted

### Build Errors
- Ensure you're using iOS 15.0+ as the deployment target
- Verify all SwiftUI imports are present
- Check that the bundle identifier is unique

## 🔒 Privacy

This app:
- Only accesses location data when actively running
- Does not store or transmit location data
- Requires explicit user permission for location access
- Respects iOS privacy settings and restrictions

## 📄 License

This project is provided as-is for educational and personal use.

## 🆘 Support

For issues or questions:
1. Check the troubleshooting section above
2. Verify your iOS version and device compatibility
3. Ensure all permissions are properly granted
