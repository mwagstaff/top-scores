import Foundation
import UIKit
import Darwin

actor AppMetricsService {
    static let shared = AppMetricsService()

    private init() {}

    // MARK: - Public API (fire-and-forget)

    /// Record that the user navigated to a screen. Call from onAppear or when a tab becomes selected.
    /// durationMs: time from screen open until data was ready (nil = not measured / instant).
    nonisolated func fireScreenView(screen: String, durationMs: Int? = nil, apiBaseURL: String) {
        Task(priority: .utility) {
            await sendEvent(event: "screen_view", screen: screen, durationMs: durationMs, apiBaseURL: apiBaseURL)
        }
    }

    /// Record a user activity (preference toggle, manual refresh, search, etc.).
    /// activity: snake_case name, e.g. "preference_toggle", "manual_refresh".
    /// screen: the screen where it happened.
    /// durationMs: how long the activity took (nil = instant / not measured).
    nonisolated func fireActivity(_ activity: String, screen: String, durationMs: Int? = nil, apiBaseURL: String) {
        Task(priority: .utility) {
            await sendEvent(event: activity, screen: screen, durationMs: durationMs, apiBaseURL: apiBaseURL)
        }
    }

    // MARK: - Existing API

    func sendAppOpenMetric(apiBaseURL: String) async {
        await sendEvent(event: "app_open", screen: nil, durationMs: nil, apiBaseURL: apiBaseURL)
    }

    // MARK: - Core

    private func sendEvent(event: String, screen: String?, durationMs: Int?, apiBaseURL: String) async {
        guard let baseURL = URL(string: apiBaseURL) else {
            NSLog("[AppMetrics] Invalid API base URL: %@", apiBaseURL)
            return
        }

        let endpoint = baseURL.appendingPathComponent("app-metrics")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        DeviceIdentity.applyHeader(to: &request)

        let payload = await buildPayload(event: event, screen: screen, durationMs: durationMs)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[AppMetrics] Invalid response type for event=%@", event)
                return
            }
            if !(200...299).contains(httpResponse.statusCode) {
                NSLog("[AppMetrics] HTTP %d for event=%@ screen=%@", httpResponse.statusCode, event, screen ?? "-")
            }
        } catch {
            NSLog("[AppMetrics] Error sending event=%@ error=%@", event, error.localizedDescription)
        }
    }

    private func buildPayload(event: String, screen: String?, durationMs: Int?) async -> [String: Any] {
        await MainActor.run {
            let device = UIDevice.current
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let buildType: String
            #if DEBUG
            buildType = "debug"
            #else
            buildType = "production"
            #endif

            var payload: [String: Any] = [
                "event": event,
                "platform": device.systemName,
                "osVersion": device.systemVersion,
                "deviceType": Self.idiomName(device.userInterfaceIdiom),
                "deviceModel": Self.resolvedModelName(),
                "appVersion": version,
                "buildNumber": build,
                "buildType": buildType,
                "locale": Locale.current.identifier,
                "timezone": TimeZone.current.identifier,
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if let screen {
                payload["screen"] = screen
            }
            if let durationMs {
                payload["durationMs"] = durationMs
            }
            return payload
        }
    }

    private static func idiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone:
            return "phone"
        case .pad:
            return "pad"
        case .tv:
            return "tv"
        case .mac:
            return "mac"
        case .vision:
            return "vision"
        default:
            return "unspecified"
        }
    }

    /// Returns the human-readable device model name (e.g. "iPhone 16 Pro Max").
    /// Falls back to the raw hardware identifier (e.g. "iPhone17,2") for unrecognised models.
    private static func resolvedModelName() -> String {
        let identifier = hardwareIdentifier()
        return modelNames[identifier] ?? identifier
    }

    private static func hardwareIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawPtr in
            let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        #endif
    }

    // swiftlint:disable:next large_tuple
    private static let modelNames: [String: String] = [
        // iPhone 12
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        // iPhone SE
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
        // iPhone 14
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        // iPad mini
        "iPad11,1": "iPad mini 5",
        "iPad11,2": "iPad mini 5",
        "iPad14,1": "iPad mini 6",
        "iPad14,2": "iPad mini 6",
        "iPad14,7": "iPad mini 7",
        "iPad14,8": "iPad mini 7",
        // iPad Air
        "iPad13,16": "iPad Air 5",
        "iPad13,17": "iPad Air 5",
        "iPad14,9":  "iPad Air M2 11\"",
        "iPad14,10": "iPad Air M2 11\"",
        "iPad14,11": "iPad Air M2 13\"",
        "iPad14,12": "iPad Air M2 13\"",
        // iPad Pro
        "iPad14,3":  "iPad Pro 11\" M2",
        "iPad14,4":  "iPad Pro 11\" M2",
        "iPad14,5":  "iPad Pro 12.9\" M2",
        "iPad14,6":  "iPad Pro 12.9\" M2",
        "iPad16,3":  "iPad Pro 11\" M4",
        "iPad16,4":  "iPad Pro 11\" M4",
        "iPad16,5":  "iPad Pro 13\" M4",
        "iPad16,6":  "iPad Pro 13\" M4",
        // iPad
        "iPad13,18": "iPad 10",
        "iPad13,19": "iPad 10",
    ]
}
