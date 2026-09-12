import Foundation
import UIKit

nonisolated final class TvLogoResolver: @unchecked Sendable {
    static let shared = TvLogoResolver()

    private let fallbackName = "_noLogo"
    private var normalizedLookup: [String: URL] = [:]
    private var expandedLookup: [String: URL] = [:]
    private var expandedDarkLookup: [String: URL] = [:]
    private var resolvedURLCache: [String: URL] = [:]
    private var unresolvedChannelKeys: Set<String> = []
    private let resolutionLock = NSLock()
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()
    private let displayImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    private init() {
        loadLogos()
    }

    func images(for channels: [String]) -> [UIImage] {
        var results: [UIImage] = []
        var seenFiles = Set<String>()

        for channel in channels {
            let displayKey = Self.normalizedKey(channel) as NSString
            if let cached = displayImageCache.object(forKey: displayKey) {
                let imageKey = "cached:\(ObjectIdentifier(cached))"
                guard seenFiles.insert(imageKey).inserted else { continue }
                results.append(cached)
                continue
            }
            guard let url = resolutionLock.withLock({
                resolveURL(for: channel) ?? resolveURL(for: fallbackName)
            }) else { continue }
            let fileKey = url.path
            if seenFiles.contains(fileKey) { continue }
            seenFiles.insert(fileKey)

            let cacheKey = fileKey as NSString
            if let cached = imageCache.object(forKey: cacheKey) {
                displayImageCache.setObject(cached, forKey: displayKey)
                results.append(cached)
                continue
            }

            if let image = UIImage(contentsOfFile: url.path) {
                imageCache.setObject(image, forKey: cacheKey)
                displayImageCache.setObject(image, forKey: displayKey)
                results.append(image)
            }
        }

        return results
    }

    func image(for channelName: String) -> UIImage? {
        let displayKey = Self.normalizedKey(channelName) as NSString
        if let cached = displayImageCache.object(forKey: displayKey) {
            return cached
        }
        let url = resolutionLock.withLock {
            resolveURL(for: channelName) ?? resolveURL(for: fallbackName)
        }
        guard let url else { return nil }

        let cacheKey = url.path as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            displayImageCache.setObject(cached, forKey: displayKey)
            return cached
        }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
            displayImageCache.setObject(image, forKey: displayKey)
        }
        return image
    }

    func prepareImagesForDisplay(for channelNames: [String]) {
        let uniqueChannelNames = Set(channelNames)
        guard !uniqueChannelNames.isEmpty else { return }

        ArtworkDisplayPreparationQueue.shared.async { [weak self, uniqueChannelNames] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            var preparedCount = 0
            for channelName in uniqueChannelNames {
                autoreleasepool {
                    InteractiveMotionGate.shared.waitUntilIdleBlocking(
                        operation: "fixture_tv_artwork"
                    )
                    let url = self.resolutionLock.withLock {
                        self.resolveURL(for: channelName) ??
                            self.resolveURL(for: self.fallbackName)
                    }
                    guard let url else { return }
                    let cacheKey = url.path as NSString
                    let sourceImage = self.imageCache.object(forKey: cacheKey) ??
                        UIImage(contentsOfFile: url.path)
                    guard let sourceImage else { return }
                    let preparedImage = sourceImage.preparingForDisplay() ?? sourceImage
                    self.imageCache.setObject(preparedImage, forKey: cacheKey)
                    self.displayImageCache.setObject(
                        preparedImage,
                        forKey: Self.normalizedKey(channelName) as NSString
                    )
                    preparedCount += 1
                }
            }
            let durationMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            if durationMilliseconds >= 25 {
                diagnosticLogAsync(
                    "[FixtureArtwork] tv_batch entries=\(uniqueChannelNames.count) " +
                    "prepared=\(preparedCount) duration_ms=\(durationMilliseconds)"
                )
            }
        }
    }

    func expandedImage(for channelName: String, isDarkAppearance: Bool = false) -> UIImage? {
        let normalized = Self.normalizedKey(channelName)
        guard !normalized.isEmpty, normalized != Self.normalizedKey(fallbackName) else { return nil }

        // Unsupported broadcasters keep their text label instead of a guessed or placeholder logo.
        let url = resolutionLock.withLock { () -> URL? in
            let logoKey = normalizedLookup[normalized] != nil
                ? normalized
                : aliasKeywords.first(where: { normalized.hasPrefix($0.0) })?.1
            guard let logoKey else { return nil }
            let appearanceURL = isDarkAppearance ? expandedDarkLookup[logoKey] : nil
            return appearanceURL ?? expandedLookup[logoKey] ?? normalizedLookup[logoKey]
        }
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
            if fileName.hasSuffix("-expanded-dark") {
                // Sky: https://images.contentstack.io/v3/assets/blt4b099fa9cc3801a6/blt02516ad9c7874bcd/Sky-sports-secondary-rgb.png
                // TNT: https://static.skyassets.com/contentstack/assets/blt143e20b03d72047e/bltead549f1f9759dfb/64ad3670ce1ee5c9828fcfb5/TNT_logo_400x120.png
                let baseName = String(fileName.dropLast("-expanded-dark".count))
                expandedDarkLookup[Self.normalizedKey(baseName)] = url
                continue
            }
            if fileName.hasSuffix("-expanded") {
                // Official horizontal marks: e0.365dm.com/tvlogos/channels/Sky-Sports-Logo.png
                // TNT: https://www.bt.com/sport/assets/images/partners/TNT-Sports.webp (converted to PNG).
                let baseName = String(fileName.dropLast("-expanded".count))
                expandedLookup[Self.normalizedKey(baseName)] = url
                continue
            }
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
