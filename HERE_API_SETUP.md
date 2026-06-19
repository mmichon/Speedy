# 🚗 HERE API Setup Guide

## Overview

The Speedy app now uses HERE API as the primary source for speed limit data, with OpenStreetMap as a fallback. This provides more accurate and reliable speed limit information.

## Setup Instructions

### 1. Get a HERE API Key

1. Visit [HERE Developer Portal](https://developer.here.com/)
2. Sign up for a free account or log in
3. Create a new project
4. Generate an API key for your project
5. Note down your API key

### 2. Configure the API Key

In `SpeedLimitService.swift`, replace the placeholder API key:

```swift
// MARK: - HERE API Configuration
private let hereApiKey = "YOUR_HERE_API_KEY" // Replace with actual API key
```

Replace `"YOUR_HERE_API_KEY"` with your actual HERE API key.

### 3. API Usage Limits

- **Free Tier**: 250,000 platform transactions per month
- **Paid Plans**: Higher limits available
- **Rate Limiting**: The app implements comprehensive rate limiting to stay within limits
- **Safety Buffer**: Uses 90% of limit (225,000 transactions) to prevent overages
- **Automatic Fallbacks**: Switches to OpenStreetMap when limits are reached

## API Endpoints Used

### Primary: HERE Route Matching API v8
- **Endpoint**: `https://routematching.hereapi.com/v8/match/routelinks`
- **Purpose**: Get accurate speed limits and road names
- **Attributes**: `SPEED_LIMITS_FCn(*),ROAD_NAME_FCn(*),ROAD_GEOM_FCn(*)`

### Secondary: HERE Geocoding API
- **Endpoint**: `https://geocode.search.hereapi.com/v1/geocode`
- **Purpose**: Get road names when Route Matching doesn't provide them
- **Fallback**: Used when primary API doesn't return road names

## Fallback Strategy

1. **Primary**: HERE Route Matching API v8 (speed limits + road names)
2. **Fallback 1**: OpenStreetMap Overpass API (if HERE fails)
3. **Fallback 2**: HERE Geocoding API (for road names)
4. **Fallback 3**: OpenStreetMap Nominatim API (final fallback)

## Benefits of HERE API

- **Higher Accuracy**: Purpose-built for traffic and speed limit data
- **Better Coverage**: More comprehensive road data
- **Real-time Updates**: Regular updates to speed limit information
- **Official Support**: Backed by HERE's official documentation

## Troubleshooting

### API Key Issues
- Ensure your API key is correctly set in `SpeedLimitService.swift`
- Verify the API key is active in your HERE Developer Portal
- Check that you haven't exceeded your monthly quota

### Network Issues
- The app will automatically fall back to OpenStreetMap if HERE API is unavailable
- Cached data will be used when offline

### Data Quality
- HERE API provides more accurate speed limits than OpenStreetMap
- The app includes validation to filter out suspicious speed limit values
- Speed limit changes are validated to prevent dramatic jumps

## Monitoring

The app logs all API calls and responses for debugging:
- HERE API calls are logged with `[INFO]` level
- Fallback to OpenStreetMap is logged with `[WARNING]` level
- Errors are logged with `[ERROR]` level

## Rate Limiting System

### Overview
The app includes a comprehensive rate limiting system that ensures compliance with HERE API free tier limits:

- **Monthly Limit**: 225,000 transactions (90% of 250,000 for safety)
- **Daily Limit**: 7,500 transactions (90% of daily budget)
- **Hourly Limit**: 312 transactions (90% of hourly budget)

### Features
- **Persistent Storage**: Usage data survives app restarts
- **Monthly Reset**: Automatic reset on first day of each month
- **Real-time Tracking**: Live usage monitoring with alerts
- **Smart Fallbacks**: Automatic fallback to OpenStreetMap when limits reached
- **Usage Alerts**: Warnings at 75%, 90%, and 95% of monthly limit
- **Projection Analytics**: Predicts monthly usage based on current trends

### User Interface
- **Settings View**: Shows current usage statistics and status
- **Progress Bar**: Visual representation of monthly usage
- **Status Messages**: Clear indication of current rate limit status
- **Reset Information**: Shows when usage counters will reset

### Automatic Fallbacks
When HERE API limits are reached, the app automatically:
1. Switches to OpenStreetMap APIs for speed limit data
2. Logs the fallback reason for debugging
3. Continues to provide accurate speed limit information
4. Resumes HERE API usage when limits reset

## Cost Optimization

- **Caching**: All API responses are cached to minimize API calls
- **Rate Limiting**: Comprehensive rate limiting prevents exceeding quotas
- **Smart Fallbacks**: Only uses fallback APIs when necessary
- **Offline Support**: Uses cached data when network is unavailable
- **Usage Monitoring**: Real-time tracking of API usage with alerts
- **Monthly Reset**: Automatic reset of usage counters each month
- **Projection Analytics**: Predicts monthly usage based on current trends

---

**Note**: This implementation follows HERE's official documentation and best practices for speed limit data retrieval. The app will automatically handle API failures and provide the best available data through its comprehensive fallback system.
