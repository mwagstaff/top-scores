import Foundation
import UIKit
import UserNotifications
import Combine

enum NotificationTestError: LocalizedError {
    case invalidAPIBaseURL
    case notificationsNotAuthorized
    case missingAPNSToken
    case requestFailed(statusCode: Int, message: String)
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .invalidAPIBaseURL:
            return "Invalid API base URL."
        case .notificationsNotAuthorized:
            return "Notifications are not authorized on this device."
        case .missingAPNSToken:
            return "APNS token is unavailable. Ensure remote notification registration succeeded."
        case let .requestFailed(statusCode, message):
            return "Test notification request failed (\(statusCode)): \(message)"
        case .invalidServerResponse:
            return "Invalid server response while sending test notification."
        }
    }
}

struct NotificationTestSendResult {
    let environment: String?
    let sentCount: Int?
    let usedStoredAPNSToken: Bool
}

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var apnsDeviceToken: String?

    private let userDefaults = UserDefaults.standard
    private let apnsTokenKey = "apns.deviceToken"

    private override init() {
        super.init()
        // Load saved token
        apnsDeviceToken = userDefaults.string(forKey: apnsTokenKey)

        // Check current authorization status
        Task {
            await checkAuthorizationStatus()
        }
    }

    /// Request authorization for notifications
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await checkAuthorizationStatus()

            if granted {
                NSLog("[NotificationManager] Notification permission granted")
                // Register for remote notifications on the main thread
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                NSLog("[NotificationManager] Notification permission denied")
            }
        } catch {
            NSLog("[NotificationManager] Error requesting authorization: %@", error.localizedDescription)
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        // If authorized but no token yet, register
        if settings.authorizationStatus == .authorized && apnsDeviceToken == nil {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Update the APNS device token
    func updateDeviceToken(_ token: String) async {
        apnsDeviceToken = token
        userDefaults.set(token, forKey: apnsTokenKey)

        NSLog("[NotificationManager] APNS token updated and saved")

        // Trigger preferences sync to send token to server
        let snapshot = PreferencesStore.loadSnapshot()
        await PreferencesSyncService.shared.syncPreferences(snapshot)
    }

    /// Get the current APNS token if available
    var currentAPNSToken: String? {
        apnsDeviceToken
    }

    /// Check if the current build is a development build
    var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        // Check if the app is running with a development provisioning profile
        // Development builds will have an embedded.mobileprovision file
        guard let provisioningPath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return false
        }
        return FileManager.default.fileExists(atPath: provisioningPath)
        #endif
    }

    /// Ask the API server to send a test push notification to this device.
    func sendTestNotification(apiBaseURL: String) async throws -> NotificationTestSendResult {
        await checkAuthorizationStatus()
        let allowedStatuses: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        guard allowedStatuses.contains(authorizationStatus) else {
            throw NotificationTestError.notificationsNotAuthorized
        }

        guard let apnsToken = apnsDeviceToken, !apnsToken.isEmpty else {
            throw NotificationTestError.missingAPNSToken
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            throw NotificationTestError.invalidAPIBaseURL
        }

        let endpoint = baseURL
            .appendingPathComponent("notifications")
            .appendingPathComponent("test")

        let userDeviceToken = DeviceIdentity.currentToken
        let sentAt = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = [
            "userDeviceToken": userDeviceToken,
            "apnsToken": apnsToken,
            "isDevelopmentBuild": isDevelopmentBuild,
            "title": "Top Scores Test",
            "body": "Test push from Preferences at \(sentAt)"
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotificationTestError.invalidServerResponse
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NotificationTestError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: bodyText.isEmpty ? "No response body" : bodyText
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let success = json["success"] as? Bool ?? false
            if !success {
                let message = (json["error"] as? String) ?? (json["message"] as? String) ?? "Unknown error"
                throw NotificationTestError.requestFailed(statusCode: httpResponse.statusCode, message: message)
            }

            return NotificationTestSendResult(
                environment: json["environment"] as? String,
                sentCount: json["sent"] as? Int,
                usedStoredAPNSToken: json["usedStoredAPNSToken"] as? Bool ?? false
            )
        }

        return NotificationTestSendResult(
            environment: nil,
            sentCount: nil,
            usedStoredAPNSToken: false
        )
    }
}
