import Foundation

enum DeviceIdentity {
    nonisolated static let activity = AppActivityContext()

    nonisolated static let headerName = "X-Device-Token"

    private nonisolated static let identityLock = NSLock()
    private nonisolated static let fallbackTokenKey = "device.identity.fallbackToken"

    nonisolated static var currentToken: String {
        identityLock.withLock {
            let defaults = UserDefaults.standard
            if let storedFallback = defaults.string(forKey: fallbackTokenKey), !storedFallback.isEmpty {
                return storedFallback
            }

            let generated = UUID().uuidString
            defaults.set(generated, forKey: fallbackTokenKey)
            return generated
        }
    }

    nonisolated static func applyHeader(to request: inout URLRequest) {
        request.setValue(currentToken, forHTTPHeaderField: headerName)
        request.setValue("ios_app", forHTTPHeaderField: "X-Client-Surface")
        request.setValue(activity.snapshot.state, forHTTPHeaderField: "X-Client-State")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", forHTTPHeaderField: "X-App-Version")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", forHTTPHeaderField: "X-App-Build")
        #if DEBUG
        request.setValue("debug", forHTTPHeaderField: "X-Build-Type")
        #else
        request.setValue("production", forHTTPHeaderField: "X-Build-Type")
        #endif
    }
}

// Networking reads this from multiple actors; lifecycle writes happen on the main actor.
nonisolated final class AppActivityContext: @unchecked Sendable {
    struct Snapshot: Sendable { let state: String }
    private let lock = NSLock()
    private var foreground = false
    private var hasSession = false

    var snapshot: Snapshot {
        lock.withLock { Snapshot(state: foreground ? "foreground" : "background") }
    }

    /// Inactive interruptions preserve the session; only background ends it.
    func update(active: Bool, background: Bool) -> Bool {
        lock.withLock {
            foreground = active
            if background { hasSession = false }
            guard active, !hasSession else { return false }
            hasSession = true
            return true
        }
    }
}
