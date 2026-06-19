
import Foundation

struct CachedSpeedLimit: Codable {
    let speedLimit: Int
    let timestamp: Date
}

class SpeedLimitCache {
    static let shared = SpeedLimitCache()
    private let cache = NSCache<NSString, NSData>()
    private let userDefaults = UserDefaults.standard
    private let cacheKey = "speedLimitCache"

    private var keys = [NSString]()

    private init() {
        loadCacheFromUserDefaults()
    }

    func set(speedLimit: Int, for key: String) {
        let cachedItem = CachedSpeedLimit(speedLimit: speedLimit, timestamp: Date())
        if let data = try? JSONEncoder().encode(cachedItem) {
            cache.setObject(data as NSData, forKey: key as NSString)
            if !keys.contains(key as NSString) {
                keys.append(key as NSString)
            }
            saveCacheToUserDefaults()
        }
    }

    func get(for key: String) -> Int? {
        if let data = cache.object(forKey: key as NSString) as Data?,
           let cachedItem = try? JSONDecoder().decode(CachedSpeedLimit.self, from: data) {
            // Cache is valid for 24 hours
            if Date().timeIntervalSince(cachedItem.timestamp) < 24 * 60 * 60 {
                return cachedItem.speedLimit
            }
        }
        return nil
    }

    private func saveCacheToUserDefaults() {
        var dictionary: [String: Data] = [:]
        for key in keys {
            if let data = self.cache.object(forKey: key) {
                dictionary[key as String] = data as Data
            }
        }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: false)
        userDefaults.set(data, forKey: cacheKey)
    }

    private func loadCacheFromUserDefaults() {
        guard let data = userDefaults.data(forKey: cacheKey),
              let dictionary = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: data) as? [String: Data] else {
            return
        }

        for (key, value) in dictionary {
            self.cache.setObject(value as NSData, forKey: key as NSString)
            if !keys.contains(key as NSString) {
                keys.append(key as NSString)
            }
        }
    }
}
