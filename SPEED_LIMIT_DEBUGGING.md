# Speed Limit Debugging Guide

## Issue: Speed Limit Stuck at 35 MPH

The speed limit is getting stuck at 35 MPH and not updating when moving between different roads.

## Root Cause Analysis

The issue is in the `SpeedLimitService.swift` file. When the HERE API fails to return speed limit data, the service falls back to OpenStreetMap (Nominatim) which infers speed limits based on road types:

```swift
// Secondary roads
if lowerRoadType.contains("secondary") || lowerRoadType.contains("tertiary") {
    return 35 // Typical secondary road speed limit
}

// City area fallback
else if address.city != nil {
    return 35 // City area
}
```

## Why This Happens

1. **HERE API Failure**: The HERE Route Matching API is failing to return speed limit data
2. **Fallback to OpenStreetMap**: When HERE API fails, it uses OpenStreetMap which infers 35 MPH for many road types
3. **Cache Persistence**: The inferred speed limit gets cached and doesn't refresh properly
4. **Road Change Detection**: The service may not be detecting road changes correctly

## Debugging Steps

### 1. Check Console Logs

Look for these log messages in the console:

```
[INFO] SpeedLimitService: Starting HERE Route Matching API speed limit lookup
[ERROR] SpeedLimitService: HERE Route Matching API error: [error message]
[INFO] SpeedLimitService: Falling back to OpenStreetMap Nominatim for road information
[INFO] SpeedLimitService: Nominatim found: roadName=[road], inferredSpeedLimit=35
[WARNING] SpeedLimitService: Using OpenStreetMap fallback - speed limit may not be accurate
```

### 2. Test HERE API Key

The HERE API key in `SpeedLimitService.swift` might be invalid or expired:

```swift
private let hereApiKey = "5fv9JYSHWHDChhp0XR5r-RvDDJlXrQpsS31C2g2g5q0"
```

### 3. Check Network Connectivity

The service tests basic connectivity before making API calls. Look for:

```
[INFO] SpeedLimitService: Network connectivity test passed, proceeding with HERE API call
```

## Immediate Fixes

### 1. Force Refresh Speed Limit

Add this function to `LocationManager.swift`:

```swift
func forceRefreshSpeedLimit() {
    guard let location = locationManager.location else { return }
    print("Force refreshing speed limit")

    // Clear the current speed limit to force a refresh
    speedLimit = 0
    speedLimitKnown = false

    // Force the speed limit service to refresh
    speedLimitService.forceRefreshSpeedLimit(for: location.coordinate)
}
```

### 2. Add Cache Management

Add these functions to `SpeedLimitService.swift`:

```swift
func forceRefreshSpeedLimit(for coordinate: CLLocationCoordinate2D) {
    log("Force refreshing speed limit - clearing cache and bypassing cooldown", level: .info)

    // Clear all cached data
    lastKnownGoodSpeedLimit = nil
    lastApiCallTime = Date.distantPast

    // Clear current values
    DispatchQueue.main.async {
        self.currentSpeedLimit = nil
        self.currentRoadName = nil
        self.errorMessage = "Force refreshing speed limit..."
    }

    // Force a new lookup
    forceLookupSpeedLimit(for: coordinate)
}

func clearSpeedLimitCache() {
    log("Clearing speed limit cache", level: .info)
    lastKnownGoodSpeedLimit = nil
    lastApiCallTime = Date.distantPast
    lastRoadName = nil

    DispatchQueue.main.async {
        self.currentSpeedLimit = nil
        self.currentRoadName = nil
        self.errorMessage = "Cache cleared, ready for new lookup"
    }
}
```

### 3. Improve Road Change Detection

The `updateRoadName` function should be more aggressive about detecting road changes:

```swift
func updateRoadName(_ newRoadName: String?, for coordinate: CLLocationCoordinate2D) {
    // Check if road name has changed
    if let newRoadName = newRoadName, newRoadName != lastRoadName {
        log("Road name changed from '\(lastRoadName ?? "nil")' to '\(newRoadName)'. Triggering speed limit lookup.", level: .info)

        // Update the stored road name
        lastRoadName = newRoadName

        // Clear the current speed limit since it's for a different road
        DispatchQueue.main.async {
            self.currentSpeedLimit = nil
            self.errorMessage = "Road changed, looking up new speed limit..."
        }

        // Trigger a new speed limit lookup for the new road
        // Use forceLookupSpeedLimit to bypass cooldown since this is a road change
        forceLookupSpeedLimit(for: coordinate)
    } else if let newRoadName = newRoadName {
        // Road name is the same, just update it
        lastRoadName = newRoadName
    }
}
```

## Long-term Solutions

### 1. Fix HERE API Integration

- Verify the HERE API key is valid and has the correct permissions
- Check if the API endpoint has changed
- Implement better error handling for API failures

### 2. Improve Fallback Logic

- Use multiple fallback sources instead of just OpenStreetMap
- Implement better road type detection
- Add user override capability for incorrect speed limits

### 3. Better Caching Strategy

- Implement time-based cache expiration
- Add distance-based cache invalidation
- Provide manual cache clearing options

## Testing

### 1. Test on Different Roads

Drive on different types of roads to see if speed limits change:
- Residential streets (should be 25 MPH)
- Secondary roads (should be 35 MPH)
- Primary roads (should be 45 MPH)
- Highways (should be 65+ MPH)

### 2. Test Network Conditions

- Test with good network connectivity
- Test with poor network connectivity
- Test with no network connectivity

### 3. Monitor Console Logs

Watch for:
- HERE API success/failure messages
- Fallback to OpenStreetMap messages
- Road name change detection
- Speed limit updates

## Expected Behavior

- Speed limits should update when moving between different roads
- HERE API should provide accurate speed limits for most roads
- Fallback to OpenStreetMap should only happen when HERE API fails
- Cached speed limits should expire and refresh appropriately

## Current Status

The speed limit is stuck at 35 MPH because:
1. HERE API is failing to return speed limit data
2. Service is falling back to OpenStreetMap which infers 35 MPH
3. The inferred speed limit is not being refreshed when moving to different roads
4. Cache management is too aggressive and not clearing properly
