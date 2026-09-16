import Foundation
import ImageIO
import Observation
import UIKit

@MainActor @Observable
final class WatchFantasyImageLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private(set) var image: UIImage?
    private var requestedURL: URL?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) {
        self.fetch = fetch
    }

    static func normalizedURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let resolved = value.hasPrefix("//") ? "https:\(value)" : value
        guard let url = URL(string: resolved, relativeTo: URL(string: "https://fantasy.premierleague.com"))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    func load(urlString: String?) async {
        let url = Self.normalizedURL(urlString)
        if requestedURL == url, image != nil { return }
        requestedURL = url
        image = nil
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                guard requestedURL == url else { return }
                var request = URLRequest(url: url, timeoutInterval: 12)
                request.cachePolicy = attempt == 0 ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData
                let (data, response) = try await fetch(request)
                guard let http = response as? HTTPURLResponse else { return }
                if !(200...299).contains(http.statusCode) {
                    guard Self.isRetryable(status: http.statusCode), attempt < 2 else { return }
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 900))
                    continue
                }
                let decoded = await Task.detached(priority: .utility) {
                    Self.decode(data)
                }.value
                try Task.checkCancellation()
                guard requestedURL == url, let decoded else { return }
                Self.cache.setObject(decoded, forKey: url as NSURL, cost: 80 * 80 * 4)
                image = decoded
                return
            } catch {
                guard !Task.isCancelled, Self.isRetryable(error: error), attempt < 2 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 900))
                } catch { return }
            }
        }
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(error.code)
    }

    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 80,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
