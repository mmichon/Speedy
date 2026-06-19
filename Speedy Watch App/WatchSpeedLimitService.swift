import Foundation
import CoreLocation
import Combine
import SpeedyShared

enum LogLevel: String {
    case debug = "[DEBUG]"
    case info = "[INFO]"
    case warning = "[WARN]"
    case error = "[ERROR]"
}

// MARK: - Cache Models
struct CachedAPIData: Codable {
    let data: Data
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let cacheKey: String
    let expiresAt: Date

    var isExpired: Bool {
        return Date() > expiresAt
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
    private let maxMemoryCacheSize = 50 // Smaller for watch - maximum number of items in memory
    private let maxDiskCacheSize = 10 * 1024 * 1024 // 10 MB disk cache for watch
    private let cacheExpirationTime: TimeInterval = 3600 // 1 hour default

    private init() {
        // Set up disk cache directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        diskCacheURL = documentsPath.appendingPathComponent("APICache")

        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Configure memory cache
        memoryCache.countLimit = maxMemoryCacheSize
        memoryCache.totalCostLimit = maxMemoryCacheSize * 512 * 1024 // 50 MB

        // Load cache metadata
        loadCacheMetadata()

        // Clean up expired cache entries
        cleanupExpiredCache()
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
                log("Found \(apiType.rawValue) data in disk cache", level: .debug)
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
            let distance = coordinate.distance(from: cachedCoordinate)

            if distance <= maxDistance {
                if let cachedData = getCachedData(for: cachedCoordinate, apiType: apiType, radius: cacheKey.radius) {
                    log("Found nearby cached \(apiType.rawValue) data within \(Int(distance))m", level: .debug)
                    return cachedData
                }
            }
        }

        return nil
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("\(timestamp) \(level.rawValue) WatchAPICacheManager: \(message)")
    }
}

class WatchSpeedLimitService: ObservableObject {
    // MARK: - Published Properties
    @Published var currentSpeedLimit: Int?
    @Published var currentRoadName: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var confidence: SpeedLimitConfidence = .unknown

    private var cancellables = Set<AnyCancellable>()
    private let cacheManager = APICacheManager.shared

    // MARK: - Enhanced Rate Limiting & Caching
    private var lastApiCallTime: Date = Date.distantPast
    private let baseApiCallCooldown: TimeInterval = 1.0 // Strict 1 second for OpenStreetMap APIs
    private var currentApiCallCooldown: TimeInterval = 1.0
    private var lastKnownGoodSpeedLimit: (speed: Int, coordinate: CLLocationCoordinate2D, timestamp: Date)?
    private var rateLimitCount: Int = 0
    private let maxRateLimitCount: Int = 3 // Reduced for stricter rate limiting
    private var rateLimitResetTime: Date = Date.distantPast
    private var lastSuccessfulApiCall: Date = Date.distantPast
    private var coordinateCache: [String: (speedLimit: Int, roadName: String, timestamp: Date)] = [:]
    private let cacheExpirationTime: TimeInterval = 300 // 5 minutes

    // MARK: - Rate Limiting Queue
    private var apiCallQueue: [(coordinate: CLLocationCoordinate2D, completion: () -> Void)] = []
    private var isProcessingQueue = false
    private let rateLimitQueue = DispatchQueue(label: "com.speedy.watch.ratelimit", qos: .utility)

    // MARK: - OpenStreetMap API Configuration
    private let nominatimBaseUrl = "https://nominatim.openstreetmap.org"
    private let overpassBaseUrl = "https://overpass-api.de/api/interpreter"

    // User agent for OpenStreetMap APIs (required for production use)
    private let userAgent = "SpeedyWatchApp/1.0 (https://github.com/yourusername/speedy; your@email.com)"

    // MARK: - Speed Limit Sources
    enum SpeedLimitSource: String, CaseIterable {
        case overpassSpeedLimits = "Overpass Speed Limits"
        case nominatimRoadNames = "Nominatim Road Names"
        case cache = "Cache"
        case estimated = "Estimated"

        var priority: Int {
            switch self {
            case .overpassSpeedLimits: return 100
            case .nominatimRoadNames: return 80
            case .cache: return 60
            case .estimated: return 40
            }
        }
    }

    enum SpeedLimitConfidence: String, CaseIterable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        case unknown = "Unknown"

        var priority: Int {
            switch self {
            case .high: return 100
            case .medium: return 75
            case .low: return 50
            case .unknown: return 25
            }
        }
    }

    private func log(_ message: String, level: LogLevel = .info) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("\(timestamp) \(level.rawValue) WatchSpeedLimitService: \(message)")
    }

    // MARK: - Main Speed Limit Lookup
    func lookupSpeedLimit(for coordinate: CLLocationCoordinate2D) {
        log("lookupSpeedLimit called with coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .debug)

        // Check coordinate cache first
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude)"
        if let cached = coordinateCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
            log("Using cached data for coordinate", level: .info)
            DispatchQueue.main.async {
                self.currentSpeedLimit = cached.speedLimit
                self.currentRoadName = cached.roadName
                self.isLoading = false
                self.errorMessage = nil
                self.confidence = .medium // Cached data has medium confidence
            }
            return
        }

        // Check if we're on cooldown to avoid hitting rate limits
        let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)
        if timeSinceLastCall < currentApiCallCooldown {
            let remainingTime = Int(currentApiCallCooldown - timeSinceLastCall)
            log("API call on cooldown. Enqueueing for rate limiting. \(remainingTime)s remaining", level: .warning)

            // If we have cached data, use it immediately
            if let cached = lastKnownGoodSpeedLimit,
               Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
                log("Using cached speed limit data while enqueueing API call", level: .info)
                DispatchQueue.main.async {
                    self.currentSpeedLimit = cached.speed
                    self.errorMessage = "Using cached data (API call queued for rate limiting)"
                    self.confidence = .low // Rate limited data has low confidence
                }
            }

            // Enqueue the API call for later processing
            enqueueApiCall(coordinate: coordinate) {
                // This completion will be called when the API call is processed
                log("API call processed from queue", level: .debug)
            }
            return
        }

        lastApiCallTime = Date()
        isLoading = true
        errorMessage = nil
        confidence = .unknown

        // Start OpenStreetMap API lookup with caching
        lookupWithOpenStreetMapCached(coordinate: coordinate)
    }

    func forceLookupSpeedLimit(for coordinate: CLLocationCoordinate2D) {
        log("forceLookupSpeedLimit called with coordinate: \(coordinate.latitude), \(coordinate.longitude)", level: .debug)
        lastApiCallTime = Date()
        isLoading = true
        errorMessage = nil
        confidence = .unknown
        lookupWithOpenStreetMapCached(coordinate: coordinate)
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
            self.confidence = .unknown
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

        // Clear API cache
        cacheManager.clearCache()

        DispatchQueue.main.async {
            self.currentSpeedLimit = nil
            self.currentRoadName = nil
            self.errorMessage = "Cache cleared, ready for new lookup"
            self.confidence = .unknown
        }
    }

    // MARK: - OpenStreetMap API Implementation with Caching
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

    private func useCachedDataIfAvailable(coordinate: CLLocationCoordinate2D) {
        log("Attempting to use cached data for offline operation", level: .info)

        // Try to get cached data for nearby coordinates
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
                self.errorMessage = "Using cached data (offline mode)"
                self.confidence = .low // Offline cached data has low confidence
            }
        } else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "No cached data available (offline mode)"
                self.confidence = .unknown
            }
        }
    }

    private func makeOpenStreetMapApiCallsCached(coordinate: CLLocationCoordinate2D) {
        // Use DispatchGroup to run both API calls in parallel
        let group = DispatchGroup()
        var roadName: String?
        var speedLimit: Int?
        var hasError = false

        // Get road name from Nominatim (with caching)
        group.enter()
        getRoadNameFromNominatimCached(coordinate: coordinate) { result in
            switch result {
            case .success(let name):
                roadName = name
                self.log("Nominatim returned road name: \(name)", level: .info)
            case .failure(let error):
                self.log("Nominatim error: \(error.localizedDescription)", level: .warning)
                hasError = true
            }
            group.leave()
        }

        // Get speed limit from Overpass (with caching)
        group.enter()
        getSpeedLimitFromOverpassCached(coordinate: coordinate) { result in
            switch result {
            case .success(let speed):
                speedLimit = speed
                self.log("Overpass returned speed limit: \(speed)", level: .info)
            case .failure(let error):
                self.log("Overpass error: \(error.localizedDescription)", level: .warning)
                hasError = true
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

    // MARK: - Nominatim API with Caching
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
        getRoadNameFromNominatim(coordinate: coordinate) { [weak self] result in
            switch result {
            case .success(let roadName):
                completion(.success(roadName))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

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

    // MARK: - Overpass API with Caching
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
        getSpeedLimitFromOverpass(coordinate: coordinate) { [weak self] result in
            switch result {
            case .success(let speedLimit):
                completion(.success(speedLimit))
            case .failure(let error):
                completion(.failure(error))
            }
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

    // MARK: - Original API Methods (now with caching)
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
            completion(.failure(NSError(domain: "WatchSpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Nominatim URL"])))
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
                        self?.cacheManager.cacheData(
                            try? JSONEncoder().encode(response),
                            for: coordinate,
                            apiType: .nominatim,
                            expirationTime: 7200 // 2 hours for road names
                        )
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
            completion(.failure(NSError(domain: "WatchSpeedLimitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct Overpass URL"])))
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
                    self?.cacheManager.cacheData(
                        try? JSONEncoder().encode(response),
                        for: coordinate,
                        apiType: .overpass,
                        expirationTime: 1800 // 30 minutes for speed limits
                    )

                    completion(.success(speedLimit))
                }
            )
            .store(in: &cancellables)
    }

    private func extractSpeedLimitFromOverpassResponse(_ response: OverpassResponse) -> Int {
        // Look for explicit speed limits first
        for element in response.elements {
            if let maxspeed = element.tags?.maxspeed {
                if let speed = self.parseSpeedLimit(maxspeed) {
                    log("Found explicit speed limit from Overpass: \(speed) MPH", level: .info)
                    return speed
                }
            }
        }

        // Fallback to road type inference
        for element in response.elements {
            if let highway = element.tags?.highway {
                let inferredSpeed = self.inferSpeedLimitFromRoadType(highway)
                log("Inferred speed limit from road type '\(highway)': \(inferredSpeed) MPH", level: .info)
                return inferredSpeed
            }
        }

        // Default fallback
        log("No speed limit data found, using default: 25 MPH", level: .warning)
        return 25
    }

    private func parseSpeedLimit(_ maxspeed: String) -> Int? {
        let lowercased = maxspeed.lowercased()

        // Handle common formats
        if lowercased.contains("mph") {
            let number = lowercased.replacingOccurrences(of: "mph", with: "").trimmingCharacters(in: .whitespaces)
            return Int(number)
        } else if lowercased.contains("km/h") || lowercased.contains("kph") {
            let number = lowercased.replacingOccurrences(of: "km/h", with: "").replacingOccurrences(of: "kph", with: "").trimmingCharacters(in: .whitespaces)
            if let kph = Int(number) {
                return Int(Double(kph) * 0.621371) // Convert KPH to MPH
            }
        } else {
            // Assume it's just a number in MPH
            return Int(maxspeed)
        }

        return nil
    }

    private func inferSpeedLimitFromRoadType(_ roadType: String) -> Int {
        let lowercased = roadType.lowercased()

        switch lowercased {
        case "motorway", "trunk":
            return 65
        case "primary":
            return 45
        case "secondary":
            return 35
        case "tertiary":
            return 30
        case "residential", "service", "living_street":
            return 25
        case "unclassified":
            return 30
        default:
            return 25
        }
    }

    // MARK: - Process Results
    private func processOpenStreetMapResults(roadName: String?, speedLimit: Int?, coordinate: CLLocationCoordinate2D, hasError: Bool) {
        log("Processing OpenStreetMap API results", level: .info)

        // Validate speed limit for reasonable values
        if let speed = speedLimit {
            if speed < 15 || speed > 85 {
                log("WARNING: Suspicious speed limit detected: \(speed) MPH. This may be incorrect data.", level: .warning)
            }
        }

        // Update the last API call time to implement cooldown
        lastApiCallTime = Date()
        lastSuccessfulApiCall = Date()

        // Cache the successful result
        if let speed = speedLimit {
            lastKnownGoodSpeedLimit = (speed: speed, coordinate: coordinate, timestamp: Date())
        }

        // Cache by coordinate
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude)"
        coordinateCache[cacheKey] = (speedLimit: speedLimit ?? 25, roadName: roadName ?? "Unknown Road", timestamp: Date())

        // Reset rate limiting on success
        rateLimitCount = 0
        currentApiCallCooldown = baseApiCallCooldown

        DispatchQueue.main.async {
            self.currentSpeedLimit = speedLimit
            self.currentRoadName = roadName
            self.isLoading = false
            self.errorMessage = hasError ? "Some data may be incomplete" : nil

            // Set confidence based on data quality
            if let speed = speedLimit {
                self.confidence = .high // Direct API response has high confidence
            } else if hasError {
                self.confidence = .low
            } else {
                self.confidence = .medium
            }

            // Update the road name tracking to detect changes
            self.updateRoadName(roadName, for: coordinate)
        }
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
                self.confidence = .unknown
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
                self.confidence = .unknown
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
                    log("Rate limiting: waiting \(Int(remainingTime))s before next API call", level: .debug)
                    Thread.sleep(forTimeInterval: remainingTime)
                }

                // Process next API call
                let nextCall = self.apiCallQueue.removeFirst()
                self.lastApiCallTime = Date()

                log("Processing queued API call", level: .debug)

                DispatchQueue.main.async {
                    self.makeOpenStreetMapApiCallsCached(coordinate: nextCall.coordinate)
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
                self.confidence = .unknown
            }

            // Trigger a new speed limit lookup for the new road
            // Use forceLookupSpeedLimit to bypass cooldown since this is a road change
            forceLookupSpeedLimit(for: coordinate)
        } else if let newRoadName = newRoadName {
            // Road name is the same, just update it
            lastRoadName = newRoadName
        }
    }

    // MARK: - Cache Management
    func getCachedSpeedLimit(for coordinate: CLLocationCoordinate2D) -> Int? {
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude)"
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
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude)"
        if let cached = coordinateCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpirationTime {
            return cached.roadName
        }
        return nil
    }

    // MARK: - Cache Control Methods
    func clearAPICache() {
        cacheManager.clearCache()
        log("API cache cleared", level: .info)
    }

    func clearExpiredAPICache() {
        cacheManager.clearExpiredCache()
        log("Expired API cache cleared", level: .info)
    }

    func getCacheStatistics() -> (memoryCount: Int, diskSize: String) {
        // This would need to be implemented in APICacheManager
        return (0, "0 MB")
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
}

struct OverpassTags: Codable {
    let maxspeed: String?
    let highway: String?
    let name: String?
}