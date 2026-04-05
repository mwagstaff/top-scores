import Foundation
import UIKit

actor AppMetricsService {
    static let shared = AppMetricsService()

    private init() {}

    func sendAppOpenMetric(apiBaseURL: String) async {
        guard let baseURL = URL(string: apiBaseURL) else {
            NSLog("[AppMetrics] Invalid API base URL: %@", apiBaseURL)
            return
        }

        let endpoint = baseURL.appendingPathComponent("app-metrics")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        let payload = await buildPayload()

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[AppMetrics] Invalid response type")
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                NSLog("[AppMetrics] App open metric sent")
            } else {
                NSLog("[AppMetrics] Failed to send app open metric: HTTP %d", httpResponse.statusCode)
            }
        } catch {
            NSLog("[AppMetrics] Error sending app open metric: %@", error.localizedDescription)
        }
    }

    private func buildPayload() async -> [String: Any] {
        await MainActor.run {
            let device = UIDevice.current
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

            return [
                "event": "app_open",
                "platform": device.systemName,
                "osVersion": device.systemVersion,
                "deviceType": Self.idiomName(device.userInterfaceIdiom),
                "deviceModel": device.model,
                "appVersion": version,
                "buildNumber": build,
                "locale": Locale.current.identifier,
                "timezone": TimeZone.current.identifier,
                "isLowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
            ]
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
}
