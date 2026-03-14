import Foundation
import UIKit

final class LogoResolver {
    static let shared = LogoResolver()

    private enum ImageSource: Hashable {
        case file(URL)
        case asset(String)

        var identifier: String {
            switch self {
            case let .file(url):
                return "file:\(url.path)"
            case let .asset(name):
                return "asset:\(name)"
            }
        }

        var displayName: String {
            switch self {
            case let .file(url):
                return url.deletingPathExtension().lastPathComponent
            case let .asset(name):
                return name
            }
        }
    }

    private let fallbackName = "_noTeamLogo"
    private var normalizedLookup: [String: ImageSource] = [:]
    private var coreLookup: [String: [ImageSource]] = [:]
    private var originalLookup: [String: ImageSource] = [:]
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private var fallbackSource: ImageSource?

    private init() {
        loadLogos()
    }

    func image(for teamName: String) -> UIImage? {
        let source = resolveSource(for: teamName) ?? fallbackSource
        guard let source else { return nil }

        let cacheKey = source.identifier as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let image = image(from: source)
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    func hasDedicatedLogo(for teamName: String) -> Bool {
        guard let resolved = resolveSource(for: teamName) else { return false }
        return !isFallbackSource(resolved)
    }

    func missingTeamNames(in teamNames: [String]) -> [String] {
        var missing: [String] = []
        var seen = Set<String>()

        for rawTeamName in teamNames {
            let normalizedDisplayName = Self.normalizedDisplayName(rawTeamName)
            guard !normalizedDisplayName.isEmpty else { continue }
            let dedupeKey = normalizedDisplayName.lowercased()
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            if !hasDedicatedLogo(for: normalizedDisplayName) {
                missing.append(normalizedDisplayName)
            }
        }

        return missing.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func loadLogos() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "team-logos") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        }
        for url in urls {
            let fileName = url.deletingPathExtension().lastPathComponent
            register(source: .file(url), forName: fileName)
        }

        loadAssetCatalogLogos()

        if fallbackSource == nil {
            fallbackSource = originalLookup[fallbackName.lowercased()]
            if fallbackSource == nil {
                fallbackSource = originalLookup.first(where: { Self.isFallbackName($0.key) })?.value
            }
        }
    }

    private func loadAssetCatalogLogos() {
        guard let manifestURL = Bundle.main.url(forResource: "team_logo_assets", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let assetNames = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }

        for name in assetNames {
            register(source: .asset(name), forName: name)
        }
    }

    private func register(source: ImageSource, forName name: String) {
        let normalized = Self.normalizedKey(name)
        normalizedLookup[normalized] = source

        let core = Self.normalizedCoreKey(name)
        if !core.isEmpty {
            coreLookup[core, default: []].append(source)
        }

        originalLookup[name.lowercased()] = source

        if Self.isFallbackName(name) {
            fallbackSource = source
        }
    }

    private func resolveSource(for teamName: String) -> ImageSource? {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if let direct = originalLookup[lower] {
            return direct
        }

        if let directAsset = directAssetSource(for: trimmed) {
            return directAsset
        }

        for alias in Self.aliases(for: trimmed) {
            if let directAlias = originalLookup[alias] {
                return directAlias
            }
            let aliasKey = Self.normalizedKey(alias)
            if let match = normalizedLookup[aliasKey] {
                return match
            }
            if let directAsset = directAssetSource(for: alias) {
                return directAsset
            }
        }

        let normalized = Self.normalizedKey(trimmed)
        if let match = normalizedLookup[normalized] {
            return match
        }

        let core = Self.normalizedCoreKey(trimmed)
        if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
            return uniqueCoreMatch
        }

        return fuzzyMatch(normalizedTeam: normalized)
    }

    private func directAssetSource(for name: String) -> ImageSource? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard UIImage(named: trimmed) != nil else { return nil }
        return .asset(trimmed)
    }

    private func uniqueCoreMatch(for coreKey: String) -> ImageSource? {
        guard !coreKey.isEmpty else { return nil }
        guard let candidates = coreLookup[coreKey], !candidates.isEmpty else { return nil }

        var seenIDs = Set<String>()
        let unique = candidates.filter { seenIDs.insert($0.identifier).inserted }
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func fuzzyMatch(normalizedTeam: String) -> ImageSource? {
        guard !normalizedTeam.isEmpty else { return nil }

        var bestKey: String?
        var bestScore: Double = 0

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

    private func image(from source: ImageSource) -> UIImage? {
        switch source {
        case let .file(url):
            return UIImage(contentsOfFile: url.path)
        case let .asset(name):
            return UIImage(named: name)
        }
    }

    private func isFallbackSource(_ source: ImageSource) -> Bool {
        Self.isFallbackName(source.displayName)
    }

    private static func isFallbackName(_ name: String) -> Bool {
        let fallback = normalizedKey("_noTeamLogo")
        let normalized = normalizedKey(name)
        return normalized == fallback || normalized.hasPrefix(fallback)
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private static func normalizedCoreKey(_ value: String) -> String {
        normalizedTokens(value, stripClubAffixes: true).joined()
    }

    private static func normalizedTokens(_ value: String, stripClubAffixes: Bool = false) -> [String] {
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
        let aliases = TeamIdentityStore.shared.names(for: name)
        if aliases.isEmpty {
            return [name.lowercased()]
        }
        return aliases.map { $0.lowercased() }
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

    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

}
