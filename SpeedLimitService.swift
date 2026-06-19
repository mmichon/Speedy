import Foundation
import CoreLocation
import Combine
import SpeedyShared

// MARK: - Logging
enum LogLevel: String {
    case debug = "[DEBUG]"
    case info = "[INFO]"
    case warning = "[WARN]"
    case error = "[ERROR]"
}

// MARK: - Conditional Logging System
struct Logger {
    // Minimum level to output. Change to .warning to show only warnings and errors.
    static var minimumLogLevel: LogLevel = .warning

    static var isLoggingEnabled: Bool {
        // Check if running in Xcode by looking for debugger attachment
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func log(_ message: String, level: LogLevel = .info, category: String = "SpeedLimitService") {
        guard isLoggingEnabled else { return }

        // Filter by minimum log level
        guard levelPriority(level) >= levelPriority(minimumLogLevel) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("\(timestamp) \(level.rawValue) \(category): \(message)")
    }

    private static func levelPriority(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 10
        case .info: return 20
        case .warning: return 30
        case .error: return 40
        }
    }
}

// MARK: - Cache Models
class CachedAPIData: Codable {
    let data: Data
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let cacheKey: String
    let expiresAt: Date

    var coordinate: CLLocationCoordinate2D {
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isExpired: Bool {
        return Date() > expiresAt
    }

    init(data: Data, timestamp: Date, coordinate: CLLocationCoordinate2D, cacheKey: String, expiresAt: Date) {
        self.data = data
        self.timestamp = timestamp
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.cacheKey = cacheKey
        self.expiresAt = expiresAt
    }
}

struct CacheKey: Hashable, Codable {
    let latitude: Double
    let longitude: Double
    let radius: Int
    let apiType: APIType

    enum APIType: String, Codable, CaseIterable {
        case nominatim = "nominatim"
        case overpass = "overpass"
        case here = "here"
        case hereRouteMatching = "here_route"
        case hereGeocoding = "here_geocoding"
    }

    var stringValue: String {
        return "\(apiType.rawValue)_\(latitude)_\(longitude)_\(radius)"
    }
}

// MARK: - Cache Manager
class APICacheManager: ObservableObject {
    static let shared = APICacheManager()

    private let memoryCache = NSCache<NSString, CachedAPIData>()
    private let diskCacheURL: URL
    private let maxMemoryCacheSize = 100 // Maximum number of items in memory
    private let maxDiskCacheSize = 50 * 1024 * 1024 // 50 MB disk cache
    private let cacheExpirationTime: TimeInterval = 3600 // 1 hour default

    private init() {
        // Set up disk cache directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        diskCacheURL = documentsPath.appendingPathComponent("APICache")

        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Configure memory cache
        memoryCache.countLimit = maxMemoryCacheSize
        memoryCache.totalCostLimit = maxMemoryCacheSize * 1024 * 1024 // 100 MB

        // Defer cache operations to background to avoid blocking app startup
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.loadCacheMetadata()
            self?.cleanupExpiredCache()
        }
    }

    // MARK: - Cache Operations
    func cacheData(_ data: Data, for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, radius: Int = 50, expirationTime: TimeInterval? = nil) {
        let cacheKey = CacheKey(latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius, apiType: apiType)
        let expiration = expirationTime ?? cacheExpirationTime
        let expiresAt = Date().addingTimeInterval(expiration)

        let cachedData = CachedAPIData(
            data: data,
            timestamp: Date(),
            coordinate: coordinate,
            cacheKey: cacheKey.stringValue,
            expiresAt: expiresAt
        )

        // Store in memory cache
        memoryCache.setObject(cachedData, forKey: cacheKey.stringValue as NSString)

        // Store on disk
        saveToDisk(cachedData, for: cacheKey)

        log("Cached \(apiType.rawValue) data for coordinate (\(coordinate.latitude), \(coordinate.longitude))", level: .debug)
    }

    func getCachedData(for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, radius: Int = 50) -> Data? {
        let cacheKey = CacheKey(latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius, apiType: apiType)

        // Check memory cache first
        if let cachedData = memoryCache.object(forKey: cacheKey.stringValue as NSString) {
            if !cachedData.isExpired {
                log("Found \(apiType.rawValue) data in memory cache", level: .debug)
                return cachedData.data
            } else {
                // Remove expired data from memory
                memoryCache.removeObject(forKey: cacheKey.stringValue as NSString)
            }
        }

        // Check disk cache
        if let cachedData = loadFromDisk(for: cacheKey) {
            if !cachedData.isExpired {
                // Load into memory cache
                memoryCache.setObject(cachedData, forKey: cacheKey.stringValue as NSString)
                log("Found \(apiType.rawValue) data in memory cache", level: .debug)
                return cachedData.data
            } else {
                // Remove expired data from disk
                removeFromDisk(for: cacheKey)
            }
        }

        log("No cached data found for \(apiType.rawValue)", level: .debug)
        return nil
    }

        func getNearbyCachedData(for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, maxDistance: Double = 100) -> Data? {
        // Search for cached data within maxDistance meters
        let cacheKeys = getAllCacheKeys(for: apiType)

        for cacheKey in cacheKeys {
            let cachedCoordinate = CLLocationCoordinate2D(latitude: cacheKey.latitude, longitude: cacheKey.longitude)
            let distance = calculateDistance(from: coordinate, to: cachedCoordinate)

            if distance <= maxDistance {
                if let cachedData = getCachedData(for: cachedCoordinate, apiType: apiType, radius: cacheKey.radius) {
                    log("Found nearby cached \(apiType.rawValue) data within \(Int(distance))m", level: .debug)
                    return cachedData
                }
            }
        }

        return nil
    }

    // MARK: - Helper Methods
    private func calculateDistance(from coordinate1: CLLocationCoordinate2D, to coordinate2: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: coordinate1.latitude, longitude: coordinate1.longitude)
        let location2 = CLLocation(latitude: coordinate2.latitude, longitude: coordinate2.longitude)
        return location1.distance(from: location2)
    }

    func clearCache() {
        memoryCache.removeAllObjects()

        // Clear disk cache
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        log("Cache cleared", level: .info)
    }

    func clearExpiredCache() {
        cleanupExpiredCache()
    }

    // MARK: - Private Methods
    private func saveToDisk(_ cachedData: CachedAPIData, for cacheKey: CacheKey) {
        let fileURL = diskCacheURL.appendingPathComponent("\(cacheKey.stringValue).cache")

        do {
            let data = try JSONEncoder().encode(cachedData)
            try data.write(to: fileURL)
        } catch {
            log("Failed to save cache to disk: \(error.localizedDescription)", level: .error)
        }
    }

    private func loadFromDisk(for cacheKey: CacheKey) -> CachedAPIData? {
        let fileURL = diskCacheURL.appendingPathComponent("\(cacheKey.stringValue).cache")

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(CachedAPIData.self, from: data)
        } catch {
            return nil
        }
    }

    private func removeFromDisk(for cacheKey: CacheKey) {
        let fileURL = diskCacheURL.appendingPathComponent("\(cacheKey.stringValue).cache")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func getAllCacheKeys(for apiType: CacheKey.APIType) -> [CacheKey] {
        let fileManager = FileManager.default
        let cacheFiles = try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)

        var cacheKeys: [CacheKey] = []

        for fileURL in cacheFiles ?? [] {
            if fileURL.lastPathComponent.hasSuffix(".cache") {
                let fileName = fileURL.lastPathComponent.replacingOccurrences(of: ".cache", with: "")
                let components = fileName.components(separatedBy: "_")

                if components.count >= 4 && components[0] == apiType.rawValue {
                    if let lat = Double(components[1]),
                       let lon = Double(components[2]),
                       let radius = Int(components[3]) {
                        let cacheKey = CacheKey(latitude: lat, longitude: lon, radius: radius, apiType: apiType)
                        cacheKeys.append(cacheKey)
                    }
                }
            }
        }

        return cacheKeys
    }

    private func cleanupExpiredCache() {
        let fileManager = FileManager.default
        let cacheFiles = try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)

        var totalSize: Int64 = 0
        var fileSizes: [(URL, Int64)] = []

        for fileURL in cacheFiles ?? [] {
            if fileURL.lastPathComponent.hasSuffix(".cache") {
                let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes?[.size] as? Int64 ?? 0
                totalSize += fileSize
                fileSizes.append((fileURL, fileSize))

                // Check if file is expired
                if let cachedData = loadFromDisk(for: CacheKey(latitude: 0, longitude: 0, radius: 0, apiType: .nominatim)) {
                    if cachedData.isExpired {
                        try? fileManager.removeItem(at: fileURL)
                        log("Removed expired cache file: \(fileURL.lastPathComponent)", level: .debug)
                    }
                }
            }
        }

        // If disk cache is too large, remove oldest files
        if totalSize > maxDiskCacheSize {
            let sortedFiles = fileSizes.sorted { $0.1 > $1.1 } // Sort by size, largest first

            for (fileURL, fileSize) in sortedFiles {
                if totalSize <= maxDiskCacheSize {
                    break
                }

                try? fileManager.removeItem(at: fileURL)
                totalSize -= fileSize
                log("Removed large cache file to free space: \(fileURL.lastPathComponent)", level: .debug)
            }
        }
    }

    private func loadCacheMetadata() {
        // Load cache statistics and metadata
        let cacheFiles = try? FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
        let cacheCount = cacheFiles?.filter { $0.lastPathComponent.hasSuffix(".cache") }.count ?? 0

        log("Cache metadata loaded - \(cacheCount) cached files", level: .debug)
    }

    private func log(_ message: String, level: LogLevel = .info) {
        Logger.log(message, level: level, category: "APICacheManager")
    }
}



class SpeedLimitService: ObservableObject {
    static let shared = SpeedLimitService()

    // MARK: - Published Properties
    @Published var currentSpeedLimit: Int?
    @Published var currentRoadName: String?
    @Published var currentCityName: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// True when the current speed limit is a statutory default (inferred from
    /// road class), not a posted/confirmed value. The UI renders these distinctly.
    @Published var currentSpeedLimitIsInferred: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private let cacheManager = APICacheManager.shared
    private let hereRateLimiter = HERERateLimiter.shared

    private init() {
        // Private initializer for singleton
    }

    // MARK: - Enhanced Rate Limiting & Caching
    private var lastApiCallTime: Date = Date.distantPast
    private let baseApiCallCooldown: TimeInterval = 1.0 // Strict 1 second for OpenStreetMap APIs
    private var currentApiCallCooldown: TimeInterval = 1.0
    // HERE-specific throttling to respect ~312 calls/hour (~1 every 11.5s)
    private var lastHereApiCallTime: Date = Date.distantPast
    private let hereApiMinInterval: TimeInterval = 12.0
    private var lastKnownGoodSpeedLimit: (speed: Int, coordinate: CLLocationCoordinate2D, timestamp: Date)?

    // Quota monitoring
    private var hereApiCallCount: Int = 0
    private var hereApiCallStartTime: Date = Date()
    private let hereApiQuotaLimit: Int = 300 // Conservative limit (312 calls/hour)
    private let hereApiQuotaWindow: TimeInterval = 3600 // 1 hour
    private var rateLimitCount: Int = 0
    private let maxRateLimitCount: Int = 3 // Reduced for stricter rate limiting
    private var rateLimitResetTime: Date = Date.distantPast
    private var lastSuccessfulApiCall: Date = Date.distantPast
    private struct CoordinateCacheEntry {
        let speedLimit: Int
        let roadName: String
        let isInferred: Bool
        let timestamp: Date
    }
    private var coordinateCache: [String: CoordinateCacheEntry] = [:]
    private let cacheExpirationTime: TimeInterval = 300 // 5 minutes for posted values
    private let inferredCacheExpirationTime: TimeInterval = 90 // shorter TTL for inferred values
    /// How long a stale value may remain displayed when a fresh lookup yields
    /// nothing, before we show "unknown" rather than a stale number.
    private let staleDisplayTTL: TimeInterval = 120

    // MARK: - Speed Limit Validation System
    private var lastValidSpeedLimit: (speed: Int, coordinate: CLLocationCoordinate2D, timestamp: Date, confidence: Int)?
    private var speedLimitHistory: [(speed: Int, timestamp: Date)] = []
    private let maxHistorySize = 10
    private let dramaticChangeThreshold = 30 // MPH difference that triggers validation
    private let confidenceThreshold = 3 // Number of consistent readings needed for high confidence
    private let validationTimeWindow: TimeInterval = 300 // 5 minutes to validate dramatic changes
    private var lastValidationRoadName: String? // Track road name for validation purposes

    // MARK: - Rate Limiting Queue
    private var apiCallQueue: [(coordinate: CLLocationCoordinate2D, completion: () -> Void)] = []
    private var isProcessingQueue = false
    private let rateLimitQueue = DispatchQueue(label: "com.speedy.ratelimit", qos: .utility)

    // MARK: - HERE concurrency guard
    private var isHereCallInFlight = false

    // MARK: - OpenStreetMap Results Processing
    private func processOpenStreetMapResults(roadName: String?, speedLimit: Int?, coordinate: CLLocationCoordinate2D, hasError: Bool) {
        log("Processing OpenStreetMap API results", level: .info)

        // Validate speed limit for reasonable values
        if let speed = speedLimit {
            if speed < 15 || speed > 85 {
                log("WARNING: Suspicious speed limit detected: \(speed) MPH. This may be incorrect data.", level: .warning)
            }
        }

        // Apply speed limit validation logic
        let validatedSpeedLimit = validateSpeedLimitChange(newSpeed: speedLimit, coordinate: coordinate)

        // Update the last API call time to implement cooldown
        lastApiCallTime = Date()
        lastSuccessfulApiCall = Date()

        // Cache the successful result
        if let speed = validatedSpeedLimit {
            lastKnownGoodSpeedLimit = (speed: speed, coordinate: coordinate, timestamp: Date())
        }

        // Cache by coordinate
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)
        if let validated = validatedSpeedLimit {
            coordinateCache[cacheKey] = CoordinateCacheEntry(speedLimit: validated, roadName: roadName ?? "Unknown Road", isInferred: false, timestamp: Date())
        }

        // Reset rate limiting on success
        rateLimitCount = 0
        currentApiCallCooldown = baseApiCallCooldown

        DispatchQueue.main.async {
            self.currentSpeedLimit = validatedSpeedLimit
            self.currentRoadName = roadName
            self.isLoading = false
            self.errorMessage = hasError ? "Some data may be incomplete" : nil

            // Update the road name tracking to detect changes
            self.updateRoadName(roadName, for: coordinate)

            // Refresh widgets when speed limit data changes
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    // MARK: - HERE API Results Processing
    private func processHereApiResults(roadName: String?, speedLimit: Int?, coordinate: CLLocationCoordinate2D, hasError: Bool) {
        log("Processing HERE API results", level: .info)

        // Validate speed limit for reasonable values
        if let speed = speedLimit {
            if speed < 15 || speed > 85 {
                log("WARNING: Suspicious speed limit detected: \(speed) MPH. This may be incorrect data.", level: .warning)
            }
        }

        // Apply speed limit validation logic
        let validatedSpeedLimit = validateSpeedLimitChange(newSpeed: speedLimit, coordinate: coordinate)

        // Update the last API call time to implement cooldown
        lastApiCallTime = Date()
        lastSuccessfulApiCall = Date()

        // Cache the successful result
        if let speed = validatedSpeedLimit {
            lastKnownGoodSpeedLimit = (speed: speed, coordinate: coordinate, timestamp: Date())
        }

        // Cache by coordinate
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)
        if let validated = validatedSpeedLimit {
            coordinateCache[cacheKey] = CoordinateCacheEntry(speedLimit: validated, roadName: roadName ?? "Unknown Road", isInferred: false, timestamp: Date())
        }

        // Reset rate limiting on success
        rateLimitCount = 0
        currentApiCallCooldown = baseApiCallCooldown

        DispatchQueue.main.async {
            self.currentSpeedLimit = validatedSpeedLimit
            self.currentRoadName = roadName
            self.isLoading = false
            self.errorMessage = hasError ? "Some data may be incomplete" : nil

            // Update the road name tracking to detect changes
            self.updateRoadName(roadName, for: coordinate)

            // Refresh widgets when speed limit data changes
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
    }

    // MARK: - Speed Limit Validation Methods
    private func validateSpeedLimitChange(newSpeed: Int?, coordinate: CLLocationCoordinate2D) -> Int? {
        guard let newSpeed = newSpeed else {
            // No new reading. Only keep showing the last value briefly — never
            // pin it indefinitely (that was the old "stuck" bug).
            if let last = lastValidSpeedLimit,
               Date().timeIntervalSince(last.timestamp) < staleDisplayTTL {
                log("No new speed limit; retaining last valid value within grace period", level: .warning)
                return last.speed
            }
            log("No new speed limit and last value is stale; clearing", level: .warning)
            return nil
        }

        // Add to history
        addToSpeedLimitHistory(newSpeed)

        // Check if this is a dramatic change
        if let lastValid = lastValidSpeedLimit {
            let speedDifference = abs(newSpeed - lastValid.speed)

            if speedDifference >= dramaticChangeThreshold {
                log("Dramatic speed limit change detected: \(lastValid.speed) → \(newSpeed) MPH (difference: \(speedDifference))", level: .warning)

                // Asymmetric handling: an INCREASE in the limit is the safe direction.
                // A stale-low limit is exactly what produces erroneous overspeed
                // warnings (e.g. moving from a 25 mph street onto a 55 mph road), so
                // raise the limit promptly the moment a higher reading arrives. Low
                // confidence keeps the value correctable if it was spurious. Only
                // DECREASES need the conservative validation below.
                if newSpeed > lastValid.speed {
                    log("Dramatic speed limit change is an increase; accepting promptly to avoid stale-low false warnings", level: .info)
                    updateLastValidSpeedLimit(newSpeed, coordinate: coordinate, confidence: 1)
                    return newSpeed
                }

                // Check if road has changed - if so, allow dramatic changes
                if hasRoadChanged() {
                    log("Road has changed, allowing dramatic speed limit change", level: .info)
                    updateLastValidSpeedLimit(newSpeed, coordinate: coordinate, confidence: 1)
                    return newSpeed
                }

                // Validate the dramatic change only if we're on the same road
                if shouldAcceptDramaticChange(newSpeed: newSpeed, lastValid: lastValid, coordinate: coordinate) {
                    log("Dramatic change validated and accepted", level: .info)
                    updateLastValidSpeedLimit(newSpeed, coordinate: coordinate, confidence: 1)
                    return newSpeed
                } else {
                    log("Dramatic change rejected, maintaining last valid speed limit: \(lastValid.speed) MPH", level: .info)
                    return lastValid.speed
                }
            } else {
                // Normal change, accept it
                log("Normal speed limit change: \(lastValid.speed) → \(newSpeed) MPH", level: .debug)
                updateLastValidSpeedLimit(newSpeed, coordinate: coordinate, confidence: min(lastValid.confidence + 1, 5))
                return newSpeed
            }
        } else {
            // First speed limit reading
            log("First speed limit reading: \(newSpeed) MPH", level: .info)
            updateLastValidSpeedLimit(newSpeed, coordinate: coordinate, confidence: 1)
            return newSpeed
        }
    }

    private func shouldAcceptDramaticChange(newSpeed: Int, lastValid: (speed: Int, coordinate: CLLocationCoordinate2D, timestamp: Date, confidence: Int), coordinate: CLLocationCoordinate2D) -> Bool {
        let timeSinceLastValid = Date().timeIntervalSince(lastValid.timestamp)

        // If the last valid speed limit is old, be more accepting of changes
        if timeSinceLastValid > validationTimeWindow {
            log("Last valid speed limit is old (\(Int(timeSinceLastValid))s), accepting dramatic change", level: .info)
            return true
        }

        // Check if we have recent consistent readings
        let recentReadings = getRecentSpeedLimitReadings(within: validationTimeWindow)
        if recentReadings.count >= confidenceThreshold {
            let averageRecent = recentReadings.map { $0.speed }.reduce(0, +) / recentReadings.count
            let recentVariance = recentReadings.map { abs($0.speed - averageRecent) }.reduce(0, +) / recentReadings.count

            // If recent readings are consistent and the new speed is close to the average, accept it
            if recentVariance < 10 && abs(newSpeed - averageRecent) < 15 {
                log("Recent readings are consistent, accepting dramatic change", level: .info)
                return true
            }
        }

        // Check if the new speed is more reasonable for the road type
        if isSpeedLimitReasonableForLocation(newSpeed, coordinate: coordinate) {
            log("New speed limit appears reasonable for location, accepting dramatic change", level: .info)
            return true
        }

        // High confidence in last valid speed limit makes us more conservative
        if lastValid.confidence >= 4 {
            log("High confidence in last valid speed limit (\(lastValid.confidence)/5), rejecting dramatic change", level: .info)
            return false
        }

        // Default to rejecting dramatic changes unless we have good evidence
        log("Insufficient evidence to accept dramatic change, rejecting", level: .info)
        return false
    }

    private func addToSpeedLimitHistory(_ speed: Int) {
        speedLimitHistory.append((speed: speed, timestamp: Date()))

        // Keep only recent history
        let cutoffTime = Date().addingTimeInterval(-validationTimeWindow)
        speedLimitHistory = speedLimitHistory.filter { $0.timestamp > cutoffTime }

        // Limit history size
        if speedLimitHistory.count > maxHistorySize {
            speedLimitHistory = Array(speedLimitHistory.suffix(maxHistorySize))
        }
    }

    private func getRecentSpeedLimitReadings(within timeWindow: TimeInterval) -> [(speed: Int, timestamp: Date)] {
        let cutoffTime = Date().addingTimeInterval(-timeWindow)
        return speedLimitHistory.filter { $0.timestamp > cutoffTime }
    }

    private func updateLastValidSpeedLimit(_ speed: Int, coordinate: CLLocationCoordinate2D, confidence: Int) {
        lastValidSpeedLimit = (speed: speed, coordinate: coordinate, timestamp: Date(), confidence: confidence)
        log("Updated last valid speed limit: \(speed) MPH (confidence: \(confidence)/5)", level: .debug)
    }

        private func isSpeedLimitReasonableForLocation(_ speed: Int, coordinate: CLLocationCoordinate2D) -> Bool {
        // Basic validation based on speed ranges
        if speed < 15 || speed > 85 {
            return false
        }

        // Check if speed is reasonable for typical road types
        // This is a simplified check - in a real implementation, you might use road type data
        let reasonableSpeeds: [Int] = [25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75]
        return reasonableSpeeds.contains(speed)
    }

    private func hasRoadChanged() -> Bool {
        // Check if the current road name is different from the last validation road name
        if let currentRoadName = currentRoadName, let lastValidationRoad = lastValidationRoadName {
            let hasChanged = currentRoadName != lastValidationRoad
            if hasChanged {
                log("Road change detected: '\(lastValidationRoad)' → '\(currentRoadName)'", level: .info)
            }
            return hasChanged
        }

        // If we don't have a previous road name, assume no change
        return false
    }

    private func log(_ message: String, level: LogLevel = .info) {
        Logger.log(message, level: level, category: "SpeedLimitService")
    }

    // MARK: - Main Speed Limit Lookup
    /// - Parameter course: the user's GPS course/heading in degrees (0–360), if
    ///   known. Used to snap to the road actually being travelled.
    func lookupSpeedLimit(for coordinate: CLLocationCoordinate2D, course: Double? = nil) {
        log("lookupSpeedLimit called with coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .debug)

        // Check coordinate cache first (grid-snapped key so it actually hits
        // along a road instead of missing on every sub-meter GPS jitter).
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)
        if let cached = coordinateCache[cacheKey] {
            let ttl = cached.isInferred ? inferredCacheExpirationTime : cacheExpirationTime
            if Date().timeIntervalSince(cached.timestamp) < ttl {
                log("Using cached data for coordinate (\(cached.isInferred ? "inferred" : "posted"))", level: .info)
                DispatchQueue.main.async {
                    self.currentSpeedLimit = cached.speedLimit
                    self.currentRoadName = cached.roadName
                    self.currentSpeedLimitIsInferred = cached.isInferred
                    self.isLoading = false
                    self.errorMessage = nil
                    SpeedyDataManager.shared.forceWidgetRefresh()
                }
                return
            }
        }

        // Check if we're on cooldown to avoid hitting rate limits
        let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)
        if timeSinceLastCall < currentApiCallCooldown {
            let remainingTime = Int(currentApiCallCooldown - timeSinceLastCall)
            log("API call on cooldown. Enqueueing for rate limiting. \(remainingTime)s remaining", level: .warning)

            // If we have recent cached data, keep showing it while we wait.
            if let cached = lastKnownGoodSpeedLimit,
               Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
                log("Using cached speed limit data while enqueueing API call", level: .info)
                DispatchQueue.main.async {
                    self.currentSpeedLimit = cached.speed
                    self.errorMessage = "Using cached data (API call queued for rate limiting)"
                    SpeedyDataManager.shared.forceWidgetRefresh()
                }
            }

            // Enqueue the API call for later processing
            enqueueApiCall(coordinate: coordinate) {
                self.log("API call processed from queue", level: .debug)
            }
            return
        }

        lastApiCallTime = Date()
        isLoading = true
        errorMessage = nil

        // Fan out to all available providers and reconcile.
        resolveSpeedLimit(coordinate: coordinate, course: course)

        SpeedyDataManager.shared.forceWidgetRefresh()
    }

    func forceLookupSpeedLimit(for coordinate: CLLocationCoordinate2D) {
        log("forceLookupSpeedLimit called with coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .debug)

        // Force lookup bypasses cache but still respects rate limiting
        if checkRateLimit() {
            lastApiCallTime = Date()
            isLoading = true
            errorMessage = nil
            resolveSpeedLimit(coordinate: coordinate, course: nil)
        } else {
            // Enqueue for rate limiting
            log("Force lookup enqueued due to rate limiting", level: .warning)
            enqueueApiCall(coordinate: coordinate) {
                self.log("Force lookup processed from queue", level: .debug)
            }
        }
    }

    // MARK: - Force Refresh and Cache Management
    func forceRefreshSpeedLimit(for coordinate: CLLocationCoordinate2D) {
        log("Force refreshing speed limit - clearing cache and bypassing cooldown", level: .info)

        // Clear all cached data
        lastKnownGoodSpeedLimit = nil
        lastApiCallTime = Date.distantPast
        currentApiCallCooldown = baseApiCallCooldown
        rateLimitCount = 0

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
        coordinateCache.removeAll()
        currentApiCallCooldown = baseApiCallCooldown
        rateLimitCount = 0

        // Clear validation system
        clearSpeedLimitValidation()

        // Clear road name validation history
        roadNameValidationHistory.removeAll()

        DispatchQueue.main.async {
            self.currentSpeedLimit = nil
            self.currentRoadName = nil
            self.errorMessage = "Cache cleared, ready for new lookup"
        }
    }

    func clearSpeedLimitValidation() {
        log("Clearing speed limit validation system", level: .info)
        lastValidSpeedLimit = nil
        speedLimitHistory.removeAll()
        lastValidationRoadName = nil
    }

    // MARK: - Multi-Source Coordinator
    /// Query every available provider in parallel, then pick the best reading.
    /// Posted readings (TomTom / OSM maxspeed / HERE) always beat inferred
    /// statutory defaults; agreement across sources wins ties. Never invents a
    /// number — an unresolved lookup shows "unknown" (after a short grace period).
    private func resolveSpeedLimit(coordinate: CLLocationCoordinate2D, course: Double?) {
        let courseDesc = course.map { String(format: "%.0f°", $0) } ?? "n/a"
        log("Resolving speed limit across providers (course: \(courseDesc))", level: .info)

        let group = DispatchGroup()
        let syncQueue = DispatchQueue(label: "com.speedy.resolve")
        var results: [SpeedLimitResult] = []
        var roadName: String?
        var stateCode: String?

        // --- TomTom (posted, primary) ---
        if tomtomEnabled {
            group.enter()
            fetchTomTomResult(coordinate: coordinate) { result, state, name in
                syncQueue.sync {
                    if let result = result { results.append(result) }
                    if let state = state { stateCode = state }
                    if roadName == nil, let name = name { roadName = name }
                }
                group.leave()
            }
        }

        // --- HERE (posted, cross-check) — gated by HERE rate limits/quota ---
        if hereEnabled, hereCanCall() {
            lastHereApiCallTime = Date()
            group.enter()
            getSpeedLimitAndRoadNameFromHereCached(coordinate: coordinate) { res in
                syncQueue.sync {
                    if case .success(let (name, mph)) = res {
                        if let mph = mph, SpeedLimitBounds.isPlausible(mph) {
                            results.append(SpeedLimitResult(speedLimitMph: mph, roadName: name,
                                                            source: .here, confidence: .posted))
                        }
                        if roadName == nil, let name = name, name != "Unknown Road" { roadName = name }
                    }
                }
                group.leave()
            }
        }

        // --- OpenStreetMap (posted maxspeed + statutory default) ---
        group.enter()
        fetchOverpassResponseCached(coordinate: coordinate) { response in
            syncQueue.sync {
                if let response = response {
                    let (osmName, osmResults) = self.overpassResults(from: response,
                                                                     coordinate: coordinate,
                                                                     course: course,
                                                                     stateCode: stateCode)
                    results.append(contentsOf: osmResults)
                    if roadName == nil, let osmName = osmName { roadName = osmName }
                }
            }
            group.leave()
        }

        group.notify(queue: .main) {
            let resolved = SpeedLimitResolver.reconcile(results)
            self.processResolvedResult(resolved, roadName: roadName, coordinate: coordinate)
        }
    }

    /// True when HERE may be called right now (key present, under quota, past
    /// the per-call throttle, no request already in flight).
    private func hereCanCall() -> Bool {
        if isHereCallInFlight { return false }
        switch hereRateLimiter.checkRateLimit() {
        case .allowed, .approachingLimit:
            if !checkHereApiQuota() { return false }
            return Date().timeIntervalSince(lastHereApiCallTime) >= hereApiMinInterval
        default:
            return false
        }
    }

    /// Publish the reconciled result: validate posted changes, cache with the
    /// grid key + confidence, refresh widgets. A nil result is shown as the last
    /// known value briefly, then as "unknown" — never a fabricated number.
    private func processResolvedResult(_ resolved: SpeedLimitResult?,
                                       roadName: String?,
                                       coordinate: CLLocationCoordinate2D) {
        lastApiCallTime = Date()
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)

        guard let resolved = resolved, let mph = resolved.speedLimitMph else {
            let stale = lastKnownGoodSpeedLimit
            DispatchQueue.main.async {
                if let stale = stale, Date().timeIntervalSince(stale.timestamp) < self.staleDisplayTTL {
                    self.currentSpeedLimit = stale.speed
                    self.errorMessage = "Speed limit unavailable (showing last known)"
                } else {
                    self.currentSpeedLimit = nil
                    self.currentSpeedLimitIsInferred = false
                    self.errorMessage = "Speed limit unavailable"
                }
                if let roadName = roadName { self.currentRoadName = roadName }
                self.isLoading = false
                SpeedyDataManager.shared.forceWidgetRefresh()
            }
            log("No speed limit could be resolved for coordinate", level: .warning)
            return
        }

        let isInferred = resolved.confidence == .inferred
        // Posted values get dramatic-change validation (guards against a single
        // bad blip); inferred values come from the matched road's class so are
        // accepted directly.
        let finalMph = isInferred ? mph : (validateSpeedLimitChange(newSpeed: mph, coordinate: coordinate) ?? mph)
        let name = resolved.roadName ?? roadName

        lastSuccessfulApiCall = Date()
        lastKnownGoodSpeedLimit = (speed: finalMph, coordinate: coordinate, timestamp: Date())
        coordinateCache[cacheKey] = CoordinateCacheEntry(speedLimit: finalMph,
                                                         roadName: name ?? "Unknown Road",
                                                         isInferred: isInferred,
                                                         timestamp: Date())
        rateLimitCount = 0
        currentApiCallCooldown = baseApiCallCooldown

        DispatchQueue.main.async {
            self.currentSpeedLimit = finalMph
            self.currentSpeedLimitIsInferred = isInferred
            if let name = name { self.currentRoadName = name }
            self.isLoading = false
            self.errorMessage = nil
            self.updateRoadName(name, for: coordinate)
            SpeedyDataManager.shared.forceWidgetRefresh()
        }
        log("Resolved \(finalMph) MPH from \(resolved.source.displayName) (\(isInferred ? "inferred" : "posted"))", level: .info)
    }

    // MARK: - TomTom Provider
    private func fetchTomTomResult(coordinate: CLLocationCoordinate2D,
                                   completion: @escaping (SpeedLimitResult?, String?, String?) -> Void) {
        let urlString = "\(tomtomReverseGeocodeUrl)/\(coordinate.latitude),\(coordinate.longitude).json"
        var components = URLComponents(string: urlString)
        components?.queryItems = [
            URLQueryItem(name: "key", value: tomtomApiKey),
            URLQueryItem(name: "returnSpeedLimit", value: "true"),
            URLQueryItem(name: "radius", value: "30")
        ]
        guard let url = components?.url else { completion(nil, nil, nil); return }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: TomTomReverseResponse.self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completionResult in
                if case .failure(let error) = completionResult {
                    self.log("TomTom API error: \(error.localizedDescription)", level: .warning)
                    completion(nil, nil, nil)
                }
            }, receiveValue: { response in
                let address = response.addresses?.first?.address
                let name = address?.streetName ?? address?.freeformAddress
                // countrySubdivisionCode is like "US-CA" → "CA".
                let state: String? = {
                    guard let code = address?.countrySubdivisionCode else { return nil }
                    let parts = code.split(separator: "-")
                    return parts.count == 2 ? String(parts[1]) : (parts.count == 1 ? String(parts[0]) : nil)
                }()
                var result: SpeedLimitResult?
                if let raw = address?.speedLimit, let mph = SpeedLimitParser.parseMaxspeed(raw) {
                    result = SpeedLimitResult(speedLimitMph: mph, roadName: name,
                                              source: .tomtom, confidence: .posted)
                    self.log("TomTom speed limit: \(mph) MPH on '\(name ?? "?")'", level: .info)
                }
                completion(result, state, name)
            })
            .store(in: &cancellables)
    }

    // MARK: - Overpass response fetch (with caching)
    private func fetchOverpassResponseCached(coordinate: CLLocationCoordinate2D,
                                             completion: @escaping (OverpassResponse?) -> Void) {
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .overpass)
            ?? cacheManager.getNearbyCachedData(for: coordinate, apiType: .overpass, maxDistance: 60),
           let response = try? JSONDecoder().decode(OverpassResponse.self, from: cachedData) {
            log("Using cached Overpass response", level: .debug)
            completion(response)
            return
        }

        let query = """
        [out:json][timeout:25];
        way(around:60,\(coordinate.latitude),\(coordinate.longitude))["highway"];
        out tags geom;
        """
        var components = URLComponents(string: overpassBaseUrl)
        components?.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let url = components?.url else { completion(nil); return }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completionResult in
                if case .failure(let error) = completionResult {
                    self.log("Overpass API error: \(error.localizedDescription)", level: .warning)
                    completion(nil)
                }
            }, receiveValue: { data in
                guard let response = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
                    completion(nil)
                    return
                }
                self.cacheManager.cacheData(data, for: coordinate, apiType: .overpass, expirationTime: 1800)
                completion(response)
            })
            .store(in: &cancellables)
    }

    // MARK: - HERE API Implementation (Primary)
    private func lookupWithHereApiCached(coordinate: CLLocationCoordinate2D) {
        log("Starting HERE API speed limit lookup with OpenStreetMap fallback", level: .info)

        // Test basic network connectivity first
        let testUrl = URL(string: "https://routematching.hereapi.com")!
        let testRequest = URLRequest(url: testUrl)

        URLSession.shared.dataTaskPublisher(for: testRequest)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("Network connectivity test failed: \(error.localizedDescription)", level: .error)
                        // Try to use cached data when offline
                        self.useCachedDataIfAvailable(coordinate: coordinate)
                    }
                },
                receiveValue: { _ in
                    self.log("Network connectivity test passed, proceeding with HERE API calls", level: .debug)
                    self.makeHereApiCallsCached(coordinate: coordinate)
                }
            )
            .store(in: &cancellables)
    }

    private func makeHereApiCallsCached(coordinate: CLLocationCoordinate2D) {
        // If a HERE request is already in flight, avoid issuing another and use OSM fallback
        if isHereCallInFlight {
            log("HERE API request already in flight. Using OpenStreetMap fallback", level: .warning)
            makeOpenStreetMapApiCallsCached(coordinate: coordinate)
            return
        }

        // Check HERE API rate limits first
        let rateLimitStatus = hereRateLimiter.checkRateLimit()

        switch rateLimitStatus {
        case .allowed, .approachingLimit:
            // Additional per-request throttle for HERE
            // Check HERE API quota first
            if !checkHereApiQuota() {
                log("HERE API quota exceeded. Using OpenStreetMap fallback", level: .warning)
                makeOpenStreetMapApiCallsCached(coordinate: coordinate)
                return
            }

            let sinceLastHere = Date().timeIntervalSince(lastHereApiCallTime)
            if sinceLastHere < hereApiMinInterval {
                let remaining = Int(hereApiMinInterval - sinceLastHere)
                log("HERE API throttled. Using OpenStreetMap fallback (\(remaining)s until next HERE call)", level: .warning)
                makeOpenStreetMapApiCallsCached(coordinate: coordinate)
                return
            }

            // Proceed with HERE API calls
            makeHereApiCallsWithRateLimit(coordinate: coordinate)

        case .monthlyLimitReached:
            log("HERE API monthly limit reached, using OpenStreetMap fallback", level: .warning)
            makeOpenStreetMapApiCallsCached(coordinate: coordinate)

        case .dailyLimitReached:
            log("HERE API daily limit reached, using OpenStreetMap fallback", level: .warning)
            makeOpenStreetMapApiCallsCached(coordinate: coordinate)

        case .hourlyLimitReached:
            log("HERE API hourly limit reached, using OpenStreetMap fallback", level: .warning)
            makeOpenStreetMapApiCallsCached(coordinate: coordinate)
        }
    }

    private func makeHereApiCallsWithRateLimit(coordinate: CLLocationCoordinate2D) {
        // Prevent parallel HERE calls
        isHereCallInFlight = true
        // Use DispatchGroup to run HERE API calls with OpenStreetMap fallback
        let group = DispatchGroup()
        var roadName: String?
        var speedLimit: Int?
        var hasError = false

        // Primary: Get speed limit and road name from HERE Route Matching API
        group.enter()
        getSpeedLimitAndRoadNameFromHereCached(coordinate: coordinate) { result in
            switch result {
            case .success(let (name, speed)):
                roadName = name
                speedLimit = speed
                self.log("HERE API returned road name: \(name ?? "Unknown") and speed limit: \(speed ?? 25)", level: .info)
            case .failure(let error):
                self.log("HERE API error: \(error.localizedDescription)", level: .warning)
                hasError = true
            }
            group.leave()
        }

        // Always run OpenStreetMap fallback in parallel to fill gaps if HERE returns nothing
        group.enter()
        getRoadNameAndSpeedLimitFromOverpassCached(coordinate: coordinate) { result in
            switch result {
            case .success(let (name, speed)):
                if roadName == nil || roadName == "Unknown Road" {
                    roadName = name
                }
                if speedLimit == nil {
                    speedLimit = speed
                }
                self.log("OpenStreetMap fallback returned road name: \(name ?? "Unknown") and speed limit: \(speed ?? 25)", level: .info)
            case .failure(let error):
                self.log("OpenStreetMap fallback error: \(error.localizedDescription)", level: .warning)
                hasError = true
            }
            group.leave()
        }

        // HERE Geocoding fallback will be decided after primary tasks complete

        // Final fallback: Get road name from Nominatim if still not available
        if roadName == nil || roadName == "Unknown Road" {
            group.enter()
            getRoadNameFromNominatimCached(coordinate: coordinate) { result in
                switch result {
                case .success(let name):
                    if roadName == nil || roadName == "Unknown Road" {
                        roadName = name
                        self.log("Nominatim final fallback returned road name: \(name)", level: .info)
                    }
                case .failure(let error):
                    self.log("Nominatim final fallback error: \(error.localizedDescription)", level: .warning)
                    if roadName == nil {
                        hasError = true
                    }
                }
                group.leave()
            }
        }

        // Process results when all primary calls complete, optionally perform HERE Geocoding if still needed
        group.notify(queue: .main) {
            if roadName == nil || roadName == "Unknown Road" {
                let status = self.hereRateLimiter.checkRateLimit()
                switch status {
                case .allowed, .approachingLimit:
                    // Enforce HERE-specific throttle for geocoding fallback as well
                    let sinceLastHere = Date().timeIntervalSince(self.lastHereApiCallTime)
                    if sinceLastHere < self.hereApiMinInterval {
                        let remaining = Int(self.hereApiMinInterval - sinceLastHere)
                        self.log("Skipping HERE Geocoding due to throttle (\(remaining)s remaining). Relying on OpenStreetMap results", level: .warning)
                        self.processHereApiResults(
                            roadName: roadName,
                            speedLimit: speedLimit,
                            coordinate: coordinate,
                            hasError: hasError
                        )
                        self.isHereCallInFlight = false
                        return
                    }

                    self.getRoadNameFromHereGeocodingCached(coordinate: coordinate) { result in
                        switch result {
                        case .success(let name):
                            if roadName == nil || roadName == "Unknown Road" {
                                roadName = name
                                self.log("HERE Geocoding fallback returned road name: \(name)", level: .info)
                            }
                        case .failure(let error):
                            self.log("HERE Geocoding fallback error: \(error.localizedDescription)", level: .warning)
                        }
                        self.processHereApiResults(
                            roadName: roadName,
                            speedLimit: speedLimit,
                            coordinate: coordinate,
                            hasError: hasError
                        )
                        self.isHereCallInFlight = false
                    }
                    return
                default:
                    self.log("Skipping HERE Geocoding due to rate limit status", level: .warning)
                }
            }
            self.processHereApiResults(
                roadName: roadName,
                speedLimit: speedLimit,
                coordinate: coordinate,
                hasError: hasError
            )
            self.isHereCallInFlight = false
        }
    }

    // MARK: - OpenStreetMap API Implementation (Fallback)
    private func lookupWithOpenStreetMapCached(coordinate: CLLocationCoordinate2D) {
        log("Starting OpenStreetMap API speed limit lookup with caching", level: .info)

        // Test basic network connectivity first
        let testUrl = URL(string: "https://www.openstreetmap.org")!
        let testRequest = URLRequest(url: testUrl)

        URLSession.shared.dataTaskPublisher(for: testRequest)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("Network connectivity test failed: \(error.localizedDescription)", level: .error)
                        // Try to use cached data when offline
                        self.useCachedDataIfAvailable(coordinate: coordinate)
                    }
                },
                receiveValue: { _ in
                    self.log("Network connectivity test passed, proceeding with cached API calls", level: .debug)
                    self.makeOpenStreetMapApiCallsCached(coordinate: coordinate)
                }
            )
            .store(in: &cancellables)
    }

    private func makeOpenStreetMapApiCallsCached(coordinate: CLLocationCoordinate2D) {
        // Use DispatchGroup to run both API calls in parallel
        let group = DispatchGroup()
        var roadName: String?
        var speedLimit: Int?
        var hasError = false

        // Get road name and speed limit from Overpass (with caching) - this gives us the actual road segment
        group.enter()
        getRoadNameAndSpeedLimitFromOverpassCached(coordinate: coordinate) { result in
            switch result {
            case .success(let (name, speed)):
                roadName = name
                speedLimit = speed
                self.log("Overpass returned road name: \(name ?? "Unknown") and speed limit: \(speed ?? 25)", level: .info)
            case .failure(let error):
                self.log("Overpass error: \(error.localizedDescription)", level: .warning)
                hasError = true
            }
            group.leave()
        }

        // Fallback: Get road name from Nominatim if Overpass didn't return a road name (with caching)
        group.enter()
        getRoadNameFromNominatimCached(coordinate: coordinate) { result in
            switch result {
            case .success(let name):
                // Only use Nominatim result if we don't already have a road name from Overpass
                if roadName == nil || roadName == "Unknown Road" {
                    roadName = name
                    self.log("Nominatim fallback returned road name: \(name)", level: .info)
                }
            case .failure(let error):
                self.log("Nominatim fallback error: \(error.localizedDescription)", level: .warning)
                if roadName == nil {
                    hasError = true
                }
            }
            group.leave()
        }

        // Process results when both calls complete
        group.notify(queue: .main) {
            self.processOpenStreetMapResults(
                roadName: roadName,
                speedLimit: speedLimit,
                coordinate: coordinate,
                hasError: hasError
            )
        }
    }

    // MARK: - API Keys (loaded from Info.plist, not hardcoded)
    /// Reads an API key from the app's Info.plist. Returns "" when missing/blank.
    private static func infoPlistKey(_ name: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: name) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private let hereApiKey = SpeedLimitService.infoPlistKey("HereApiKey")
    private let tomtomApiKey = SpeedLimitService.infoPlistKey("TomTomApiKey")
    private var hereEnabled: Bool { !hereApiKey.isEmpty }
    private var tomtomEnabled: Bool { !tomtomApiKey.isEmpty }

    // MARK: - HERE API Configuration
    private let hereRouteMatchingUrl = "https://routematching.hereapi.com/v8/match/routelinks"
    private let hereGeocodingUrl = "https://geocode.search.hereapi.com/v1/geocode"

    // MARK: - TomTom API Configuration
    // Reverse-geocode endpoint returns the road's posted `speedLimit` (free tier:
    // 2,500 non-tile requests/day, no credit card). Provider is skipped when no key.
    private let tomtomReverseGeocodeUrl = "https://api.tomtom.com/search/2/reverseGeocode"

    // MARK: - OpenStreetMap API Configuration
    private let nominatimBaseUrl = "https://nominatim.openstreetmap.org"
    private let overpassBaseUrl = "https://overpass-api.de/api/interpreter"

    // User agent for OpenStreetMap APIs (required for production use)
    private let userAgent = "SpeedyApp/1.0 (https://github.com/yourusername/speedy; your@email.com)"

    // MARK: - OpenStreetMap API Methods
    private func getRoadNameFromNominatimCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<String, Error>) -> Void) {
        log("Getting road name from Nominatim (with caching)", level: .info)

        // Check cache first
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .nominatim) {
            log("Using cached Nominatim data", level: .debug)
            if let roadName = processCachedNominatimData(cachedData) {
                completion(.success(roadName))
                return
            }
        }

        // Check for nearby cached data
        if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .nominatim, maxDistance: 100) {
            log("Using nearby cached Nominatim data", level: .debug)
            if let roadName = processCachedNominatimData(nearbyCachedData) {
                completion(.success(roadName))
                return
            }
        }

        // Make API call if no cached data available
        getRoadNameFromNominatim(coordinate: coordinate) { result in
            switch result {
            case .success(let roadName):
                completion(.success(roadName))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getRoadNameAndSpeedLimitFromOverpassCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<(String?, Int?), Error>) -> Void) {
        log("Getting road name and speed limit from Overpass (with caching)", level: .info)

        // Check cache first
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .overpass) {
            log("Using cached Overpass data", level: .debug)
            if let (roadName, speedLimit) = processCachedOverpassDataForRoadAndSpeed(cachedData) {
                completion(.success((roadName, speedLimit)))
                return
            }
        }

        // Check for nearby cached data
        if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .overpass, maxDistance: 100) {
            log("Using nearby cached Overpass data", level: .debug)
            if let (roadName, speedLimit) = processCachedOverpassDataForRoadAndSpeed(nearbyCachedData) {
                completion(.success((roadName, speedLimit)))
                return
            }
        }

        // Make API call if no cached data available
        getRoadNameAndSpeedLimitFromOverpass(coordinate: coordinate) { result in
            switch result {
            case .success(let (roadName, speedLimit)):
                completion(.success((roadName, speedLimit)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getSpeedLimitFromOverpassCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<Int, Error>) -> Void) {
        log("Getting speed limit from Overpass (with caching)", level: .info)

        // Check cache first
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .overpass) {
            log("Using cached Overpass data", level: .debug)
            if let speedLimit = processCachedOverpassData(cachedData) {
                completion(.success(speedLimit))
                return
            }
        }

        // Check for nearby cached data
        if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .overpass, maxDistance: 100) {
            log("Using nearby cached Overpass data", level: .debug)
            if let speedLimit = processCachedOverpassData(nearbyCachedData) {
                completion(.success(speedLimit))
                return
            }
        }

        // Make API call if no cached data available
        getSpeedLimitFromOverpass(coordinate: coordinate) { result in
            switch result {
            case .success(let speedLimit):
                completion(.success(speedLimit))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func useCachedDataIfAvailable(coordinate: CLLocationCoordinate2D) {
        log("Attempting to use cached data for offline operation", level: .info)

        // Try to get cached HERE API data first (preferred)
        if let cachedHereData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .hereRouteMatching, maxDistance: 200) {
            if let (roadName, speedLimit) = processCachedHereData(cachedHereData) {
                DispatchQueue.main.async {
                    self.currentSpeedLimit = speedLimit
                    self.currentRoadName = roadName
                    self.isLoading = false
                    self.errorMessage = "Using cached HERE data (offline mode)"
                }
                return
            }
        }

        // Fallback to OpenStreetMap cached data
        if let cachedSpeedLimitData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .overpass, maxDistance: 200),
           let cachedRoadNameData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .nominatim, maxDistance: 200) {

            // Process cached speed limit data
            if let speedLimit = processCachedOverpassData(cachedSpeedLimitData) {
                self.currentSpeedLimit = speedLimit
            }

            // Process cached road name data
            if let roadName = processCachedNominatimData(cachedRoadNameData) {
                self.currentRoadName = roadName
            }

            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Using cached OpenStreetMap data (offline mode)"
            }
        } else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "No cached data available (offline mode)"
            }
        }
    }

    // MARK: - Original OpenStreetMap API Methods
    private func getRoadNameFromNominatim(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<String, Error>) -> Void) {
        log("Making Nominatim API call", level: .info)

        var components = URLComponents(string: "\(nominatimBaseUrl)/reverse")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "extratags", value: "1")
        ]

        guard let url = components?.url else {
            completion(.failure(NSError(domain: "SpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Nominatim URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> NominatimResponse in
                if let jsonString = String(data: data, encoding: .utf8) {
                    self.log("Raw Nominatim API JSON response: \(jsonString)", level: .debug)
                }

                let decoder = JSONDecoder()
                return try decoder.decode(NominatimResponse.self, from: data)
            }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("Nominatim API error: \(error.localizedDescription)", level: .error)
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] response in
                    if let roadName = response.address?.road {
                        // Cache the successful response
                        if let encodedData = try? JSONEncoder().encode(response) {
                            self?.cacheManager.cacheData(
                                encodedData,
                                for: coordinate,
                                apiType: .nominatim,
                                expirationTime: 7200 // 2 hours for road names
                            )
                        }
                        completion(.success(roadName))
                    } else {
                        // Fallback to other address components
                        let fallbackName = response.address?.suburb ?? response.address?.city ?? "Unknown Road"
                        completion(.success(fallbackName))
                    }
                }
            )
            .store(in: &cancellables)
    }

    private func getRoadNameAndSpeedLimitFromOverpass(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<(String?, Int?), Error>) -> Void) {
        log("Making Overpass API call for road name and speed limit", level: .info)

        // Fetch all nearby drivable ways WITH geometry so we can snap to the road
        // the user is actually on (by GPS course), then read maxspeed or infer a
        // statutory default. `out tags geom;` returns tags + the way's coordinates.
        let query = """
        [out:json][timeout:25];
        way(around:60,\(coordinate.latitude),\(coordinate.longitude))["highway"];
        out tags geom;
        """

        var components = URLComponents(string: overpassBaseUrl)
        components?.queryItems = [
            URLQueryItem(name: "data", value: query)
        ]

        guard let url = components?.url else {
            completion(.failure(NSError(domain: "SpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Overpass URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> OverpassResponse in
                if let jsonString = String(data: data, encoding: .utf8) {
                    self.log("Raw Overpass API JSON response: \(jsonString)", level: .debug)
                }

                let decoder = JSONDecoder()
                return try decoder.decode(OverpassResponse.self, from: data)
            }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("Overpass API error: \(error.localizedDescription)", level: .error)
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] response in
                    let (roadName, speedLimit) = self?.extractRoadNameAndSpeedLimitFromOverpassResponse(response, coordinate: coordinate) ?? (nil, 25)

                    // Cache the successful response
                    if let encodedData = try? JSONEncoder().encode(response) {
                        self?.cacheManager.cacheData(
                            encodedData,
                            for: coordinate,
                            apiType: .overpass,
                            expirationTime: 1800 // 30 minutes for road data
                        )
                    }

                    completion(.success((roadName, speedLimit)))
                }
            )
            .store(in: &cancellables)
    }

    private func getSpeedLimitFromOverpass(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<Int, Error>) -> Void) {
        log("Making Overpass API call", level: .info)

        // Overpass query to find speed limits near the coordinate
        let query = """
        [out:json][timeout:25];
        (
          way["maxspeed"](around:50,\(coordinate.latitude),\(coordinate.longitude));
          way["highway"](around:50,\(coordinate.latitude),\(coordinate.longitude));
        );
        out body;
        >;
        out skel qt;
        """

        var components = URLComponents(string: overpassBaseUrl)
        components?.queryItems = [
            URLQueryItem(name: "data", value: query)
        ]

        guard let url = components?.url else {
            completion(.failure(NSError(domain: "SpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Overpass URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> OverpassResponse in
                if let jsonString = String(data: data, encoding: .utf8) {
                    self.log("Raw Overpass API JSON response: \(jsonString)", level: .debug)
                }

                let decoder = JSONDecoder()
                return try decoder.decode(OverpassResponse.self, from: data)
            }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("Overpass API error: \(error.localizedDescription)", level: .error)
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] response in
                    let speedLimit = self?.extractSpeedLimitFromOverpassResponse(response) ?? 25

                    // Cache the successful response
                    if let encodedData = try? JSONEncoder().encode(response) {
                        self?.cacheManager.cacheData(
                            encodedData,
                            for: coordinate,
                            apiType: .overpass,
                            expirationTime: 1800 // 30 minutes for speed limits
                        )
                    }

                    completion(.success(speedLimit))
                }
            )
            .store(in: &cancellables)
    }

    // MARK: - HERE API Methods
    private func getSpeedLimitAndRoadNameFromHereCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<(String?, Int?), Error>) -> Void) {
        log("Getting speed limit and road name from HERE API (with caching)", level: .info)

        // Check cache first
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .hereRouteMatching) {
            log("Using cached HERE data", level: .debug)
            if let (roadName, speedLimit) = processCachedHereData(cachedData) {
                completion(.success((roadName, speedLimit)))
                return
            }
        }

        // Check for nearby cached data. Tightened from 100m to 50m: a wider radius
        // could hand back an adjacent (slower) street's cached limit on an exact-cache
        // miss, short-circuiting the API call that would fetch the correct (higher)
        // limit for the road we just moved onto — the stale-low false-warning bug.
        if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .hereRouteMatching, maxDistance: 50) {
            log("Using nearby cached HERE data", level: .debug)
            if let (roadName, speedLimit) = processCachedHereData(nearbyCachedData) {
                completion(.success((roadName, speedLimit)))
                return
            }
        }

        // Make API call if no cached data available
        // Record API call before making it
        hereRateLimiter.recordAPICall(apiType: .routeMatching)

        getSpeedLimitAndRoadNameFromHere(coordinate: coordinate) { result in
            switch result {
            case .success(let (roadName, speedLimit)):
                completion(.success((roadName, speedLimit)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getSpeedLimitAndRoadNameFromHere(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<(String?, Int?), Error>) -> Void) {
        log("Making HERE Route Matching API call for coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .info)

        // Create proper waypoints for route matching - use a larger offset to create a meaningful route segment
        let offset = 0.01 // Increased offset for better route matching (approximately 1km)
        let waypoint0 = "\(coordinate.latitude - offset),\(coordinate.longitude - offset)"
        let waypoint1 = "\(coordinate.latitude + offset),\(coordinate.longitude + offset)"

        log("HERE API waypoints - Start: \(waypoint0), End: \(waypoint1)", level: .debug)

        var components = URLComponents(string: hereRouteMatchingUrl)
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: hereApiKey),
            URLQueryItem(name: "waypoint0", value: waypoint0),
            URLQueryItem(name: "waypoint1", value: waypoint1),
            URLQueryItem(name: "mode", value: "fastest;car"),
            URLQueryItem(name: "routeMatch", value: "1"),
            URLQueryItem(name: "attributes", value: "SPEED_LIMITS_FCn(*),ROAD_NAME_FCn(*),ROAD_GEOM_FCn(*)"),
            URLQueryItem(name: "return", value: "polyline,summary,actions,instructions")
        ]

        guard let url = components?.url else {
            let error = NSError(domain: "SpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct HERE API URL"])
            log("Failed to construct HERE API URL", level: .error)
            completion(.failure(error))
            return
        }

        log("HERE API request URL: \(url.absoluteString)", level: .debug)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0 // Add timeout

        // Mark the moment we are initiating a HERE request to enforce spacing
        lastHereApiCallTime = Date()

        // Track API call for quota monitoring
        hereApiCallCount += 1
        log("HERE API call #\(hereApiCallCount) initiated at: \(Date())", level: .debug)

        log("Initiating HERE API request at: \(Date())", level: .debug)

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> HereRouteMatchingResponse in
                let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                self.log("Raw HERE API response (length: \(data.count) bytes): \(responseString)", level: .debug)

                // Check for HTTP error responses
                if let httpResponse = data as? HTTPURLResponse {
                    self.log("HERE API HTTP status: \(httpResponse.statusCode)", level: .debug)
                    if httpResponse.statusCode != 200 {
                        self.log("HERE API returned non-200 status: \(httpResponse.statusCode)", level: .error)
                        throw NSError(domain: "SpeedLimitService", code: httpResponse.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HERE API returned status \(httpResponse.statusCode)",
                            "response": responseString
                        ])
                    }
                }

                let decoder = JSONDecoder()
                do {
                    let response = try decoder.decode(HereRouteMatchingResponse.self, from: data)
                    self.log("Successfully decoded HERE API response", level: .debug)
                    return response
                } catch {
                    self.log("Failed to decode HERE API response: \(error.localizedDescription)", level: .error)
                    self.log("Response data: \(responseString)", level: .error)
                    throw error
                }
            }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("HERE API request failed: \(error.localizedDescription)", level: .error)
                        if let nsError = error as NSError? {
                            self.log("Error domain: \(nsError.domain), code: \(nsError.code)", level: .error)
                            if let userInfo = nsError.userInfo as? [String: Any] {
                                for (key, value) in userInfo {
                                    self.log("Error info - \(key): \(value)", level: .error)
                                }
                            }
                        }
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] response in
                    self?.log("HERE API response received successfully", level: .info)
                    let (roadName, speedLimit) = self?.extractRoadNameAndSpeedLimitFromHereResponse(response) ?? (nil, nil)

                    self?.log("Extracted from HERE response - Road: \(roadName ?? "nil"), Speed Limit: \(speedLimit?.description ?? "nil")", level: .info)

                    // Cache the successful response
                    if let encodedData = try? JSONEncoder().encode(response) {
                        self?.cacheManager.cacheData(
                            encodedData,
                            for: coordinate,
                            apiType: .hereRouteMatching,
                            expirationTime: 3600 // 1 hour for HERE data
                        )
                        self?.log("Cached HERE API response successfully", level: .debug)
                    }

                    completion(.success((roadName, speedLimit)))
                }
            )
            .store(in: &cancellables)
    }

    private func getRoadNameFromHereGeocodingCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<String, Error>) -> Void) {
        log("Getting road name from HERE Geocoding API (with caching)", level: .info)

        // Check cache first
        if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .hereGeocoding) {
            log("Using cached HERE Geocoding data", level: .debug)
            if let roadName = processCachedHereGeocodingData(cachedData) {
                completion(.success(roadName))
                return
            }
        }

        // Check for nearby cached data
        if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .hereGeocoding, maxDistance: 100) {
            log("Using nearby cached HERE Geocoding data", level: .debug)
            if let roadName = processCachedHereGeocodingData(nearbyCachedData) {
                completion(.success(roadName))
                return
            }
        }

        // Make API call if no cached data available
        // Record API call before making it
        hereRateLimiter.recordAPICall(apiType: .geocoding)

        getRoadNameFromHereGeocoding(coordinate: coordinate) { result in
            switch result {
            case .success(let roadName):
                completion(.success(roadName))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getRoadNameFromHereGeocoding(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<String, Error>) -> Void) {
        log("Making HERE Geocoding API call for coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .info)

        var components = URLComponents(string: hereGeocodingUrl)
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: hereApiKey),
            URLQueryItem(name: "at", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components?.url else {
            let error = NSError(domain: "SpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct HERE Geocoding URL"])
            log("Failed to construct HERE Geocoding URL", level: .error)
            completion(.failure(error))
            return
        }

        log("HERE Geocoding API request URL: \(url.absoluteString)", level: .debug)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0 // Add timeout

        // Mark the moment we are initiating a HERE request to enforce spacing
        lastHereApiCallTime = Date()

        // Track API call for quota monitoring
        hereApiCallCount += 1
        log("HERE Geocoding API call #\(hereApiCallCount) initiated at: \(Date())", level: .debug)

        log("Initiating HERE Geocoding API request at: \(Date())", level: .debug)

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .tryMap { data -> HereGeocodingResponse in
                let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                self.log("Raw HERE Geocoding API response (length: \(data.count) bytes): \(responseString)", level: .debug)

                // Check for HTTP error responses
                if let httpResponse = data as? HTTPURLResponse {
                    self.log("HERE Geocoding API HTTP status: \(httpResponse.statusCode)", level: .debug)
                    if httpResponse.statusCode != 200 {
                        self.log("HERE Geocoding API returned non-200 status: \(httpResponse.statusCode)", level: .error)
                        throw NSError(domain: "SpeedLimitService", code: httpResponse.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HERE Geocoding API returned status \(httpResponse.statusCode)",
                            "response": responseString
                        ])
                    }
                }

                let decoder = JSONDecoder()
                do {
                    let response = try decoder.decode(HereGeocodingResponse.self, from: data)
                    self.log("Successfully decoded HERE Geocoding API response", level: .debug)
                    return response
                } catch {
                    self.log("Failed to decode HERE Geocoding API response: \(error.localizedDescription)", level: .error)
                    self.log("Response data: \(responseString)", level: .error)
                    throw error
                }
            }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completionResult in
                    if case .failure(let error) = completionResult {
                        self.log("HERE Geocoding API error: \(error.localizedDescription)", level: .error)
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] response in
                    let roadName = self?.extractRoadNameFromHereGeocodingResponse(response) ?? "Unknown Road"

                    // Cache the successful response
                    if let encodedData = try? JSONEncoder().encode(response) {
                        self?.cacheManager.cacheData(
                            encodedData,
                            for: coordinate,
                            apiType: .hereGeocoding,
                            expirationTime: 7200 // 2 hours for geocoding data
                        )
                    }

                    completion(.success(roadName))
                }
            )
            .store(in: &cancellables)
    }

    // MARK: - HERE API Data Processing
    private func processCachedHereData(_ data: Data) -> (String?, Int?)? {
        do {
            let response = try JSONDecoder().decode(HereRouteMatchingResponse.self, from: data)
            let (roadName, speedLimit) = extractRoadNameAndSpeedLimitFromHereResponse(response)
            return (roadName, speedLimit)
        } catch {
            log("Failed to process cached HERE data: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func processCachedHereGeocodingData(_ data: Data) -> String? {
        do {
            let response = try JSONDecoder().decode(HereGeocodingResponse.self, from: data)
            return extractRoadNameFromHereGeocodingResponse(response)
        } catch {
            log("Failed to process cached HERE Geocoding data: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func extractRoadNameAndSpeedLimitFromHereResponse(_ response: HereRouteMatchingResponse) -> (String?, Int?) {
        guard let route = response.response?.route?.first,
              let waypoint = route.waypoint?.first,
              let attributes = waypoint.attributes else {
            log("No route data found in HERE response", level: .warning)
            return (nil, nil)
        }

        var roadName: String?
        var speedLimit: Int?

        // Extract road name
        if let roadNames = attributes.ROAD_NAME_FCN, let firstRoadName = roadNames.first {
            roadName = firstRoadName.ROAD_NAME
            log("Found road name from HERE: \(roadName ?? "Unknown")", level: .info)
        }

        // Extract speed limit
        if let speedLimits = attributes.SPEED_LIMITS_FCN, let firstSpeedLimit = speedLimits.first {
            speedLimit = firstSpeedLimit.speedLimitMph
            log("Found speed limit from HERE: \(speedLimit ?? 25) MPH", level: .info)
        }

        return (roadName, speedLimit)
    }

    private func extractRoadNameFromHereGeocodingResponse(_ response: HereGeocodingResponse) -> String {
        guard let items = response.items, let firstItem = items.first else {
            log("No geocoding data found in HERE response", level: .warning)
            return "Unknown Road"
        }

        // Try to get street name from address
        if let street = firstItem.address?.street {
            log("Found road name from HERE Geocoding: \(street)", level: .info)
            return street
        }

        // Fallback to title
        if let title = firstItem.title {
            log("Using title as road name from HERE Geocoding: \(title)", level: .info)
            return title
        }

        log("No road name found in HERE Geocoding response", level: .warning)
        return "Unknown Road"
    }

    // MARK: - OpenStreetMap Data Processing
    private func processCachedNominatimData(_ data: Data) -> String? {
        do {
            let response = try JSONDecoder().decode(NominatimResponse.self, from: data)
            if let roadName = response.address?.road {
                return roadName
            } else {
                // Fallback to other address components
                return response.address?.suburb ?? response.address?.city ?? "Unknown Road"
            }
        } catch {
            log("Failed to process cached Nominatim data: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func processCachedOverpassDataForRoadAndSpeed(_ data: Data) -> (String?, Int?)? {
        do {
            let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
            // Use a dummy coordinate for cached data processing
            let dummyCoordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            let (roadName, speedLimit) = extractRoadNameAndSpeedLimitFromOverpassResponse(response, coordinate: dummyCoordinate)
            return (roadName, speedLimit)
        } catch {
            log("Failed to process cached Overpass data for road and speed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func processCachedOverpassData(_ data: Data) -> Int? {
        do {
            let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
            return extractSpeedLimitFromOverpassResponse(response)
        } catch {
            log("Failed to process cached Overpass data: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Geometry/bearing-aware match: pick the nearby way the user is most likely
    /// on, using distance to the way's polyline and (when available) the
    /// alignment between the user's GPS course and the road's local bearing.
    /// This is what stops the app latching onto a parallel or cross street.
    private func bestOverpassElement(in response: OverpassResponse,
                                     coordinate: CLLocationCoordinate2D,
                                     course: Double?) -> (element: OverpassElement, distance: Double)? {
        let nonDrivable: Set<String> = ["footway", "cycleway", "path", "track",
                                        "steps", "bridleway", "pedestrian",
                                        "construction", "proposed"]
        var best: (element: OverpassElement, distance: Double)?
        var bestScore = Double.infinity

        for element in response.elements {
            guard let tags = element.tags, let highway = tags.highway?.lowercased() else { continue }
            if nonDrivable.contains(highway) { continue }
            guard let geometry = element.geometry, !geometry.isEmpty else { continue }

            let (distance, segBearing) = nearestSegment(coordinate: coordinate, geometry: geometry)
            if distance > 40 { continue } // too far to plausibly be the current road

            // Lower score wins: meters of distance plus an alignment penalty.
            var score = distance
            if let course = course, course >= 0, let segBearing = segBearing {
                let misalign = SpeedLimitGeo.headingAlignment(course, segBearing) // 0...90
                score += misalign * 0.8 // heavily penalise perpendicular cross streets
            }
            if tags.name == nil { score += 3 } // small tie-break toward named roads

            if score < bestScore {
                bestScore = score
                best = (element, distance)
            }
        }
        return best
    }

    /// All speed-limit results derivable from one Overpass response for the
    /// bearing-matched road: a posted reading from `maxspeed` (when tagged) and
    /// a statutory-default reading (always, as a lower-confidence fallback).
    private func overpassResults(from response: OverpassResponse,
                                 coordinate: CLLocationCoordinate2D,
                                 course: Double?,
                                 stateCode: String?) -> (roadName: String?, results: [SpeedLimitResult]) {
        guard let match = bestOverpassElement(in: response, coordinate: coordinate, course: course),
              let tags = match.element.tags, let highway = tags.highway else {
            return (nil, [])
        }
        let roadName = tags.name
        var results: [SpeedLimitResult] = []

        if let maxspeed = tags.maxspeed, let mph = SpeedLimitParser.parseMaxspeed(maxspeed) {
            results.append(SpeedLimitResult(speedLimitMph: mph, roadName: roadName,
                                            source: .osmMaxspeed, confidence: .posted))
            log("OSM maxspeed: \(mph) MPH on '\(roadName ?? "Unnamed")' (\(Int(match.distance))m)", level: .info)
        }

        let ctx = StatutoryRoadContext(highway: highway,
                                       isLit: tags.lit.map { $0.lowercased() == "yes" },
                                       maxspeedType: tags.maxspeedType,
                                       stateCode: stateCode)
        if let statutory = StatutoryDefaultSpeeds.result(for: ctx, roadName: roadName) {
            results.append(statutory)
            log("Statutory default: \(statutory.speedLimitMph ?? -1) MPH for '\(highway)'", level: .info)
        }
        return (roadName, results)
    }

    /// Distance (m) from `coordinate` to a way's polyline, plus the local bearing
    /// of the nearest segment (nil for single-point geometry).
    private func nearestSegment(coordinate: CLLocationCoordinate2D,
                                geometry: [OverpassGeom]) -> (distance: Double, bearing: Double?) {
        let pt = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if geometry.count == 1 {
            let only = CLLocation(latitude: geometry[0].lat, longitude: geometry[0].lon)
            return (pt.distance(from: only), nil)
        }
        var minDist = Double.infinity
        var bearing: Double?
        for i in 0..<(geometry.count - 1) {
            let a = CLLocationCoordinate2D(latitude: geometry[i].lat, longitude: geometry[i].lon)
            let b = CLLocationCoordinate2D(latitude: geometry[i + 1].lat, longitude: geometry[i + 1].lon)
            let d = distanceToSegment(coordinate, a, b)
            if d < minDist {
                minDist = d
                bearing = SpeedLimitGeo.bearing(from: a, to: b)
            }
        }
        return (minDist, bearing)
    }

    /// Distance (m) from point P to segment AB via a local equirectangular
    /// projection (accurate at street scale, P as origin).
    private func distanceToSegment(_ p: CLLocationCoordinate2D,
                                   _ a: CLLocationCoordinate2D,
                                   _ b: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(p.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - p.longitude) * mPerDegLon, (c.latitude - p.latitude) * mPerDegLat)
        }
        let (ax, ay) = xy(a); let (bx, by) = xy(b) // P is origin (0,0)
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(ax, ay) }
        var t = -(ax * dx + ay * dy) / lenSq
        t = max(0, min(1, t))
        let cx = ax + t * dx, cy = ay + t * dy
        return hypot(cx, cy)
    }

    // Backward-compatible wrapper used by cached integer paths (no course).
    private func extractRoadNameAndSpeedLimitFromOverpassResponse(_ response: OverpassResponse, coordinate: CLLocationCoordinate2D) -> (String?, Int?) {
        let (roadName, results) = overpassResults(from: response, coordinate: coordinate, course: nil, stateCode: nil)
        return (roadName, SpeedLimitResolver.reconcile(results)?.speedLimitMph)
    }

    // Cached-data fallback: best available speed limit without snapping geometry.
    private func extractSpeedLimitFromOverpassResponse(_ response: OverpassResponse) -> Int? {
        for element in response.elements {
            guard let tags = element.tags, let highway = tags.highway else { continue }
            if let maxspeed = tags.maxspeed, let mph = SpeedLimitParser.parseMaxspeed(maxspeed) { return mph }
            let ctx = StatutoryRoadContext(highway: highway,
                                           isLit: tags.lit.map { $0.lowercased() == "yes" },
                                           maxspeedType: tags.maxspeedType, stateCode: nil)
            if let mph = StatutoryDefaultSpeeds.defaultSpeed(for: ctx) { return mph }
        }
        return nil
    }



    // MARK: - Rate Limit Handling
    private func handleRateLimit(coordinate: CLLocationCoordinate2D) {
        rateLimitCount += 1
        let timeSinceReset = Date().timeIntervalSince(rateLimitResetTime)

        // Reset counter if it's been more than 1 hour
        if timeSinceReset > 3600 {
            rateLimitCount = 1
            rateLimitResetTime = Date()
        }

        if rateLimitCount >= maxRateLimitCount {
            // We've hit too many rate limits, extend the cooldown
            let extendedCooldown = TimeInterval(rateLimitCount * 60) // 1 minute per rate limit
            currentApiCallCooldown = extendedCooldown
            log("Multiple rate limits hit (\(rateLimitCount)). Extending cooldown to \(Int(extendedCooldown))s", level: .warning)

            DispatchQueue.main.async {
                self.currentSpeedLimit = nil
                self.isLoading = false
                self.errorMessage = "Speed limit unavailable (rate limited - try again later)"
            }

            // Update cooldown time
            lastApiCallTime = Date().addingTimeInterval(-extendedCooldown)
        } else {
            // Normal rate limit handling
            log("Rate limit reached (\(rateLimitCount)/\(maxRateLimitCount)) - speed limit unavailable", level: .warning)
            DispatchQueue.main.async {
                self.currentSpeedLimit = nil
                self.isLoading = false
                self.errorMessage = "Speed limit unavailable (rate limited)"
            }
        }
    }

    // MARK: - Rate Limiting Queue Management
    private func enqueueApiCall(coordinate: CLLocationCoordinate2D, completion: @escaping () -> Void) {
        log("Enqueueing API call for rate limiting", level: .debug)

        apiCallQueue.append((coordinate: coordinate, completion: completion))

        if !isProcessingQueue {
            processApiCallQueue()
        }
    }

        private func processApiCallQueue() {
        guard !apiCallQueue.isEmpty && !isProcessingQueue else { return }

        isProcessingQueue = true

        rateLimitQueue.async { [weak self] in
            guard let self = self else { return }

            while !self.apiCallQueue.isEmpty {
                let timeSinceLastCall = Date().timeIntervalSince(self.lastApiCallTime)

                if timeSinceLastCall < self.currentApiCallCooldown {
                    let remainingTime = self.currentApiCallCooldown - timeSinceLastCall
                    self.log("Rate limiting: waiting \(Int(remainingTime))s before next API call", level: .debug)
                    Thread.sleep(forTimeInterval: remainingTime)
                }

                // Process next API call
                let nextCall = self.apiCallQueue.removeFirst()
                self.lastApiCallTime = Date()

                self.log("Processing queued API call", level: .debug)

                DispatchQueue.main.async {
                    self.resolveSpeedLimit(coordinate: nextCall.coordinate, course: nil)
                    nextCall.completion()
                }

                // Ensure minimum 1-second gap between calls
                Thread.sleep(forTimeInterval: 1.0)
            }

            DispatchQueue.main.async {
                self.isProcessingQueue = false
            }
        }
    }

    // MARK: - Strict Rate Limiting Check
    private func checkRateLimit() -> Bool {
        let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)

        if timeSinceLastCall < currentApiCallCooldown {
            let remainingTime = Int(currentApiCallCooldown - timeSinceLastCall)
            log("API call blocked by rate limit. \(remainingTime)s remaining", level: .warning)
            return false
        }

        return true
    }

    // MARK: - Road Name Change Detection
    private var lastRoadName: String?
    private var roadNameValidationHistory: [String: (count: Int, lastSeen: Date)] = [:]
    private let roadNameValidationThreshold = 3 // Require 3 consistent readings
    private let roadNameValidationTimeWindow: TimeInterval = 30 // 30 seconds

    func updateRoadName(_ newRoadName: String?, for coordinate: CLLocationCoordinate2D) {
        // Validate the road name to ensure it's the actual road being driven on
        let validatedRoadName = validateRoadName(newRoadName)

        // Check if road name has changed
        if let validatedRoadName = validatedRoadName, validatedRoadName != lastRoadName {
            log("Road name changed from '\(lastRoadName ?? "nil")' to '\(validatedRoadName)'. Triggering speed limit lookup.", level: .info)

            // Update the stored road name
            lastRoadName = validatedRoadName

            // Update validation road name tracking
            lastValidationRoadName = validatedRoadName

            // Clear the current speed limit since it's for a different road
            DispatchQueue.main.async {
                self.currentSpeedLimit = nil
                self.errorMessage = "Road changed, looking up new speed limit..."
            }

            // Trigger a new speed limit lookup for the new road
            // Use forceLookupSpeedLimit to bypass cooldown since this is a road change
            forceLookupSpeedLimit(for: coordinate)
        } else if let validatedRoadName = validatedRoadName {
            // Road name is the same, just update it
            lastRoadName = validatedRoadName
            lastValidationRoadName = validatedRoadName
        }
    }

    private func validateRoadName(_ roadName: String?) -> String? {
        guard let roadName = roadName else { return nil }

        // Skip obviously invalid road names
        if roadName.isEmpty || roadName == "Unknown Road" || roadName == "Unknown" {
            return nil
        }

        // Skip very short names that might be cross streets
        if roadName.count < 3 {
            log("Rejecting very short road name: '\(roadName)' (likely cross street)", level: .debug)
            return nil
        }

        // Skip names that look like addresses or cross streets
        let suspiciousPatterns = [
            "St", "Ave", "Blvd", "Dr", "Rd", "Ln", "Ct", "Pl", "Way", "Cir"
        ]

        // Check if the name is just a street type (likely a cross street)
        if suspiciousPatterns.contains(where: { roadName.lowercased() == $0.lowercased() }) {
            log("Rejecting road name that appears to be just a street type: '\(roadName)'", level: .debug)
            return nil
        }

        // Track road name frequency to validate consistency
        let now = Date()
        let cutoffTime = now.addingTimeInterval(-roadNameValidationTimeWindow)

        // Clean up old entries
        roadNameValidationHistory = roadNameValidationHistory.filter { $0.value.lastSeen > cutoffTime }

        // Update or add current road name
        if let existing = roadNameValidationHistory[roadName] {
            roadNameValidationHistory[roadName] = (count: existing.count + 1, lastSeen: now)
        } else {
            roadNameValidationHistory[roadName] = (count: 1, lastSeen: now)
        }

        // Only return road names that have been seen consistently
        if let entry = roadNameValidationHistory[roadName], entry.count >= roadNameValidationThreshold {
            log("Road name '\(roadName)' validated (seen \(entry.count) times)", level: .debug)
            return roadName
        } else {
            log("Road name '\(roadName)' not yet validated (seen \(roadNameValidationHistory[roadName]?.count ?? 0) times, need \(roadNameValidationThreshold))", level: .debug)
            return nil
        }
    }

    // MARK: - Cache Management
    func getCachedSpeedLimit(for coordinate: CLLocationCoordinate2D) -> Int? {
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)
        if let cached = coordinateCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
            return cached.speedLimit
        }
        return nil
    }

    // MARK: - Rate Limiting Status
    func getRateLimitStatus() -> (isRateLimited: Bool, timeRemaining: Int, queueLength: Int) {
        let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)
        let isRateLimited = timeSinceLastCall < currentApiCallCooldown
        let timeRemaining = isRateLimited ? Int(currentApiCallCooldown - timeSinceLastCall) : 0
        let queueLength = apiCallQueue.count

        return (isRateLimited: isRateLimited, timeRemaining: timeRemaining, queueLength: queueLength)
    }

    func clearRateLimitQueue() {
        log("Clearing rate limit queue", level: .info)
        apiCallQueue.removeAll()
        isProcessingQueue = false
    }

    func getCachedRoadName(for coordinate: CLLocationCoordinate2D) -> String? {
        let cacheKey = SpeedLimitGeo.gridKey(coordinate)
        if let cached = coordinateCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
            return cached.roadName
        }
        return nil
    }

    // MARK: - Validation System Status
    func getValidationStatus() -> (lastValidSpeed: Int?, confidence: Int, historyCount: Int, isValidationActive: Bool, currentRoad: String?, lastValidationRoad: String?) {
        let lastValidSpeed = lastValidSpeedLimit?.speed
        let confidence = lastValidSpeedLimit?.confidence ?? 0
        let historyCount = speedLimitHistory.count
        let isValidationActive = lastValidSpeedLimit != nil
        let currentRoad = currentRoadName
        let lastValidationRoad = lastValidationRoadName

        return (lastValidSpeed: lastValidSpeed, confidence: confidence, historyCount: historyCount, isValidationActive: isValidationActive, currentRoad: currentRoad, lastValidationRoad: lastValidationRoad)
    }

    // MARK: - Helper Computed Properties
    private var batteryIconName: String {
        // This would need to be implemented based on your battery monitoring
        return "battery.100"
    }

    private var batteryColor: String {
        // This would need to be implemented based on your battery monitoring
        return "green"
    }

    // MARK: - HERE API Rate Limiting
    func getHEREUsageStats() -> HEREUsageStats {
        return hereRateLimiter.getUsageStats()
    }

    func getHEREStatusMessage() -> String {
        return hereRateLimiter.statusMessage
    }

    func shouldUseHEREAPI() -> Bool {
        return hereRateLimiter.shouldUseHEREAPI
    }

    func logHEREUsageStats() {
        hereRateLimiter.logUsageStats()
        logHereApiQuotaStatus()
    }

    // MARK: - HERE API Quota Monitoring

    private func checkHereApiQuota() -> Bool {
        let now = Date()
        let timeSinceStart = now.timeIntervalSince(hereApiCallStartTime)

        // Reset quota window if more than 1 hour has passed
        if timeSinceStart >= hereApiQuotaWindow {
            hereApiCallCount = 0
            hereApiCallStartTime = now
            log("HERE API quota window reset", level: .info)
        }

        let quotaUsed = hereApiCallCount
        let quotaRemaining = hereApiQuotaLimit - quotaUsed
        let quotaPercentage = Double(quotaUsed) / Double(hereApiQuotaLimit) * 100

        log("HERE API quota status: \(quotaUsed)/\(hereApiQuotaLimit) calls used (\(String(format: "%.1f", quotaPercentage))%)", level: .debug)

        if quotaUsed >= hereApiQuotaLimit {
            log("HERE API quota exceeded: \(quotaUsed)/\(hereApiQuotaLimit) calls used", level: .warning)
            return false
        }

        if quotaPercentage >= 90 {
            log("HERE API quota warning: \(String(format: "%.1f", quotaPercentage))% used", level: .warning)
        }

        return true
    }

    private func logHereApiQuotaStatus() {
        let now = Date()
        let timeSinceStart = now.timeIntervalSince(hereApiCallStartTime)
        let quotaUsed = hereApiCallCount
        let quotaRemaining = hereApiQuotaLimit - quotaUsed
        let quotaPercentage = Double(quotaUsed) / Double(hereApiQuotaLimit) * 100
        let timeRemaining = hereApiQuotaWindow - timeSinceStart

        log("HERE API Quota Status:", level: .info)
        log("  Calls used: \(quotaUsed)/\(hereApiQuotaLimit) (\(String(format: "%.1f", quotaPercentage))%)", level: .info)
        log("  Calls remaining: \(quotaRemaining)", level: .info)
        log("  Time in current window: \(String(format: "%.1f", timeSinceStart/60)) minutes", level: .info)
        log("  Time until reset: \(String(format: "%.1f", timeRemaining/60)) minutes", level: .info)
    }

    // MARK: - HERE API Testing & Debugging

    func testHereApiEndpoint(coordinate: CLLocationCoordinate2D) {
        log("=== HERE API ENDPOINT TEST ===", level: .info)
        log("Testing coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .info)
        log("API Key present: \(!hereApiKey.isEmpty)", level: .info)
        log("API Key length: \(hereApiKey.count) characters", level: .info)
        log("Base URL: \(hereRouteMatchingUrl)", level: .info)

        // Test quota status
        let quotaOk = checkHereApiQuota()
        log("Quota check passed: \(quotaOk)", level: .info)

        // Test rate limiting
        let rateLimitStatus = hereRateLimiter.checkRateLimit()
        log("Rate limit status: \(rateLimitStatus)", level: .info)

        // Test waypoint creation
        let offset = 0.01
        let waypoint0 = "\(coordinate.latitude - offset),\(coordinate.longitude - offset)"
        let waypoint1 = "\(coordinate.latitude + offset),\(coordinate.longitude + offset)"
        log("Test waypoints - Start: \(waypoint0), End: \(waypoint1)", level: .info)

        // Test URL construction
        var components = URLComponents(string: hereRouteMatchingUrl)
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: hereApiKey),
            URLQueryItem(name: "waypoint0", value: waypoint0),
            URLQueryItem(name: "waypoint1", value: waypoint1),
            URLQueryItem(name: "mode", value: "fastest;car"),
            URLQueryItem(name: "routeMatch", value: "1"),
            URLQueryItem(name: "attributes", value: "SPEED_LIMITS_FCn(*),ROAD_NAME_FCn(*),ROAD_GEOM_FCn(*)"),
            URLQueryItem(name: "return", value: "polyline,summary,actions,instructions")
        ]

        if let url = components?.url {
            log("Constructed URL: \(url.absoluteString)", level: .info)
        } else {
            log("Failed to construct URL", level: .error)
        }

        log("=== END HERE API TEST ===", level: .info)
    }
}



    // MARK: - OpenStreetMap API Response Models

    // Nominatim Response Models
    struct NominatimResponse: Codable {
        let address: NominatimAddress?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case address
            case displayName = "display_name"
        }
    }

    struct NominatimAddress: Codable {
        let road: String?
        let suburb: String?
        let city: String?
        let state: String?
        let country: String?
        let postcode: String?
    }

    // Overpass Response Models
    struct OverpassResponse: Codable {
        let elements: [OverpassElement]
    }

    struct OverpassElement: Codable {
        let type: String
        let id: Int
        let tags: OverpassTags?
        let geometry: [OverpassGeom]?
    }

    struct OverpassGeom: Codable {
        let lat: Double
        let lon: Double
    }

    struct OverpassTags: Codable {
        let maxspeed: String?
        let highway: String?
        let name: String?
        let lanes: String?
        let lit: String?
        let maxspeedType: String?

        enum CodingKeys: String, CodingKey {
            case maxspeed, highway, name, lanes, lit
            case maxspeedType = "maxspeed:type"
        }
    }

    // MARK: - TomTom Reverse Geocode Response Models
    struct TomTomReverseResponse: Codable {
        let addresses: [TomTomAddressEntry]?
    }

    struct TomTomAddressEntry: Codable {
        let address: TomTomAddress?
    }

    struct TomTomAddress: Codable {
        let streetName: String?
        let freeformAddress: String?
        let countrySubdivisionCode: String? // e.g. "US-CA"
        let speedLimit: String?             // e.g. "30.00MPH" when returnSpeedLimit=true
    }

    // MARK: - HERE API Response Models
    struct HereRouteMatchingResponse: Codable {
        let response: HereRouteResponse?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case response
            case error
            case errorDescription = "error_description"
        }
    }

    struct HereRouteResponse: Codable {
        let route: [HereRoute]?
    }

    struct HereRoute: Codable {
        let waypoint: [HereWaypoint]?
    }

    struct HereWaypoint: Codable {
        let linkId: String?
        let attributes: HereWaypointAttributes?

        enum CodingKeys: String, CodingKey {
            case linkId = "linkId"
            case attributes
        }
    }

    struct HereWaypointAttributes: Codable {
        let SPEED_LIMITS_FCN: [HereSpeedLimit]?
        let ROAD_NAME_FCN: [HereRoadName]?
    }

    struct HereSpeedLimit: Codable {
        let FROM_REF_SPEED_LIMIT: String?
        let TO_REF_SPEED_LIMIT: String?
        let SPEED_LIMIT_SOURCE: String?
        let SPEED_LIMIT_UNIT: String?

        var speedLimitMph: Int? {
            guard let fromLimit = FROM_REF_SPEED_LIMIT, let unit = SPEED_LIMIT_UNIT else { return nil }

            if let speed = Int(fromLimit) {
                // Convert km/h to mph if needed
                if unit == "K" { // Kilometers per hour
                    return Int(Double(speed) * 0.621371)
                } else if unit == "M" { // Miles per hour
                    return speed
                }
            }
            return nil
        }
    }

    struct HereRoadName: Codable {
        let ROAD_NAME: String?
        let LANGUAGE: String?
    }

    struct HereGeocodingResponse: Codable {
        let items: [HereGeocodingItem]?
    }

    struct HereGeocodingItem: Codable {
        let title: String?
        let address: HereAddress?
    }

    struct HereAddress: Codable {
        let street: String?
        let city: String?
        let state: String?
        let country: String?
    }
