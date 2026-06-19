import Foundation
import CoreLocation

// MARK: - HERE API Rate Limiting System
// Ensures compliance with HERE API free tier limit of 250,000 platform transactions per month

// MARK: - Data Models
struct HEREUsageData: Codable {
    let month: String           // "2024-01" format
    let totalTransactions: Int  // Total API calls this month
    let lastResetDate: Date     // When monthly limit was reset
    let dailyUsage: [String: Int] // Daily breakdown
    let hourlyUsage: [String: Int] // Hourly breakdown (last 24h)

    init(month: String, totalTransactions: Int, lastResetDate: Date, dailyUsage: [String: Int], hourlyUsage: [String: Int]) {
        self.month = month
        self.totalTransactions = totalTransactions
        self.lastResetDate = lastResetDate
        self.dailyUsage = dailyUsage
        self.hourlyUsage = hourlyUsage
    }
}

enum HEREAPIType: String, CaseIterable {
    case routeMatching = "route_matching"
    case geocoding = "geocoding"
}

enum HERERateLimitStatus {
    case allowed
    case dailyLimitReached
    case hourlyLimitReached
    case monthlyLimitReached
    case approachingLimit(percentage: Double)
}

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

// MARK: - HERE Rate Limiter
class HERERateLimiter: ObservableObject {
    static let shared = HERERateLimiter()

    // Rate limiting configuration
    private let monthlyLimit = 225000      // 90% of 250k for safety
    private let dailyLimit = 7500          // 90% of daily budget (8,333 * 0.9)
    private let hourlyLimit = 312          // 90% of hourly budget (347 * 0.9)

    // Alert thresholds
    private let criticalThreshold = 0.95   // 95% - disable HERE API
    private let warningThreshold = 0.90    // 90% - reduce usage
    private let infoThreshold = 0.75       // 75% - monitor closely

    // Post-cap drip configuration to avoid all-day lockout when daily cap is hit
    private let postCapDripEnabled = true
    private let postCapDripInterval: TimeInterval = 600 // allow one HERE call every 10 minutes
    private let postCapMonthlySafetyThreshold = 0.90 // only allow drip if monthly usage < 90%
    private var lastPostCapDripTime: Date = Date.distantPast

    // Storage configuration
    private let storageKey = "HERE_API_USAGE_DATA"
    private let cleanupInterval: TimeInterval = 3600 // 1 hour

    // Usage data
    @Published private(set) var usageData: HEREUsageData
    private var lastCleanupTime: Date = Date()

    // Date formatters
    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-HH"
        return formatter
    }()

    private init() {
        // Load existing usage data or create new
        self.usageData = Self.loadUsageData()

        // Check for monthly reset
        checkMonthlyReset()

        // Perform initial cleanup
        cleanupOldData()

        Logger.log("HERE Rate Limiter initialized. Current usage: \(usageData.totalTransactions)/\(monthlyLimit)", level: .info)
    }

    // MARK: - Public Interface

    /// Check if HERE API calls are allowed based on current usage
    func checkRateLimit() -> HERERateLimitStatus {
        let currentUsage = getCurrentUsage()

        // Check monthly limit
        if currentUsage.totalTransactions >= monthlyLimit {
            Logger.log("HERE API monthly limit reached: \(currentUsage.totalTransactions)/\(monthlyLimit)", level: .warning)
            return .monthlyLimitReached
        }

        // Check daily limit
        let todayUsage = getTodayUsage()
        if todayUsage >= dailyLimit {
            // Allow a limited "drip" request after the daily cap to prevent an all-day lockout,
            // but only if monthly usage is still within the safety threshold and we've waited long enough.
            let monthlyUsageRatio = Double(currentUsage.totalTransactions) / Double(monthlyLimit)
            let timeSinceLastDrip = Date().timeIntervalSince(lastPostCapDripTime)

            if postCapDripEnabled && monthlyUsageRatio < postCapMonthlySafetyThreshold && timeSinceLastDrip >= postCapDripInterval {
                lastPostCapDripTime = Date()
                Logger.log("HERE API daily limit reached, allowing limited drip request (every \(Int(postCapDripInterval))s) to avoid all-day lockout", level: .warning)
                return .allowed
            }

            Logger.log("HERE API daily limit reached: \(todayUsage)/\(dailyLimit)", level: .warning)
            return .dailyLimitReached
        }

        // Check hourly limit
        let currentHourUsage = getCurrentHourUsage()
        if currentHourUsage >= hourlyLimit {
            Logger.log("HERE API hourly limit reached: \(currentHourUsage)/\(hourlyLimit)", level: .warning)
            return .hourlyLimitReached
        }

        // Check if approaching limits
        let monthlyPercentage = Double(currentUsage.totalTransactions) / Double(monthlyLimit)
        if monthlyPercentage >= infoThreshold {
            Logger.log("HERE API usage at \(Int(monthlyPercentage * 100))% of monthly limit", level: .info)
            return .approachingLimit(percentage: monthlyPercentage)
        }

        return .allowed
    }

    /// Record an API call and update usage statistics
    func recordAPICall(apiType: HEREAPIType) {
        let now = Date()

        // Update monthly usage
        usageData = HEREUsageData(
            month: usageData.month,
            totalTransactions: usageData.totalTransactions + 1,
            lastResetDate: usageData.lastResetDate,
            dailyUsage: usageData.dailyUsage,
            hourlyUsage: usageData.hourlyUsage
        )

        // Update daily usage
        let todayKey = dayFormatter.string(from: now)
        var updatedDailyUsage = usageData.dailyUsage
        updatedDailyUsage[todayKey, default: 0] += 1

        // Update hourly usage
        let hourKey = hourFormatter.string(from: now)
        var updatedHourlyUsage = usageData.hourlyUsage
        updatedHourlyUsage[hourKey, default: 0] += 1

        // Update usage data
        usageData = HEREUsageData(
            month: usageData.month,
            totalTransactions: usageData.totalTransactions,
            lastResetDate: usageData.lastResetDate,
            dailyUsage: updatedDailyUsage,
            hourlyUsage: updatedHourlyUsage
        )

        // Save to persistent storage
        saveUsageData()

        // Check for alerts
        checkUsageAlerts()

        // Clean up old data periodically
        if now.timeIntervalSince(lastCleanupTime) > cleanupInterval {
            cleanupOldData()
            lastCleanupTime = now
        }

        Logger.log("HERE API call recorded (\(apiType.rawValue)). Total: \(usageData.totalTransactions)/\(monthlyLimit)", level: .debug)
    }

    /// Get current usage statistics
    func getUsageStats() -> HEREUsageStats {
        let current = getCurrentUsage()
        let today = getTodayUsage()
        let currentHour = getCurrentHourUsage()

        let calendar = Calendar.current
        let daysInMonth = calendar.range(of: .day, in: .month, for: Date())?.count ?? 30
        let daysPassed = calendar.component(.day, from: Date())
        let averageDaily = daysPassed > 0 ? Double(current.totalTransactions) / Double(daysPassed) : 0.0
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

    /// Get current usage data
    var currentUsage: HEREUsageData {
        return getCurrentUsage()
    }

    /// Get today's usage count
    var todayUsage: Int {
        return getTodayUsage()
    }

    /// Get current hour's usage count
    var currentHourUsage: Int {
        return getCurrentHourUsage()
    }

    /// Get next reset date
    var nextResetDate: Date {
        return getNextResetDate()
    }

    /// Log current usage statistics
    func logUsageStats() {
        let stats = getUsageStats()

        Logger.log("=== HERE API Usage Statistics ===", level: .info)
        Logger.log("Monthly: \(stats.monthlyUsage)/\(monthlyLimit) (\(Int(stats.usagePercentage * 100))%)", level: .info)
        Logger.log("Daily: \(stats.dailyUsage)/\(dailyLimit)", level: .info)
        Logger.log("Hourly: \(stats.hourlyUsage)/\(hourlyLimit)", level: .info)
        Logger.log("Projected Monthly: \(stats.projectedMonthlyUsage)", level: .info)
        Logger.log("Next Reset: \(stats.nextResetDate)", level: .info)
        Logger.log("================================", level: .info)
    }

    // MARK: - Private Methods

    private func getCurrentUsage() -> HEREUsageData {
        return usageData
    }

    private func getTodayUsage() -> Int {
        let todayKey = dayFormatter.string(from: Date())
        return usageData.dailyUsage[todayKey] ?? 0
    }

    private func getCurrentHourUsage() -> Int {
        let hourKey = hourFormatter.string(from: Date())
        return usageData.hourlyUsage[hourKey] ?? 0
    }

    private func getNextResetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()

        // Get first day of next month
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: now) ?? now
        let components = calendar.dateComponents([.year, .month], from: nextMonth)
        return calendar.date(from: components) ?? now
    }

    private func checkMonthlyReset() {
        let calendar = Calendar.current
        let now = Date()

        // Check if we're in a new month
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)
        let storedMonth = calendar.component(.month, from: usageData.lastResetDate)
        let storedYear = calendar.component(.year, from: usageData.lastResetDate)

        if currentMonth != storedMonth || currentYear != storedYear {
            // Reset monthly usage
            let newMonth = monthFormatter.string(from: now)
            usageData = HEREUsageData(
                month: newMonth,
                totalTransactions: 0,
                lastResetDate: now,
                dailyUsage: [:],
                hourlyUsage: [:]
            )

            saveUsageData()
            Logger.log("HERE API usage reset for new month: \(newMonth)", level: .info)
        }
    }

    private func checkUsageAlerts() {
        let percentage = Double(usageData.totalTransactions) / Double(monthlyLimit)

        switch percentage {
        case criticalThreshold...1.0:
            Logger.log("🚨 CRITICAL: HERE API usage at \(Int(percentage * 100))% of monthly limit! Disabling HERE API calls.", level: .error)

        case warningThreshold..<criticalThreshold:
            Logger.log("⚠️ WARNING: HERE API usage at \(Int(percentage * 100))% of monthly limit. Consider reducing usage.", level: .warning)

        case infoThreshold..<warningThreshold:
            Logger.log("📊 INFO: HERE API usage at \(Int(percentage * 100))% of monthly limit. Monitor usage closely.", level: .info)

        default:
            break
        }
    }

    private func cleanupOldData() {
        let now = Date()
        let calendar = Calendar.current

        // Clean up hourly data older than 24 hours
        var updatedHourlyUsage = usageData.hourlyUsage
        let cutoffTime = now.addingTimeInterval(-24 * 3600) // 24 hours ago

        for (key, _) in updatedHourlyUsage {
            // Parse the hour key (MM-dd-HH format)
            let components = key.split(separator: "-")
            if components.count == 3,
               let month = Int(components[0]),
               let day = Int(components[1]),
               let hour = Int(components[2]) {

                var dateComponents = DateComponents()
                dateComponents.year = calendar.component(.year, from: now)
                dateComponents.month = month
                dateComponents.day = day
                dateComponents.hour = hour

                if let date = calendar.date(from: dateComponents), date < cutoffTime {
                    updatedHourlyUsage.removeValue(forKey: key)
                }
            }
        }

        // Clean up daily data older than 30 days
        var updatedDailyUsage = usageData.dailyUsage
        let dailyCutoffTime = now.addingTimeInterval(-30 * 24 * 3600) // 30 days ago

        for (key, _) in updatedDailyUsage {
            // Parse the day key (MM-dd format)
            let components = key.split(separator: "-")
            if components.count == 2,
               let month = Int(components[0]),
               let day = Int(components[1]) {

                var dateComponents = DateComponents()
                dateComponents.year = calendar.component(.year, from: now)
                dateComponents.month = month
                dateComponents.day = day

                if let date = calendar.date(from: dateComponents), date < dailyCutoffTime {
                    updatedDailyUsage.removeValue(forKey: key)
                }
            }
        }

        // Update usage data if cleanup occurred
        if updatedHourlyUsage.count != usageData.hourlyUsage.count ||
           updatedDailyUsage.count != usageData.dailyUsage.count {
            usageData = HEREUsageData(
                month: usageData.month,
                totalTransactions: usageData.totalTransactions,
                lastResetDate: usageData.lastResetDate,
                dailyUsage: updatedDailyUsage,
                hourlyUsage: updatedHourlyUsage
            )
            saveUsageData()
        }
    }

    // MARK: - Persistent Storage

    private func saveUsageData() {
        do {
            let data = try JSONEncoder().encode(usageData)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            Logger.log("Failed to save HERE usage data: \(error.localizedDescription)", level: .error)
        }
    }

    private static func loadUsageData() -> HEREUsageData {
        guard let data = UserDefaults.standard.data(forKey: "HERE_API_USAGE_DATA") else {
            // Create new usage data for current month
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            let month = formatter.string(from: now)

            return HEREUsageData(
                month: month,
                totalTransactions: 0,
                lastResetDate: now,
                dailyUsage: [:],
                hourlyUsage: [:]
            )
        }

        do {
            return try JSONDecoder().decode(HEREUsageData.self, from: data)
        } catch {
            Logger.log("Failed to load HERE usage data: \(error.localizedDescription)", level: .error)

            // Create new usage data if loading fails
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            let month = formatter.string(from: now)

            return HEREUsageData(
                month: month,
                totalTransactions: 0,
                lastResetDate: now,
                dailyUsage: [:],
                hourlyUsage: [:]
            )
        }
    }
}

// MARK: - Extensions

extension HERERateLimiter {
    /// Check if HERE API should be used based on current rate limits
    var shouldUseHEREAPI: Bool {
        switch checkRateLimit() {
        case .allowed, .approachingLimit:
            return true
        case .dailyLimitReached, .hourlyLimitReached, .monthlyLimitReached:
            return false
        }
    }

    /// Get a user-friendly status message
    var statusMessage: String {
        switch checkRateLimit() {
        case .allowed:
            return "HERE API available"
        case .approachingLimit(let percentage):
            return "HERE API usage at \(Int(percentage * 100))%"
        case .dailyLimitReached:
            return "Daily limit reached - using fallback"
        case .hourlyLimitReached:
            return "Hourly limit reached - using fallback"
        case .monthlyLimitReached:
            return "Monthly limit reached - using fallback"
        }
    }
}
