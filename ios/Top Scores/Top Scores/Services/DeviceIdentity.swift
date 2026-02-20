import Foundation
import UIKit

enum DeviceIdentity {
    static let headerName = "X-Device-Token"

    private static let fallbackTokenKey = "device.identity.fallbackToken"

    static var currentToken: String {
        if let vendorToken = UIDevice.current.identifierForVendor?.uuidString, !vendorToken.isEmpty {
            return vendorToken
        }

        let defaults = UserDefaults.standard
        if let storedFallback = defaults.string(forKey: fallbackTokenKey), !storedFallback.isEmpty {
            return storedFallback
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: fallbackTokenKey)
        return generated
    }

    static func applyHeader(to request: inout URLRequest) {
        request.setValue(currentToken, forHTTPHeaderField: headerName)
    }
}
