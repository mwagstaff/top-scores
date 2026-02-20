import Foundation
import UIKit

final class TvLogoResolver {
    static let shared = TvLogoResolver()

    private let fallbackName = "_noLogo"
    private var normalizedLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func images(for channels: [String]) -> [UIImage] {
        var results: [UIImage] = []
        var seenFiles = Set<String>()

        for channel in channels {
            guard let url = resolveURL(for: channel) ?? resolveURL(for: fallbackName) else { continue }
            let fileKey = url.deletingPathExtension().lastPathComponent.lowercased()
            if seenFiles.contains(fileKey) { continue }
            seenFiles.insert(fileKey)

            if let image = UIImage(contentsOfFile: url.path) {
                cache[channel] = image
                results.append(image)
            }
        }

        return results
    }

    func image(for channelName: String) -> UIImage? {
        if let cached = cache[channelName] {
            return cached
        }

        let url = resolveURL(for: channelName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }
        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[channelName] = image
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

        if let direct = normalizedLookup[normalized] {
            return direct
        }

        for (keyword, logoKey) in aliasKeywords {
            if normalized.contains(keyword), let url = normalizedLookup[logoKey] {
                return url
            }
        }

        return fuzzyMatch(normalizedChannel: normalized)
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
        ("channel4", "channel4")
    ]
}
