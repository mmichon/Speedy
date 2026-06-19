# Speed Limit Validation System

## Overview

The Speed Limit Validation System has been implemented to prevent dramatic and potentially incorrect speed limit changes that can occur when driving on the same road. This system helps maintain the most likely correct speed limit by validating new readings against historical data and reasonable thresholds.

## Problem Solved

Previously, the app could experience dramatic speed limit changes (e.g., 65 MPH → 25 MPH) while driving on the same road, which could be caused by:
- GPS positioning errors
- Incorrect map data
- API response inconsistencies
- Temporary road conditions or construction zones

**Important**: The validation system only applies when driving on the same road. When the road changes (e.g., turning from a highway onto a local street), dramatic speed limit changes are automatically allowed.

## Solution Components

### 1. Speed Limit Validation Properties

```swift
// MARK: - Speed Limit Validation System
private var lastValidSpeedLimit: (speed: Int, coordinate: CLLocationCoordinate2D, timestamp: Date, confidence: Int)?
private var speedLimitHistory: [(speed: Int, timestamp: Date)] = []
private let maxHistorySize = 10
private let dramaticChangeThreshold = 30 // MPH difference that triggers validation
private let confidenceThreshold = 3 // Number of consistent readings needed for high confidence
private let validationTimeWindow: TimeInterval = 300 // 5 minutes to validate dramatic changes
```

### 2. Core Validation Logic

The system uses a confidence-based approach:

- **Dramatic Change Detection**: Any speed limit change ≥ 30 MPH triggers validation
- **Confidence Scoring**: Each speed limit reading builds confidence (1-5 scale)
- **Historical Analysis**: Recent readings are analyzed for consistency
- **Time-based Validation**: Older speed limits are more likely to be updated

### 3. Validation Rules

The system accepts dramatic changes when:

1. **Road Change**: The road name has changed (e.g., turning onto a different street)
2. **Old Data**: Last valid speed limit is > 5 minutes old
3. **Consistent History**: Recent readings show low variance and new speed is close to average
4. **Reasonable Speed**: New speed limit is within typical road speed ranges
5. **Low Confidence**: Previous speed limit had low confidence (< 4/5)

The system rejects dramatic changes when:

1. **Same Road**: We're still on the same road (road name hasn't changed)
2. **High Confidence**: Previous speed limit had high confidence (≥ 4/5)
3. **Inconsistent History**: Recent readings are inconsistent
4. **Unreasonable Speed**: New speed is outside typical ranges (15-85 MPH)
5. **Insufficient Evidence**: No compelling reason to accept the change

### 4. Key Methods

#### `validateSpeedLimitChange(newSpeed:coordinate:)`
- Main validation entry point
- Compares new speed against last valid speed
- Triggers dramatic change validation when needed
- Updates confidence levels

#### `shouldAcceptDramaticChange(newSpeed:lastValid:coordinate:)`
- Evaluates whether a dramatic change should be accepted
- Uses multiple validation criteria
- Returns true/false based on evidence

#### `addToSpeedLimitHistory(_:)`
- Maintains rolling history of speed limit readings
- Limits history to 10 entries
- Filters out old entries (> 5 minutes)

#### `isSpeedLimitReasonableForLocation(_:coordinate:)`
- Validates speed limits against typical road speeds
- Checks for reasonable speed ranges (25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75 MPH)

#### `hasRoadChanged()`
- Checks if the current road name differs from the last validation road name
- Returns true if road has changed, allowing dramatic speed limit changes

## Usage Examples

### Normal Speed Limit Change
```
Current: 45 MPH → New: 50 MPH (5 MPH difference)
Result: Accepted (normal change)
Confidence: Increased from 3 to 4
```

### Dramatic Speed Limit Change (Rejected)
```
Current: 65 MPH → New: 25 MPH (40 MPH difference)
Result: Rejected (maintains 65 MPH)
Reason: High confidence in current speed limit
```

### Dramatic Speed Limit Change (Accepted)
```
Current: 65 MPH → New: 25 MPH (40 MPH difference)
Result: Accepted
Reason: Last valid speed limit is 6 minutes old (stale data)
```

### Road Change with Dramatic Speed Limit Change
```
Current: 65 MPH → New: 25 MPH (40 MPH difference)
Result: Accepted
Reason: Road changed from "Interstate 95" to "Main Street"
```

## Configuration

The system can be tuned by adjusting these parameters:

- `dramaticChangeThreshold`: 30 MPH (triggers validation)
- `confidenceThreshold`: 3 readings (for consistency analysis)
- `validationTimeWindow`: 300 seconds (5 minutes)
- `maxHistorySize`: 10 entries (history limit)

## Monitoring and Debugging

### Validation Status
```swift
let status = speedLimitService.getValidationStatus()
print("Last valid speed: \(status.lastValidSpeed ?? 0)")
print("Confidence: \(status.confidence)/5")
print("History count: \(status.historyCount)")
print("Validation active: \(status.isValidationActive)")
print("Current road: \(status.currentRoad ?? "Unknown")")
print("Last validation road: \(status.lastValidationRoad ?? "Unknown")")
```

### Logging
The system provides detailed logging for all validation decisions:
- `[INFO]` for accepted changes
- `[WARN]` for dramatic changes detected
- `[DEBUG]` for normal operations

### Cache Management
```swift
// Clear validation system
speedLimitService.clearSpeedLimitValidation()

// Clear all caches including validation
speedLimitService.clearSpeedLimitCache()
```

## Benefits

1. **Reduced False Positives**: Dramatic speed limit changes are validated before acceptance
2. **Improved User Experience**: More stable speed limit display
3. **Confidence Tracking**: System learns from consistent readings
4. **Graceful Degradation**: Falls back to last known good speed limit when needed
5. **Configurable**: Parameters can be adjusted based on real-world usage

## Integration

The validation system is automatically integrated into the existing speed limit lookup flow:

1. API calls return speed limit data
2. `processOpenStreetMapResults()` calls `validateSpeedLimitChange()`
3. Validated speed limit is used for display and caching
4. Widgets are updated with validated data

This ensures that all speed limit updates go through the validation system without requiring changes to the existing UI or widget code.
