# 🚦 HERE API Rate Limiting System

## Overview
This document outlines the comprehensive rate limiting system implemented for HERE API calls to ensure compliance with the free tier limit of **250,000 platform transactions per month**.

## 🎯 Rate Limiting Strategy

### Monthly Transaction Limits
- **Free Tier Limit**: 250,000 platform transactions per month
- **Daily Budget**: ~8,333 transactions per day (250,000 ÷ 30 days)
- **Hourly Budget**: ~347 transactions per hour (8,333 ÷ 24 hours)
- **Safety Buffer**: 90% of limit (225,000 transactions) to avoid overages

### API Call Types
1. **HERE Route Matching API**: Primary speed limit data
2. **HERE Geocoding API**: Road name fallback
3. **Combined Transaction**: Each coordinate lookup = 1-2 transactions

## 🏗️ Architecture

### Rate Limiting Components
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   HERE API      │───▶│  Monthly Rate    │───▶│  API Call      │
│   Request       │    │  Limiter         │    │  Execution     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │  Usage Tracker   │
                       │  (Persistent)    │
                       └──────────────────┘
```

### Key Features
- **Persistent Storage**: Usage data survives app restarts
- **Monthly Reset**: Automatic reset on first day of each month
- **Real-time Tracking**: Live usage monitoring
- **Smart Fallbacks**: Automatic fallback to OpenStreetMap when limits reached
- **Usage Alerts**: Warnings at 75%, 90%, and 95% of monthly limit

## 📊 Implementation Details

### Usage Tracking
```swift
struct HEREUsageData: Codable {
    let month: String           // "2024-01" format
    let totalTransactions: Int  // Total API calls this month
    let lastResetDate: Date     // When monthly limit was reset
    let dailyUsage: [String: Int] // Daily breakdown
    let hourlyUsage: [String: Int] // Hourly breakdown (last 24h)
}

class HERERateLimiter {
    private let monthlyLimit = 225000  // 90% of 250k for safety
    private let dailyLimit = 7500      // 90% of daily budget
    private let hourlyLimit = 312      // 90% of hourly budget

    private var usageData: HEREUsageData
    private let storageKey = "HERE_API_USAGE_DATA"
}
```

### Rate Limiting Logic
```swift
enum HERERateLimitStatus {
    case allowed
    case dailyLimitReached
    case hourlyLimitReached
    case monthlyLimitReached
    case approachingLimit(percentage: Double)
}

func checkRateLimit() -> HERERateLimitStatus {
    let currentUsage = getCurrentUsage()

    // Check monthly limit
    if currentUsage.totalTransactions >= monthlyLimit {
        return .monthlyLimitReached
    }

    // Check daily limit
    let todayUsage = getTodayUsage()
    if todayUsage >= dailyLimit {
        return .dailyLimitReached
    }

    // Check hourly limit
    let currentHourUsage = getCurrentHourUsage()
    if currentHourUsage >= hourlyLimit {
        return .hourlyLimitReached
    }

    // Check if approaching limits
    let monthlyPercentage = Double(currentUsage.totalTransactions) / Double(monthlyLimit)
    if monthlyPercentage >= 0.75 {
        return .approachingLimit(percentage: monthlyPercentage)
    }

    return .allowed
}
```

### Usage Tracking
```swift
func recordAPICall(apiType: HEREAPIType) {
    let now = Date()
    let calendar = Calendar.current

    // Update monthly usage
    usageData.totalTransactions += 1

    // Update daily usage
    let todayKey = DateFormatter.monthDay.string(from: now)
    usageData.dailyUsage[todayKey, default: 0] += 1

    // Update hourly usage
    let hourKey = DateFormatter.hour.string(from: now)
    usageData.hourlyUsage[hourKey, default: 0] += 1

    // Clean up old hourly data (keep only last 24 hours)
    cleanupOldHourlyData()

    // Save to persistent storage
    saveUsageData()

    // Check for alerts
    checkUsageAlerts()
}
```

## 🔄 Monthly Reset Logic
```swift
func checkMonthlyReset() {
    let calendar = Calendar.current
    let now = Date()

    // Check if we're in a new month
    let currentMonth = calendar.component(.month, from: now)
    let currentYear = calendar.component(.year, from: now)
    let storedMonth = calendar.component(.month, from: usageData.lastResetDate)
    let storedYear = calendar.component(.year, from: usageData.lastResetDate)

    if currentMonth != storedMonth || currentYear != storedYear {
        // Reset monthly usage
        usageData = HEREUsageData(
            month: "\(currentYear)-\(String(format: "%02d", currentMonth))",
            totalTransactions: 0,
            lastResetDate: now,
            dailyUsage: [:],
            hourlyUsage: [:]
        )

        saveUsageData()
        log("HERE API usage reset for new month: \(usageData.month)", level: .info)
    }
}
```

## 🚨 Usage Alerts
```swift
func checkUsageAlerts() {
    let percentage = Double(usageData.totalTransactions) / Double(monthlyLimit)

    switch percentage {
    case 0.95...1.0:
        log("🚨 CRITICAL: HERE API usage at \(Int(percentage * 100))% of monthly limit!", level: .error)
        // Disable HERE API calls, use only fallbacks

    case 0.90..<0.95:
        log("⚠️ WARNING: HERE API usage at \(Int(percentage * 100))% of monthly limit", level: .warning)
        // Reduce HERE API usage, prefer fallbacks

    case 0.75..<0.90:
        log("📊 INFO: HERE API usage at \(Int(percentage * 100))% of monthly limit", level: .info)
        // Monitor usage more closely

    default:
        break
    }
}
```

## 🔧 Integration with SpeedLimitService

### Modified API Call Flow
```swift
private func makeHereApiCallsCached(coordinate: CLLocationCoordinate2D) {
    // Check rate limits first
    let rateLimitStatus = hereRateLimiter.checkRateLimit()

    switch rateLimitStatus {
    case .allowed:
        // Proceed with HERE API calls
        makeHereApiCalls(coordinate: coordinate)

    case .monthlyLimitReached:
        log("HERE API monthly limit reached, using OpenStreetMap fallback", level: .warning)
        makeOpenStreetMapApiCallsCached(coordinate: coordinate)

    case .dailyLimitReached:
        log("HERE API daily limit reached, using OpenStreetMap fallback", level: .warning)
        makeOpenStreetMapApiCallsCached(coordinate: coordinate)

    case .hourlyLimitReached:
        log("HERE API hourly limit reached, using OpenStreetMap fallback", level: .warning)
        makeOpenStreetMapApiCallsCached(coordinate: coordinate)

    case .approachingLimit(let percentage):
        log("HERE API usage at \(Int(percentage * 100))%, proceeding with caution", level: .info)
        makeHereApiCalls(coordinate: coordinate)
    }
}

private func makeHereApiCalls(coordinate: CLLocationCoordinate2D) {
    // Record API call before making it
    hereRateLimiter.recordAPICall(apiType: .routeMatching)

    // Make HERE Route Matching API call
    getSpeedLimitAndRoadNameFromHereCached(coordinate: coordinate) { result in
        switch result {
        case .success(let (name, speed)):
            // Success - data cached automatically
            break
        case .failure(let error):
            // Record failed call (still counts against limit)
            log("HERE API call failed: \(error.localizedDescription)", level: .warning)
        }
    }
}
```

## 📱 User Interface Integration

### Settings View Updates
```swift
struct HEREUsageView: View {
    @StateObject private var rateLimiter = HERERateLimiter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HERE API Usage")
                .font(.headline)

            // Monthly usage
            HStack {
                Text("This Month:")
                Spacer()
                Text("\(rateLimiter.currentUsage.totalTransactions) / 225,000")
                    .foregroundColor(usageColor)
            }

            // Progress bar
            ProgressView(value: Double(rateLimiter.currentUsage.totalTransactions),
                        total: 225000)
                .progressViewStyle(LinearProgressViewStyle(tint: usageColor))

            // Daily usage
            HStack {
                Text("Today:")
                Spacer()
                Text("\(rateLimiter.todayUsage) / 7,500")
            }

            // Reset date
            Text("Resets: \(rateLimiter.nextResetDate, formatter: dateFormatter)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var usageColor: Color {
        let percentage = Double(rateLimiter.currentUsage.totalTransactions) / 225000
        switch percentage {
        case 0.9...1.0: return .red
        case 0.75..<0.9: return .orange
        default: return .green
        }
    }
}
```

## 🔍 Monitoring and Debugging

### Usage Statistics
```swift
struct HEREUsageStats {
    let monthlyUsage: Int
    let dailyUsage: Int
    let hourlyUsage: Int
    let remainingMonthly: Int
    let remainingDaily: Int
    let remainingHourly: Int
    let usagePercentage: Double
    let nextResetDate: Date
    let averageDailyUsage: Double
    let projectedMonthlyUsage: Int
}

func getUsageStats() -> HEREUsageStats {
    let current = getCurrentUsage()
    let today = getTodayUsage()
    let currentHour = getCurrentHourUsage()

    let daysInMonth = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
    let daysPassed = Calendar.current.component(.day, from: Date())
    let averageDaily = Double(current.totalTransactions) / Double(daysPassed)
    let projected = Int(averageDaily * Double(daysInMonth))

    return HEREUsageStats(
        monthlyUsage: current.totalTransactions,
        dailyUsage: today,
        hourlyUsage: currentHour,
        remainingMonthly: monthlyLimit - current.totalTransactions,
        remainingDaily: dailyLimit - today,
        remainingHourly: hourlyLimit - currentHour,
        usagePercentage: Double(current.totalTransactions) / Double(monthlyLimit),
        nextResetDate: getNextResetDate(),
        averageDailyUsage: averageDaily,
        projectedMonthlyUsage: projected
    )
}
```

### Debug Logging
```swift
func logUsageStats() {
    let stats = getUsageStats()

    log("=== HERE API Usage Statistics ===", level: .info)
    log("Monthly: \(stats.monthlyUsage)/225,000 (\(Int(stats.usagePercentage * 100))%)", level: .info)
    log("Daily: \(stats.dailyUsage)/7,500", level: .info)
    log("Hourly: \(stats.hourlyUsage)/312", level: .info)
    log("Projected Monthly: \(stats.projectedMonthlyUsage)", level: .info)
    log("Next Reset: \(stats.nextResetDate)", level: .info)
    log("================================", level: .info)
}
```

## 🚀 Benefits

### Cost Protection
- **Prevents Overages**: Stays within free tier limits
- **Smart Fallbacks**: Automatically uses OpenStreetMap when limits reached
- **Usage Monitoring**: Real-time tracking and alerts
- **Predictive Analytics**: Projects monthly usage based on current trends

### User Experience
- **Transparent**: Users can see API usage in settings
- **Seamless**: Automatic fallbacks maintain functionality
- **Reliable**: Consistent service even when limits reached
- **Informative**: Clear warnings and usage statistics

### Developer Benefits
- **Persistent Storage**: Usage data survives app restarts
- **Comprehensive Logging**: Detailed usage and performance metrics
- **Flexible Configuration**: Easy to adjust limits and thresholds
- **Integration Ready**: Drop-in replacement for existing API calls

## 🔧 Configuration Options

### Adjustable Parameters
```swift
// Rate limiting configuration
private let monthlyLimit = 225000      // 90% of 250k for safety
private let dailyLimit = 7500          // 90% of daily budget
private let hourlyLimit = 312          // 90% of hourly budget

// Alert thresholds
private let criticalThreshold = 0.95   // 95% - disable HERE API
private let warningThreshold = 0.90    // 90% - reduce usage
private let infoThreshold = 0.75       // 75% - monitor closely

// Storage configuration
private let storageKey = "HERE_API_USAGE_DATA"
private let cleanupInterval: TimeInterval = 3600 // 1 hour
```

This comprehensive rate limiting system ensures the app stays within HERE API free tier limits while providing excellent user experience through intelligent fallbacks and transparent usage monitoring.

