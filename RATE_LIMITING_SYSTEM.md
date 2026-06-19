# 🚦 Rate Limiting System Documentation

## Overview
The Speedy app now includes a comprehensive rate limiting system that ensures strict compliance with OpenStreetMap API usage policies. This system enforces a **one-per-second** rate limit for all API calls to Nominatim and Overpass APIs, preventing rate limiting issues and ensuring reliable service.

## 🎯 Key Features

### 1. Strict 1-Second Rate Limiting
- **Base Cooldown**: 1.0 second between API calls
- **Queue System**: API calls are queued when rate limited
- **Automatic Processing**: Queued calls are processed automatically
- **Compliance**: Ensures adherence to OpenStreetMap usage policies

### 2. Intelligent Queue Management
- **FIFO Queue**: First-in, first-out processing order
- **Background Processing**: Queue processing runs on dedicated background thread
- **Automatic Scheduling**: Calls are processed as soon as rate limits allow
- **Queue Status**: Real-time monitoring of queue length and wait times

### 3. Enhanced User Experience
- **Immediate Cached Data**: Shows cached data while queuing API calls
- **Transparent Processing**: Users see when calls are queued
- **Graceful Degradation**: App continues to function during rate limiting
- **Status Updates**: Clear feedback about rate limiting status

## 🏗️ Architecture

### Rate Limiting Components
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   API Request   │───▶│  Rate Limit      │───▶│  API Call      │
│                 │    │  Check           │    │  Execution     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │  Queue System    │
                       │  (Background)    │
                       └──────────────────┘
```

### Queue Processing Flow
1. **Request Arrives**: API call requested
2. **Rate Check**: Verify if enough time has passed
3. **Immediate Execution**: If no rate limiting needed
4. **Queue if Needed**: If rate limited, add to queue
5. **Background Processing**: Process queue on background thread
6. **Automatic Execution**: Execute calls when rate limits allow

## 📊 Configuration

### Rate Limiting Parameters
```swift
// Base rate limiting
private let baseApiCallCooldown: TimeInterval = 1.0 // 1 second

// Rate limit thresholds
private let maxRateLimitCount: Int = 3 // iOS: 3, Watch: 3

// Extended cooldown calculation
let extendedCooldown = TimeInterval(rateLimitCount * 60) // 1 minute per violation
```

### Queue Configuration
```swift
// Queue processing
private let rateLimitQueue = DispatchQueue(label: "com.speedy.ratelimit", qos: .utility)

// Queue state
private var apiCallQueue: [(coordinate: CLLocationCoordinate2D, completion: () -> Void)] = []
private var isProcessingQueue = false
```

## 🔧 Implementation Details

### Rate Limit Check
```swift
private func checkRateLimit() -> Bool {
    let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)

    if timeSinceLastCall < currentApiCallCooldown {
        let remainingTime = Int(currentApiCallCooldown - timeSinceLastCall)
        log("API call blocked by rate limit. \(remainingTime)s remaining", level: .warning)
        return false
    }

    return true
}
```

### Queue Management
```swift
private func enqueueApiCall(coordinate: CLLocationCoordinate2D, completion: @escaping () -> Void) {
    log("Enqueueing API call for rate limiting", level: .debug)

    apiCallQueue.append((coordinate: coordinate, completion: completion))

    if !isProcessingQueue {
        processApiCallQueue()
    }
}
```

### Queue Processing
```swift
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

            // Execute API call
            DispatchQueue.main.async {
                self.makeOpenStreetMapApiCallsCached(coordinate: nextCall.coordinate)
                nextCall.completion()
            }

            // Ensure minimum 1-second gap
            Thread.sleep(forTimeInterval: 1.0)
        }

        DispatchQueue.main.async {
            self.isProcessingQueue = false
        }
    }
}
```

## 📱 Usage Examples

### Basic Rate Limiting
```swift
func lookupSpeedLimit(for coordinate: CLLocationCoordinate2D) {
    // Check coordinate cache first
    if let cached = getCachedData(for: coordinate) {
        // Use cached data immediately
        return
    }

    // Check if we're on cooldown
    let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)
    if timeSinceLastCall < currentApiCallCooldown {
        // Enqueue for later processing
        enqueueApiCall(coordinate: coordinate) {
            log("API call processed from queue", level: .debug)
        }
        return
    }

    // No rate limiting needed, proceed immediately
    lastApiCallTime = Date()
    makeApiCall(coordinate: coordinate)
}
```

### Force Lookup with Rate Limiting
```swift
func forceLookupSpeedLimit(for coordinate: CLLocationCoordinate2D) {
    // Force lookup bypasses cache but still respects rate limiting
    if checkRateLimit() {
        lastApiCallTime = Date()
        makeApiCall(coordinate: coordinate)
    } else {
        // Enqueue for rate limiting
        log("Force lookup enqueued due to rate limiting", level: .warning)
        enqueueApiCall(coordinate: coordinate) {
            log("Force lookup processed from queue", level: .debug)
        }
    }
}
```

### Rate Limit Status Monitoring
```swift
func getRateLimitStatus() -> (isRateLimited: Bool, timeRemaining: Int, queueLength: Int) {
    let timeSinceLastCall = Date().timeIntervalSince(lastApiCallTime)
    let isRateLimited = timeSinceLastCall < currentApiCallCooldown
    let timeRemaining = isRateLimited ? Int(currentApiCallCooldown - timeSinceLastCall) : 0
    let queueLength = apiCallQueue.count

    return (isRateLimited: isRateLimited, timeRemaining: timeRemaining, queueLength: queueLength)
}
```

## 🔍 Monitoring and Debugging

### Console Logging
```
12:34:56.789 [WARN] SpeedLimitService: API call on cooldown. Enqueueing for rate limiting. 2s remaining
12:34:56.790 [DEBUG] SpeedLimitService: Enqueueing API call for rate limiting
12:34:58.789 [DEBUG] SpeedLimitService: Processing queued API call
12:34:58.790 [DEBUG] SpeedLimitService: API call processed from queue
```

### Rate Limit Status
```swift
let status = speedLimitService.getRateLimitStatus()
print("Rate Limited: \(status.isRateLimited)")
print("Time Remaining: \(status.timeRemaining)s")
print("Queue Length: \(status.queueLength)")
```

### Queue Management
```swift
// Clear the rate limit queue
speedLimitService.clearRateLimitQueue()

// Get current status
let status = speedLimitService.getRateLimitStatus()
```

## 🚨 Error Handling

### Rate Limit Violations
- **Automatic Detection**: System detects when rate limits are exceeded
- **Progressive Penalties**: Cooldown increases with repeated violations
- **Queue Management**: Violations are automatically queued
- **User Feedback**: Clear messages about rate limiting status

### Queue Overflow Protection
- **Unlimited Queue Size**: Queue can handle any number of requests
- **Background Processing**: Queue processing doesn't block main thread
- **Memory Management**: Queue entries are lightweight
- **Automatic Cleanup**: Queue is processed automatically

## 📈 Performance Benefits

### API Call Efficiency
- **Strict Compliance**: Never exceeds OpenStreetMap rate limits
- **Predictable Performance**: Consistent 1-second intervals
- **Reduced Errors**: Fewer rate limit violations
- **Better Reliability**: More stable API access

### User Experience
- **Immediate Feedback**: Cached data shown while queuing
- **Transparent Processing**: Users know when calls are queued
- **No Blocking**: App remains responsive during rate limiting
- **Automatic Recovery**: Queue processing happens automatically

## 🔧 Configuration Options

### Adjustable Parameters
```swift
// Base cooldown (must be >= 1.0 for OpenStreetMap compliance)
private let baseApiCallCooldown: TimeInterval = 1.0

// Maximum rate limit violations before extended cooldown
private let maxRateLimitCount: Int = 3

// Extended cooldown multiplier (seconds per violation)
let extendedCooldown = TimeInterval(rateLimitCount * 60)
```

### Queue Processing
```swift
// Queue processing thread priority
private let rateLimitQueue = DispatchQueue(label: "com.speedy.ratelimit", qos: .utility)

// Minimum gap between API calls (must be >= 1.0)
Thread.sleep(forTimeInterval: 1.0)
```

## 🚦 Best Practices

### 1. Rate Limit Compliance
- Always respect the 1-second minimum interval
- Use the queue system for rate-limited calls
- Monitor rate limit violations
- Implement progressive penalties

### 2. Queue Management
- Process queues on background threads
- Provide user feedback about queue status
- Handle queue overflow gracefully
- Implement queue cleanup mechanisms

### 3. User Experience
- Show cached data immediately when available
- Provide clear status updates
- Don't block the main thread
- Handle errors gracefully

### 4. Monitoring
- Log all rate limiting events
- Track queue performance
- Monitor API call success rates
- Alert on repeated violations

## 🔮 Future Enhancements

### Planned Features
- **Adaptive Rate Limiting**: Adjust based on API response times
- **Priority Queuing**: Handle high-priority requests first
- **Batch Processing**: Group multiple API calls efficiently
- **Smart Retry Logic**: Intelligent retry mechanisms

### Advanced Queue Management
- **Queue Persistence**: Save queue across app restarts
- **Queue Analytics**: Detailed performance metrics
- **Dynamic Queue Sizing**: Adjust based on device capabilities
- **Queue Optimization**: ML-based queue management

## 🆘 Troubleshooting

### Common Issues
1. **Queue Not Processing**
   - Check if background thread is running
   - Verify queue is not empty
   - Check for processing flags

2. **Rate Limiting Too Aggressive**
   - Verify cooldown values
   - Check for multiple violations
   - Review API call frequency

3. **Queue Overflow**
   - Monitor queue length
   - Implement queue cleanup
   - Check for memory issues

### Debug Commands
```swift
// Check rate limit status
let status = speedLimitService.getRateLimitStatus()

// Clear rate limit queue
speedLimitService.clearRateLimitQueue()

// Force refresh (bypasses cache but respects rate limiting)
speedLimitService.forceRefreshSpeedLimit(for: coordinate)
```

## 📚 Integration Guide

### Adding Rate Limiting to New Services
1. **Import Rate Limiting**: Add rate limiting properties
2. **Implement Queue System**: Add queue management methods
3. **Add Rate Limit Checks**: Check limits before API calls
4. **Handle Queue Processing**: Process queued calls automatically
5. **Monitor Status**: Provide rate limiting status information

### Custom Rate Limiting
```swift
// Custom rate limiting for different APIs
enum APIRateLimit {
    case strict = 1.0      // 1 second (OpenStreetMap)
    case moderate = 2.0    // 2 seconds (other APIs)
    case relaxed = 5.0     // 5 seconds (internal APIs)
}

// Apply custom rate limiting
private func checkCustomRateLimit(for apiType: APIRateLimit) -> Bool {
    // Implementation specific to API type
}
```

This rate limiting system provides robust protection against API violations while maintaining excellent user experience through intelligent queuing and transparent processing.
