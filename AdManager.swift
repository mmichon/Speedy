import Foundation
import SwiftUI

final class AdManager: NSObject, ObservableObject {
    static let shared = AdManager()

    @AppStorage("adsEnabled") private var adsEnabled: Bool = false

    // Track Mobile Ads SDK initialization to avoid premature requests
    private var isInitialized: Bool = false
    private var initializationCallbacks: [() -> Void] = []

    private override init() {}

    func start() {
#if canImport(GoogleMobileAds)
        guard adsEnabled else { return }
        // Configure test device from console hint if available
        MobileAds.shared.requestConfiguration.testDeviceIdentifiers = [
            "7a57090503b0d37a0059c850c55ce94a"
        ]
        let appID = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String ?? "<missing>"
        print("[INFO] AdManager: Starting MobileAds. AppID=\(appID)")
        MobileAds.shared.start { status in
            print("[INFO] AdManager: MobileAds started. Ad SDK status: \(status.adapterStatusesByClassName.keys.count) adapters")
            self.isInitialized = true
            let callbacks = self.initializationCallbacks
            self.initializationCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
#endif
    }

    func whenInitialized(_ block: @escaping () -> Void) {
#if canImport(GoogleMobileAds)
        if isInitialized {
            block()
        } else {
            initializationCallbacks.append(block)
        }
#else
        block()
#endif
    }
}

#if canImport(GoogleMobileAds)
import GoogleMobileAds

struct BannerAdView: UIViewRepresentable {
    let adUnitId: String
    let availableWidth: CGFloat

    func makeUIView(context: Context) -> BannerView {
        let width = availableWidth
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitId
        banner.delegate = context.coordinator
        print("[INFO] AdManager: Preparing banner. unit=\(adUnitId) width=\(width) size=\(AdSizeBanner.size)")
        // Defer rootViewController lookup to next runloop to ensure window exists
        func attemptLoad(retry: Int) {
            let rootVC = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?
                .rootViewController
            if let rootVC {
                banner.rootViewController = rootVC
                print("[INFO] AdManager: Loading banner with rootVC present. retry=\(retry)")
                // Request standard 320x50 banner
                banner.adSize = AdSizeBanner
                banner.load(Request())
            } else if retry < 3 {
                let delay = Double(retry + 1) * 0.2
                print("[WARN] AdManager: rootVC nil, retrying in \(delay)s (attempt \(retry+1))")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    attemptLoad(retry: retry + 1)
                }
            } else {
                print("[ERROR] AdManager: Failed to obtain rootVC after retries; banner not loaded")
            }
        }
        DispatchQueue.main.async {
            AdManager.shared.whenInitialized {
                attemptLoad(retry: 0)
            }
        }
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        // No-op for standard banner; size remains 320x50
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            print("[INFO] AdManager: Banner loaded successfully")
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            let nsError = error as NSError
            print("[ERROR] AdManager: Banner failed to load: code=\(nsError.code) domain=\(nsError.domain) userInfo=\(nsError.userInfo) desc=\(nsError.localizedDescription)")
            // Retry once with a fresh standard request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                print("[WARN] AdManager: Retrying with standard size 320x50")
                bannerView.adSize = AdSizeBanner
                bannerView.load(Request())
            }
        }
    }
}
#else
struct BannerAdView: View {
    let adUnitId: String
    var body: some View { EmptyView() }
}
#endif
