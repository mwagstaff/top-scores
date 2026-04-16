import Foundation
import UIKit

final class WatchTeamLogoResolver {
    static let shared = WatchTeamLogoResolver()

    private let fallbackName = "_noTeamLogo"
    private let bundlesToSearch: [Bundle]
    private var normalizedLookup: [String: URL] = [:]
    private var coreLookup: [String: [URL]] = [:]
    private var originalLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        bundlesToSearch = Self.buildBundlesToSearch()
        loadLogos()
    }

    func image(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        let cacheKey = Self.cacheKey(for: teamName, alternateNames: alternateNames)
        if let cached = cache[cacheKey] {
            return cached
        }

        if let assetImage = resolveAssetImage(for: teamName, alternateNames: alternateNames) ??
            resolveAssetFallbackImage() {
            cache[cacheKey] = assetImage
            return assetImage
        }

        let url = resolveURL(for: teamName, alternateNames: alternateNames) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[cacheKey] = image
        }

        return image
    }

    private func loadLogos() {
        for bundle in bundlesToSearch {
            var urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: "team-logos") ?? []
            if urls.isEmpty {
                urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            }

            for url in urls {
                let fileName = url.deletingPathExtension().lastPathComponent
                let normalized = Self.normalizedKey(fileName)
                normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
                let core = Self.normalizedCoreKey(fileName)
                if !core.isEmpty {
                    coreLookup[core, default: []].append(url)
                }
                originalLookup[fileName.lowercased()] = originalLookup[fileName.lowercased()] ?? url
            }
        }
    }

    private static func buildBundlesToSearch() -> [Bundle] {
        var output: [Bundle] = []
        var seenURLs = Set<URL>()

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            output.append(bundle)
        }

        return output
    }

    private func resolveAssetImage(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        for candidate in assetNameCandidates(for: teamName, alternateNames: alternateNames) {
            if let image = UIImage(named: candidate) {
                return image
            }
        }

        return nil
    }

    private func resolveAssetFallbackImage() -> UIImage? {
        for candidate in [fallbackName, "\(fallbackName) 1"] {
            if let image = UIImage(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func assetNameCandidates(for teamName: String, alternateNames: [String] = []) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        for rawCandidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            add(rawCandidate)
            add(rawCandidate.replacingOccurrences(of: "’", with: "'"))
            add(rawCandidate.replacingOccurrences(of: "'", with: ""))

            let lowered = rawCandidate.lowercased()
            if let alias = Self.aliasMap[lowered] {
                add(alias)
                add(Self.displayName(forAlias: alias))
            }

            for (fullName, alias) in Self.aliasMap where alias == lowered {
                add(fullName)
                add(Self.displayName(forAlias: fullName))
            }
        }

        return candidates
    }

    private static func displayName(forAlias alias: String) -> String {
        alias
            .split(separator: " ")
            .map { token in
                switch token {
                case "fc":
                    return "FC"
                case "ac":
                    return "AC"
                case "sv":
                    return "SV"
                case "vfl":
                    return "VfL"
                case "vfb":
                    return "VfB"
                case "paok":
                    return "PAOK"
                case "psv":
                    return "PSV"
                default:
                    return token.prefix(1).uppercased() + String(token.dropFirst())
                }
            }
            .joined(separator: " ")
    }

    private func resolveURL(for teamName: String, alternateNames: [String] = []) -> URL? {
        var fuzzyCandidates: [String] = []

        for candidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            let lower = candidate.lowercased()
            if let direct = originalLookup[lower] {
                return direct
            }

            for alias in Self.aliases(for: candidate) {
                let aliasKey = Self.normalizedKey(alias)
                if let match = normalizedLookup[aliasKey] {
                    return match
                }
            }

            let normalized = Self.normalizedKey(candidate)
            if let match = normalizedLookup[normalized] {
                return match
            }

            let core = Self.normalizedCoreKey(candidate)
            if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
                return uniqueCoreMatch
            }

            fuzzyCandidates.append(normalized)
        }

        for normalized in fuzzyCandidates {
            if let match = fuzzyMatch(normalizedTeam: normalized) {
                return match
            }
        }

        return nil
    }

    private func uniqueCoreMatch(for coreKey: String) -> URL? {
        guard !coreKey.isEmpty else { return nil }
        guard let candidates = coreLookup[coreKey], !candidates.isEmpty else { return nil }

        var seenPaths = Set<String>()
        let unique = candidates.filter { seenPaths.insert($0.path).inserted }
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func fuzzyMatch(normalizedTeam: String) -> URL? {
        guard !normalizedTeam.isEmpty else { return nil }

        var bestKey: String?
        var bestScore = 0.0

        for key in normalizedLookup.keys {
            let score = Self.similarity(normalizedTeam, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.78 {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private nonisolated static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private nonisolated static func normalizedCoreKey(_ value: String) -> String {
        normalizedTokens(value, stripClubAffixes: true).joined()
    }

    private nonisolated static func normalizedTokens(_ value: String, stripClubAffixes: Bool = false) -> [String] {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { token in
                if stopWords.contains(token) {
                    return false
                }
                if stripClubAffixes, clubAffixWords.contains(token) {
                    return false
                }
                return true
            }
    }

    private static func aliases(for name: String) -> [String] {
        let lowered = name.lowercased()
        if let alias = aliasMap[lowered] {
            return [alias, lowered]
        }
        return [lowered]
    }

    private static func lookupCandidates(for teamName: String, alternateNames: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            output.append(trimmed)
        }

        add(teamName)
        alternateNames.forEach(add)
        return output
    }

    private static func cacheKey(for teamName: String, alternateNames: [String]) -> String {
        lookupCandidates(for: teamName, alternateNames: alternateNames)
            .map(normalizedKey)
            .joined(separator: "|")
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

    private nonisolated static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private nonisolated static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

    private static let aliasMap: [String: String] = [
        "manchester united": "man united",
        "manchester city": "man city",
        "tottenham hotspur": "tottenham",
        "wolverhampton wanderers": "wolves",
        "sheffield united": "sheff utd",
        "sheffield wednesday": "sheff wed",
        "nottingham forest": "nottm forest",
        "borussia dortmund": "dortmund",
        "borussia m'gladbach": "m'gladbach",
        "athletic club": "athletic",
        "real betis": "betis",
        "real sociedad": "real sociedad",
        "fc copenhagen": "copenhagen",
        "fc porto": "porto",
        "paok thessaloniki": "paok",
        "paok thessaloniki fc": "paok",
        "inter milan": "inter",
        "ac milan": "ac milan"
    ]
}

final class WatchTvLogoResolver {
    static let shared = WatchTvLogoResolver()

    private let fallbackName = "_noLogo"
    private let bundlesToSearch: [Bundle]
    private var normalizedLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        bundlesToSearch = Self.buildBundlesToSearch()
        loadLogos()
    }

    func image(for channelName: String) -> UIImage? {
        if let cached = cache[channelName] {
            return cached
        }

        if let assetImage = resolveAssetImage(for: channelName) ?? resolveAssetFallbackImage() {
            cache[channelName] = assetImage
            return assetImage
        }

        let url = resolveURL(for: channelName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[channelName] = image
        }

        return image
    }

    func images(for channels: [String]) -> [UIImage] {
        var output: [UIImage] = []
        var seenChannels = Set<String>()

        for channel in channels {
            let dedupeKey = Self.normalizedKey(channel)
            guard !seenChannels.contains(dedupeKey) else { continue }
            guard let image = image(for: channel) else { continue }
            seenChannels.insert(dedupeKey)
            output.append(image)
        }

        return output
    }

    private func loadLogos() {
        for bundle in bundlesToSearch {
            var urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: "tv-logos") ?? []
            if urls.isEmpty {
                urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            }

            for url in urls {
                let fileName = url.deletingPathExtension().lastPathComponent
                let normalized = Self.normalizedKey(fileName)
                normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
            }
        }
    }

    private static func buildBundlesToSearch() -> [Bundle] {
        var output: [Bundle] = []
        var seenURLs = Set<URL>()

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            output.append(bundle)
        }

        return output
    }

    private func resolveAssetImage(for channelName: String) -> UIImage? {
        for candidate in assetNameCandidates(for: channelName) {
            if let image = UIImage(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func resolveAssetFallbackImage() -> UIImage? {
        for candidate in [fallbackName, "\(fallbackName) 1"] {
            if let image = UIImage(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func assetNameCandidates(for channelName: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        add(channelName)

        let normalized = Self.normalizedKey(channelName)
        for (keyword, logoKey) in aliasKeywords where normalized.contains(keyword) {
            add(logoKey)
            add(logoKey.uppercased())
            add(logoKey.capitalized)
        }

        return candidates
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
        var bestScore = 0.0

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
