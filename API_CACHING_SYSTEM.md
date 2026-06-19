# 🚀 API Caching System Documentation

## Overview
The Speedy app includes a comprehensive API caching system that significantly improves performance, reduces API calls, and provides offline functionality for HERE and OpenStreetMap data. This system caches HERE Route Matching and Geocoding responses, as well as Nominatim (road names) and Overpass (speed limits) API responses.

## 🏗️ Architecture

### Cache Layers
1. **Memory Cache**: Fast access using NSCache
2. **Disk Cache**: Persistent storage for offline access
3. **Coordinate Cache**: Location-based caching for nearby data

### Cache Managers
- **APICacheManager**: Shared caching system used by the app and widgets

## 📊 Cache Configuration

### Memory Cache
- **Count Limit**: 100 items
- **Approx. Cost Limit**: ~100 MB
- **Eviction Policy**: LRU (Least Recently Used)

### Disk Cache
- **Maximum Size**: 50 MB
- **File Format**: `.cache` files with metadata (JSON-encoded)

### Expiration Times
- **HERE Route Matching**: 1 hour
- **HERE Geocoding**: 2 hours
- **Road Names (Nominatim)**: 2 hours
- **Speed Limits (Overpass)**: 30 minutes
- **Default**: 1 hour
- **Coordinate Cache**: 5 minutes

## 🔧 Key Features

### 1. Intelligent Caching
```swift
// Cache data with custom expiration
cacheManager.cacheData(
    responseData,
    for: coordinate,
    apiType: .nominatim,
    expirationTime: 7200 // 2 hours
)
```

### 2. Nearby Data Lookup
```swift
// Find cached data within 100 meters
let cachedData = cacheManager.getNearbyCachedData(
    for: coordinate,
    apiType: .overpass,
    maxDistance: 100
)
```

### 3. Offline Support
- Automatically falls back to cached data when offline
- Searches nearby coordinates for relevant data
- Provides graceful degradation (prefers HERE cache, falls back to OpenStreetMap cache)

### 4. Automatic Cleanup
- Removes expired cache entries
- Manages disk space automatically
- Cleans up old files based on size limits

## 📱 Implementation Details

### Cache Key Structure
```
{apiType}_{latitude}_{longitude}_{radius}
Example: nominatim_40.7128_-74.0060_50
```

### Data Models
```swift
struct CachedAPIData: Codable {
    let data: Data              // Raw API response
    let timestamp: Date         // When cached
    let coordinate: CLLocationCoordinate2D
    let cacheKey: String        // Unique identifier
    let expiresAt: Date         // Expiration time
}

struct CacheKey: Hashable, Codable {
    let latitude: Double
    let longitude: Double
    let radius: Int
    let apiType: APIType
}
```

### Cache Operations
```swift
// Store data
func cacheData(_ data: Data, for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, radius: Int = 50, expirationTime: TimeInterval? = nil)

// Retrieve data
func getCachedData(for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, radius: Int = 50) -> Data?

// Find nearby data
func getNearbyCachedData(for coordinate: CLLocationCoordinate2D, apiType: CacheKey.APIType, maxDistance: Double = 100) -> Data?

// Clear cache
func clearCache()
func clearExpiredCache()
```

## 🔄 Data Flow

### 1. API Request Flow
```
User Request → Check Memory Cache → Check Disk Cache → Check Nearby Cache → Make API Call → Cache Response
```

### 2. Offline Flow
```
User Request → Check Memory Cache → Check Disk Cache → Check Nearby Cache → Return Cached Data
```

### 3. Cache Update Flow
```
API Response → Validate Data → Store in Memory → Store on Disk → Update Metadata
```

## 🚦 Performance Benefits

### Response Times
- **Memory Cache**: < 1ms
- **Disk Cache**: < 10ms
- **API Call**: 100-500ms
- **Overall Improvement**: 80-95% faster for cached data

### API Call Reduction
- **First Visit**: Full API calls
- **Subsequent Visits**: 0 API calls (cached)
- **Nearby Locations**: 0 API calls (nearby cache)
- **Estimated Savings**: 70-90% fewer API calls

### Battery Life
- Reduced network activity
- Faster response times
- Less CPU usage for parsing

## 🛠️ Usage Examples

### Basic Caching
```swift
// In SpeedLimitService
private func getRoadNameFromNominatimCached(coordinate: CLLocationCoordinate2D, completion: @escaping (Result<String, Error>) -> Void) {
    // Check cache first
    if let cachedData = cacheManager.getCachedData(for: coordinate, apiType: .nominatim) {
        if let roadName = processCachedNominatimData(cachedData) {
            completion(.success(roadName))
            return
        }
    }

    // Check nearby cache
    if let nearbyCachedData = cacheManager.getNearbyCachedData(for: coordinate, apiType: .nominatim, maxDistance: 100) {
        if let roadName = processCachedNominatimData(nearbyCachedData) {
            completion(.success(roadName))
            return
        }
    }

    // Make API call if no cached data
    getRoadNameFromNominatim(coordinate: coordinate, completion: completion)
}
```

### Cache Management
```swift
// Clear all cache
APICacheManager.shared.clearCache()

// Clear expired entries only
APICacheManager.shared.clearExpiredCache()
```

## 🔍 Debugging and Monitoring

### Console Logging
```
12:34:56.789 [DEBUG] APICacheManager: Cached nominatim data for coordinate (40.7128, -74.0060)
12:34:56.790 [DEBUG] APICacheManager: Found overpass data in memory cache
12:34:56.791 [INFO] APICacheManager: Cache metadata loaded - 25 cached files
```

### Cache Statistics
- Number of cached files
- Total disk usage
- Memory cache hit rate
- Expired entry count

### Performance Metrics
- Cache hit/miss ratios
- Response time improvements
- API call reduction statistics

## 🚨 Error Handling

### Cache Failures
- Graceful fallback to API calls
- Automatic cache cleanup on errors
- Logging of all cache operations

### Data Validation
- Checks for expired data
- Validates coordinate ranges
- Ensures data integrity

### Offline Scenarios
- Uses cached data when available
- Provides user feedback about data freshness
- Maintains app functionality without network

## 🔧 Configuration Options

### Cache Sizes
```swift
// In APICacheManager
// memoryCache.countLimit = 100
// totalCostLimit ≈ 100 MB
// maxDiskCacheSize = 50 MB
```

### Expiration Times
```swift
// 1 hour default, overridden per API call in SpeedLimitService
```

### Search Radius
```swift
// Adjust nearby search distance
let nearbyData = cacheManager.getNearbyCachedData(
    for: coordinate,
    apiType: .overpass,
    maxDistance: 100  // 100 meters
)
```

## 📈 Best Practices

### 1. Cache Strategy
- Cache frequently accessed data
- Use appropriate expiration times
- Implement nearby coordinate search

### 2. Memory Management
- Monitor memory usage
- Clear expired entries regularly
- Balance cache size vs. performance

### 3. Offline Support
- Always check cache before API calls
- Provide fallback mechanisms
- Inform users about data freshness

### 4. Performance Optimization
- Use memory cache for hot data
- Implement background cleanup
- Monitor cache hit rates

## 🔮 Future Enhancements

### Planned Features
- **Predictive Caching**: Pre-cache likely destinations
- **Compression**: Reduce disk storage requirements
- **Sync**: Share cache between devices
- **Analytics**: Detailed performance metrics

### Advanced Caching
- **Multi-level Cache**: L1/L2/L3 cache hierarchy
- **Smart Eviction**: ML-based cache management
- **Network Awareness**: Adaptive cache policies

## 🆘 Troubleshooting

### Common Issues
1. **Cache Not Working**
   - Check file permissions
   - Verify disk space
   - Clear and rebuild cache

2. **Memory Issues**
   - Reduce cache size limits
   - Increase cleanup frequency
   - Monitor memory usage

3. **Performance Problems**
   - Check cache hit rates
   - Verify expiration times
   - Monitor API call frequency

### Debug Commands
```swift
// Enable verbose logging
// Add to your logging configuration

// Test cache functionality
APICacheManager.shared.clearCache()
speedLimitService.forceRefreshSpeedLimit(for: coordinate)

// Offline behavior automatically prefers HERE cached data, then OSM
```

## 📚 Integration Guide

### Adding to New Services
1. Import APICacheManager
2. Create cache manager instance
3. Implement cache check before API calls
4. Cache successful responses
5. Handle cache misses gracefully

### Custom Cache Keys
```swift
// Create custom cache keys for different data types
enum CustomAPIType: String, Codable, CaseIterable {
    case weather = "weather"
    case traffic = "traffic"
    case poi = "poi"
}

// Use in cache operations
cacheManager.cacheData(data, for: coordinate, apiType: .weather)
```

This caching system provides a robust foundation for efficient API usage while maintaining excellent user experience, preferring HERE cached results and gracefully falling back to OpenStreetMap when necessary or offline.
