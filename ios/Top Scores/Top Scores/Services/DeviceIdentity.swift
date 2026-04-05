import Foundation

enum DeviceIdentity {
    nonisolated static let headerName = "X-Device-Token"

    private nonisolated static let fallbackTokenKey = "device.identity.fallbackToken"

    nonisolated static var currentToken: String {
        let defaults = UserDefaults.standard
        if let storedFallback = defaults.string(forKey: fallbackTokenKey), !storedFallback.isEmpty {
            return storedFallback
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: fallbackTokenKey)
        return generated
    }

    nonisolated static func applyHeader(to request: inout URLRequest) {
        request.setValue(currentToken, forHTTPHeaderField: headerName)
    }
}
