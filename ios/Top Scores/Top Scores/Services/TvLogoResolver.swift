import Foundation
import UIKit

final class TvLogoResolver {
    static let shared = TvLogoResolver()

    private let fallbackName = "_noLogo"
    private var normalizedLookup: [String: URL] = [:]
    private var resolvedURLCache: [String: URL] = [:]
    private var unresolvedChannelKeys: Set<String> = []
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private init() {
        loadLogos()
    }

    func images(for channels: [String]) -> [UIImage] {
        var results: [UIImage] = []
        var seenFiles = Set<String>()

        for channel in channels {
            guard let url = resolveURL(for: channel) ?? resolveURL(for: fallbackName) else { continue }
            let fileKey = url.path
            if seenFiles.contains(fileKey) { continue }
            seenFiles.insert(fileKey)

            let cacheKey = fileKey as NSString
            if let cached = imageCache.object(forKey: cacheKey) {
                results.append(cached)
                continue
            }

            if let image = UIImage(contentsOfFile: url.path) {
                imageCache.setObject(image, forKey: cacheKey)
                results.append(image)
            }
        }

        return results
    }

    func image(for channelName: String) -> UIImage? {
        let url = resolveURL(for: channelName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let cacheKey = url.path as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    private func loadLogos() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "tv-logos") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        }
        for url in urls {
            let fileName = url.deletingPathExtension().lastPathComponent
            let normalized = Self.normalizedKey(fileName)
            normalizedLookup[normalized] = url
        }
    }

    private func resolveURL(for channelName: String) -> URL? {
        let normalized = Self.normalizedKey(channelName)
        guard !normalized.isEmpty else { return nil }

        if let cached = resolvedURLCache[normalized] {
            return cached
        }
        if unresolvedChannelKeys.contains(normalized) {
            return nil
        }

        if let direct = normalizedLookup[normalized] {
            resolvedURLCache[normalized] = direct
            return direct
        }

        for (keyword, logoKey) in aliasKeywords {
            if normalized.contains(keyword), let url = normalizedLookup[logoKey] {
                resolvedURLCache[normalized] = url
                return url
            }
        }
        if let fuzzyMatch = fuzzyMatch(normalizedChannel: normalized) {
            resolvedURLCache[normalized] = fuzzyMatch
            return fuzzyMatch
        }

        unresolvedChannelKeys.insert(normalized)
        return nil
    }

    private func fuzzyMatch(normalizedChannel: String) -> URL? {
        guard !normalizedChannel.isEmpty else { return nil }

        var bestKey: String?
        var bestScore: Double = 0

        for key in normalizedLookup.keys {
            let score = Self.similarity(normalizedChannel, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.72 {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private static func normalizedKey(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")

        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }

        return tokens.joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let distance = levenshtein(lhs, rhs)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        var previous = Array(0...rhsChars.count)
        var current = Array(repeating: 0, count: rhsChars.count + 1)

        for (i, lhsChar) in lhsChars.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsChars.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }

    private let aliasKeywords: [(String, String)] = [
        ("skysports", "sky"),
        ("sky", "sky"),
        ("tntsports", "tnt"),
        ("tnt", "tnt"),
        ("bt", "tnt"),
        ("amazonprime", "amazon"),
        ("primevideo", "amazon"),
        ("amazon", "amazon"),
        ("apple", "apple"),
        ("mlsseasonpass", "apple"),
        ("bbc", "bbc"),
        ("itv", "itv"),
        ("channel4", "channel4"),
        ("hbomax", "hbomax"),
        ("hbo", "hbomax"),
        ("dazn", "dazn"),
        ("disneyplus", "disneyplus"),
        ("disney", "disneyplus"),
        ("nowtv", "now"),
        ("premiersports", "premiersports"),
        ("laligatv", "laligatv"),
        ("laliga", "laligatv")
    ]
}
