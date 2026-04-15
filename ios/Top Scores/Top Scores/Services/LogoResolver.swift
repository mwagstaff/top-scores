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
    private var resolvedSourceCache: [String: ImageSource] = [:]
    private var unresolvedSourceKeys: Set<String> = []
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private var fallbackSource: ImageSource?

    private init() {
        loadLogos()
    }

    func image(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        let source = resolvePreferredSource(for: teamName, alternateNames: alternateNames) ?? fallbackSource
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

    func hasDedicatedLogo(for teamName: String, alternateNames: [String] = []) -> Bool {
        guard let resolved = resolvePreferredSource(for: teamName, alternateNames: alternateNames) else {
            return false
        }
        return !isFallbackSource(resolved)
    }

    func missingTeamNames(in teamNames: [String]) -> [String] {
        missingTeamNames(in: teamNames.map { ($0, [String]()) })
    }

    func missingTeamNames(in teamEntries: [(String, [String])]) -> [String] {
        var missing: [String] = []
        var seen = Set<String>()

        for (rawTeamName, alternateNames) in teamEntries {
            let normalizedDisplayName = Self.normalizedDisplayName(rawTeamName)
            guard !normalizedDisplayName.isEmpty else { continue }
            let dedupeKey = normalizedDisplayName.lowercased()
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            if !hasDedicatedLogo(for: normalizedDisplayName, alternateNames: alternateNames) {
                missing.append(normalizedDisplayName)
            }
        }

        return missing.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func resolvePreferredSource(for teamName: String, alternateNames: [String]) -> ImageSource? {
        for candidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            if let resolved = resolveSource(for: candidate) {
                return resolved
            }
        }
        return nil
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
        if !normalized.isEmpty {
            normalizedLookup[normalized] = source
        }

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
        let cacheKey = trimmed.lowercased()

        if let cached = resolvedSourceCache[cacheKey] {
            return cached
        }
        if unresolvedSourceKeys.contains(cacheKey) {
            return nil
        }

        let lower = trimmed.lowercased()
        if let direct = originalLookup[lower] {
            resolvedSourceCache[cacheKey] = direct
            return direct
        }

        if let directAsset = directAssetSource(for: trimmed) {
            resolvedSourceCache[cacheKey] = directAsset
            return directAsset
        }

        for alias in Self.aliases(for: trimmed) {
            if let directAlias = originalLookup[alias] {
                resolvedSourceCache[cacheKey] = directAlias
                return directAlias
            }
            let aliasKey = Self.normalizedKey(alias)
            if let match = normalizedLookup[aliasKey] {
                resolvedSourceCache[cacheKey] = match
                return match
            }
            if let directAsset = directAssetSource(for: alias) {
                resolvedSourceCache[cacheKey] = directAsset
                return directAsset
            }
        }

        let normalized = Self.normalizedKey(trimmed)
        if let match = normalizedLookup[normalized] {
            resolvedSourceCache[cacheKey] = match
            return match
        }

        let core = Self.normalizedCoreKey(trimmed)
        if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
            resolvedSourceCache[cacheKey] = uniqueCoreMatch
            return uniqueCoreMatch
        }
        if let fuzzyMatch = fuzzyMatch(normalizedTeam: normalized) {
            resolvedSourceCache[cacheKey] = fuzzyMatch
            return fuzzyMatch
        }

        unresolvedSourceKeys.insert(cacheKey)
        return nil
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

    private static func normalizedTokens(
        _ value: String,
        stripClubAffixes: Bool = false
    ) -> [String] {
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
                if genericStopWords.contains(token) {
                    return false
                }
                if stripClubAffixes, clubAffixWords.contains(token) {
                    return false
                }
                return true
            }
    }

    private static func aliases(for name: String) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            output.append(key)
        }

        TeamIdentityStore.shared.names(for: name).forEach(add)
        BundledTeamIdentityCatalog.shared.names(for: name).forEach(add)

        if output.isEmpty {
            add(name)
        }

        return output
    }

    private static func lookupCandidates(for name: String, alternateNames: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let normalized = normalizedDisplayName(candidate)
            guard !normalized.isEmpty else { return }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return }
            output.append(normalized)
        }

        add(name)
        alternateNames.forEach(add)
        return output
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

    private static let genericStopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and"
    ]

    private static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

}

final class BundledTeamIdentityCatalog {
    static let shared = BundledTeamIdentityCatalog()

    private var canonicalNameByKey: [String: String] = [:]
    private var namesByCanonicalKey: [String: [String]] = [:]
    private var exactToCanonicalKey: [String: String] = [:]

    private init() {
        load()
    }

    func names(for rawValue: String) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let key = TeamIdentityStore.normalizedKey(trimmed)
        let canonicalKey = exactToCanonicalKey[key]
        let canonicalName = canonicalKey.flatMap { canonicalNameByKey[$0] }
        let knownNames = canonicalKey.flatMap { namesByCanonicalKey[$0] } ?? []

        var output: [String] = []
        var seen = Set<String>()
        for candidate in ([canonicalName, trimmed] + knownNames).compactMap({ $0 }) {
            let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCandidate.isEmpty else { continue }
            let dedupeKey = normalizedCandidate.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            output.append(normalizedCandidate)
        }
        return output
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "team_colors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(TeamColorsCatalogResponse.self, from: data) else {
            return
        }

        for entry in catalog.teams.map({ ($0.name, $0.aliases) }) +
            catalog.identityGroups.map({ ($0.name, $0.aliases) }) {
            let canonicalKey = TeamIdentityStore.normalizedKey(entry.0)
            guard !canonicalKey.isEmpty else { continue }

            if canonicalNameByKey[canonicalKey] == nil {
                canonicalNameByKey[canonicalKey] = entry.0
            }

            var names = namesByCanonicalKey[canonicalKey] ?? []
            for candidate in [entry.0] + entry.1 {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !names.contains(trimmed) {
                    names.append(trimmed)
                }

                let key = TeamIdentityStore.normalizedKey(trimmed)
                if !key.isEmpty, exactToCanonicalKey[key] == nil {
                    exactToCanonicalKey[key] = canonicalKey
                }
            }
            namesByCanonicalKey[canonicalKey] = names
        }
    }
}
