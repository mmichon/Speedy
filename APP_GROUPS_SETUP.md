# App Groups Setup for Speedy Widget

## Overview
This guide explains how to configure App Groups in Xcode to enable data sharing between the main Speedy app and the home screen widget.

## Why App Groups?
iOS widgets run in a separate process and cannot directly access the main app's memory. App Groups provide a shared container that both the main app and widget can access.

## Setup Steps

### 1. Enable App Groups Capability

#### For Main App Target (Speedy):
1. Select the Speedy project in Xcode
2. Select the "Speedy" target
3. Go to "Signing & Capabilities" tab
4. Click "+ Capability"
5. Add "App Groups"
6. Click "+" under App Groups
7. Add: `group.com.speedy.app`

#### For Widget Target (SpeedyWidget):
1. Select the "SpeedyWidget" target
2. Go to "Signing & Capabilities" tab
3. Click "+ Capability"
4. Add "App Groups"
5. Click "+" under App Groups
6. Add: `group.com.speedy.app`

### 2. Verify Bundle Identifiers

Make sure both targets have consistent bundle identifiers:
- Main App: `com.speedy.app` (or your preferred identifier)
- Widget: `com.speedy.app.SpeedyWidget`

### 3. Build and Test

1. Clean build folder (Product → Clean Build Folder)
2. Build the project
3. Run on device (widgets don't work in simulator)
4. Add the widget to your home screen
5. The widget should now display real-time data from the app

## How It Works

1. **Main App**: Saves data to shared container using `SpeedyDataManager.shared.saveWidgetData()`
2. **Widget**: Reads data from shared container using `loadWidgetData()`
3. **Data Updates**: Widget refreshes every 30 seconds and when app data changes
4. **Fallback**: Widget shows placeholder data if no real data is available

## Troubleshooting

### Widget Still Shows Old Data
- Check that App Groups are properly configured
- Verify both targets have the same App Group identifier
- Clean and rebuild the project
- Delete and re-add the widget to home screen

### Build Errors
- Ensure App Groups capability is added to both targets
- Check that bundle identifiers are consistent
- Verify signing certificates support App Groups

### Data Not Updating
- Check that `saveWidgetData()` is being called in LocationManager
- Verify the shared container path matches in both targets
- Ensure the widget timeline is set to update frequently enough

## Code Changes Made

1. **SpeedyShared.swift**: Added shared data model and UserDefaults extension
2. **SpeedyDataManager.swift**: Created data manager for saving/loading widget data
3. **LocationManager.swift**: Added calls to save widget data when relevant data changes
4. **SpeedyWidget.swift**: Updated widget to read real data instead of hardcoded values

## Testing

After setup:
1. Run the app and drive around
2. Add the widget to home screen
3. Verify the widget shows real speed, speed limit, and road name
4. Check that data updates as you drive
5. Verify speeding indicators work correctly
