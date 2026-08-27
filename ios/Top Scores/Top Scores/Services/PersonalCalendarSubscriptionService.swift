import Foundation
import Security

enum PersonalCalendarSubscriptionError: LocalizedError {
    case tokenUnavailable
    case invalidSubscriptionURL

    var errorDescription: String? {
        switch self {
        case .tokenUnavailable:
            return "Top Scores could not create a secure calendar link."
        case .invalidSubscriptionURL:
            return "Top Scores received an invalid calendar subscription address."
        }
    }
}

enum PersonalCalendarSubscriptionService {
    static func provision(preferences: PreferencesSnapshot) async throws -> URL {
        let calendarToken = try CalendarSubscriptionTokenStore.currentToken()
        let feedURL = try await PreferencesSyncService.shared.registerCalendarSubscription(
            preferences,
            calendarToken: calendarToken
        )
        guard let subscriptionURL = webcalURL(from: feedURL) else {
            throw PersonalCalendarSubscriptionError.invalidSubscriptionURL
        }
        return subscriptionURL
    }

    nonisolated static func webcalURL(from feedURL: URL) -> URL? {
        guard var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false),
              components.scheme == "https" || components.scheme == "http" else {
            return nil
        }
        components.scheme = "webcal"
        return components.url
    }
}

private enum CalendarSubscriptionTokenStore {
    private static let service = "dev.skynolimit.topscores.personal-calendar"
    private static var account: String {
        "subscription-token-\(DeviceIdentity.currentToken)"
    }

    static func currentToken() throws -> String {
        if let existing = storedToken() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw PersonalCalendarSubscriptionError.tokenUnavailable
        }
        let token = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard token.count == 43 else {
            throw PersonalCalendarSubscriptionError.tokenUnavailable
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = storedToken() {
            return existing
        }
        guard status == errSecSuccess else {
            throw PersonalCalendarSubscriptionError.tokenUnavailable
        }
        return token
    }

    private static func storedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              token.count == 43 else {
            return nil
        }
        return token
    }
}
