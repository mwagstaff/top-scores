import Foundation
import UIKit

nonisolated enum ArtworkDisplayPreparationQueue {
    static let shared = DispatchQueue(
        label: "dev.skynolimit.topscores.artwork-display-preparation",
        qos: .utility
    )
}

nonisolated final class LogoResolver: @unchecked Sendable {
    static let shared = LogoResolver()

    private struct FuzzyCandidate {
        let key: String
        let characters: [Character]
    }

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
    private static let bundledLogoOverrideKeys: Set<String> = [
        normalizedKey("Sheffield Wednesday"),
        normalizedKey("Sheff Wed")
    ]
    private var normalizedLookup: [String: ImageSource] = [:]
    private var coreLookup: [String: [ImageSource]] = [:]
    private var originalLookup: [String: ImageSource] = [:]
    private var fuzzyCandidatesByInitial: [Character: [FuzzyCandidate]] = [:]
    private var resolvedSourceCache: [String: ImageSource] = [:]
    private var unresolvedSourceKeys: Set<String> = []
    private let resolutionLock = NSLock()
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private let displayImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()
    private var fallbackSource: ImageSource?

    private init() {
        loadLogos()
        buildFuzzyIndex()
    }

    func image(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        return bundledImage(for: teamName, alternateNames: alternateNames, useFallback: true)
    }

    private func bundledImage(
        for teamName: String,
        alternateNames: [String],
        useFallback: Bool
    ) -> UIImage? {
        let displayKey = Self.displayCacheKey(
            teamName: teamName,
            alternateNames: alternateNames
        ) as NSString
        if let cached = displayImageCache.object(forKey: displayKey) {
            return cached
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let resolvedSource = resolvePreferredSource(
            for: teamName,
            alternateNames: alternateNames
        )
        let source = resolvedSource ?? (useFallback ? fallbackSource : nil)
        guard let source else { return nil }

        let cacheKey = source.identifier as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            displayImageCache.setObject(cached, forKey: displayKey)
            return cached
        }

        let image = image(from: source)
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
            displayImageCache.setObject(image, forKey: displayKey)
        }
        let durationMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        )
        if Thread.isMainThread && durationMilliseconds >= 4 {
            diagnosticLogAsync(
                "[FixtureArtwork] team_cache_miss duration_ms=\(durationMilliseconds) " +
                "team=\(teamName) success=\(image == nil ? 0 : 1)"
            )
        }
        return image
    }

    func image(for teamName: String, teamId: String?, alternateNames: [String] = []) -> UIImage? {
        return image(for: teamName, alternateNames: alternateNames)
    }

    func prepareImagesForDisplay(for matches: [Match]) {
        struct TeamEntry: Hashable {
            let name: String
            let alternateNames: [String]
        }

        let entries = Set(matches.flatMap { match in
            [
                TeamEntry(
                    name: match.homeTeam,
                    alternateNames: [match.homeShortName].compactMap { $0 }
                ),
                TeamEntry(
                    name: match.awayTeam,
                    alternateNames: [match.awayShortName].compactMap { $0 }
                ),
            ]
        })
        guard !entries.isEmpty else { return }

        ArtworkDisplayPreparationQueue.shared.async { [weak self, entries] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            var preparedCount = 0
            var workDuration: TimeInterval = 0
            for entry in entries {
                autoreleasepool {
                    InteractiveMotionGate.shared.waitUntilIdleBlocking(
                        operation: "fixture_team_artwork"
                    )
                    let workStartedAt = ProcessInfo.processInfo.systemUptime
                    defer {
                        workDuration += ProcessInfo.processInfo.systemUptime - workStartedAt
                    }
                    let source = self.resolvePreferredSource(
                        for: entry.name,
                        alternateNames: entry.alternateNames
                    ) ?? self.fallbackSource
                    guard let source else { return }
                    let cacheKey = source.identifier as NSString
                    let sourceImage = self.imageCache.object(forKey: cacheKey) ??
                        self.image(from: source)
                    guard let sourceImage else { return }
                    diagnosticLogAsync(
                        "[FixtureArtwork] prepare_start kind=team source=\(source.displayName)"
                    )
                    let preparedImage = sourceImage.preparingForDisplay() ?? sourceImage
                    diagnosticLogAsync(
                        "[FixtureArtwork] prepare_finished kind=team source=\(source.displayName)"
                    )
                    self.imageCache.setObject(preparedImage, forKey: cacheKey)
                    self.displayImageCache.setObject(
                        preparedImage,
                        forKey: Self.displayCacheKey(
                            teamName: entry.name,
                            alternateNames: entry.alternateNames
                        ) as NSString
                    )
                    preparedCount += 1
                }
            }
            let durationMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            let workMilliseconds = Int((workDuration * 1_000).rounded())
            if durationMilliseconds >= 25 {
                diagnosticLogAsync(
                    "[FixtureArtwork] team_batch entries=\(entries.count) " +
                    "prepared=\(preparedCount) duration_ms=\(durationMilliseconds) " +
                    "wait_ms=\(max(0, durationMilliseconds - workMilliseconds)) " +
                    "work_ms=\(workMilliseconds)"
                )
            }
        }
    }

    private static func displayCacheKey(
        teamName: String,
        alternateNames: [String]
    ) -> String {
        ([teamName] + alternateNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    private func prefersBundledLogo(for teamName: String, alternateNames: [String]) -> Bool {
        Self.lookupCandidates(for: teamName, alternateNames: alternateNames).contains {
            Self.bundledLogoOverrideKeys.contains(Self.normalizedKey($0))
        }
    }

    func hasDedicatedLogo(for teamName: String, alternateNames: [String] = []) -> Bool {
        guard let resolved = resolvePreferredSource(
            for: teamName,
            alternateNames: alternateNames
        ) else {
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
            guard !Self.isNonTeamPlaceholder(normalizedDisplayName) else { continue }
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

    private func buildFuzzyIndex() {
        fuzzyCandidatesByInitial = Dictionary(
            grouping: normalizedLookup.keys.compactMap { key -> (Character, FuzzyCandidate)? in
                guard let initial = key.first else { return nil }
                return (initial, FuzzyCandidate(key: key, characters: Array(key)))
            },
            by: { $0.0 }
        )
        .mapValues { entries in
            entries.map(\.1).sorted { $0.key < $1.key }
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

        let cached = resolutionLock.withLock { () -> (found: Bool, source: ImageSource?) in
            if let source = resolvedSourceCache[cacheKey] {
                return (true, source)
            }
            if unresolvedSourceKeys.contains(cacheKey) {
                return (true, nil)
            }
            return (false, nil)
        }
        if cached.found { return cached.source }

        let resolved = resolveUncachedSource(for: trimmed)
        resolutionLock.withLock {
            if let resolved {
                resolvedSourceCache[cacheKey] = resolved
            } else {
                unresolvedSourceKeys.insert(cacheKey)
            }
        }
        return resolved
    }

    private func resolveUncachedSource(for trimmed: String) -> ImageSource? {
        let lower = trimmed.lowercased()
        if let direct = originalLookup[lower] {
            return direct
        }

        for alias in Self.aliases(for: trimmed) {
            if let directAlias = originalLookup[alias] {
                return directAlias
            }
            let aliasKey = Self.normalizedKey(alias)
            if let match = normalizedLookup[aliasKey] {
                return match
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
        if let fuzzyMatch = fuzzyMatch(normalizedTeam: normalized) {
            return fuzzyMatch
        }

        return nil
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
        guard let initial = normalizedTeam.first,
              let candidates = fuzzyCandidatesByInitial[initial] else {
            return nil
        }

        let teamCharacters = Array(normalizedTeam)
        var bestKey: String?
        var bestScore: Double = 0

        for candidate in candidates {
            let maximumLength = max(teamCharacters.count, candidate.characters.count)
            let maximumDistance = Int(
                (Double(maximumLength) * (1 - Self.fuzzySimilarityThreshold)).rounded(.down)
            )
            guard abs(teamCharacters.count - candidate.characters.count) <= maximumDistance,
                  let distance = Self.levenshtein(
                    teamCharacters,
                    candidate.characters,
                    maximumDistance: maximumDistance
                  ) else {
                continue
            }
            let score = 1 - (Double(distance) / Double(maximumLength))
            if score > bestScore {
                bestScore = score
                bestKey = candidate.key
            }
        }

        if let bestKey, bestScore >= Self.fuzzySimilarityThreshold {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private func image(from source: ImageSource) -> UIImage? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let isMainThread = Thread.isMainThread
        if isMainThread {
            performanceDiagnosticSetBreadcrumb(
                category: "artwork_decode",
                value: "team source=\(source.displayName)"
            )
        }
        defer {
            if isMainThread {
                performanceDiagnosticSetBreadcrumb(category: "artwork_decode", value: nil)
            }
        }
        let image: UIImage? = switch source {
        case let .file(url):
            UIImage(contentsOfFile: url.path)
        case let .asset(name):
            UIImage(named: name)
        }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let durationMilliseconds = Int(((finishedAt - startedAt) * 1_000).rounded())
        diagnosticLogAsync(
            "[FixtureArtwork] cold_load kind=team source=\(source.displayName) " +
            "duration_ms=\(durationMilliseconds) main_thread=\(isMainThread ? 1 : 0) " +
            "success=\(image == nil ? 0 : 1) uptime_ms=\(Int((finishedAt * 1_000).rounded()))"
        )
        return image
    }

    private func isFallbackSource(_ source: ImageSource) -> Bool {
        Self.isFallbackName(source.displayName)
    }

    private static func isFallbackName(_ name: String) -> Bool {
        let fallback = normalizedKey("_noTeamLogo")
        let normalized = normalizedKey(name)
        return normalized == fallback || normalized.hasPrefix(fallback)
    }

    private static func isNonTeamPlaceholder(_ name: String) -> Bool {
        normalizedDisplayName(name).localizedCaseInsensitiveCompare("TBC") == .orderedSame
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
            .map { stripLeadingZeros(String($0)) }
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

    /// Xcode strips leading zeros from trailing numbers in asset catalog
    /// imageset names (e.g. "1. FSV Mainz 05" -> "1. FSV Mainz 5"), so
    /// numeric tokens are normalized the same way on both sides of the lookup.
    private static func stripLeadingZeros(_ token: String) -> String {
        guard token.count > 1, token.allSatisfy(\.isNumber) else { return token }
        let stripped = token.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
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

    private static func levenshtein(
        _ lhs: [Character],
        _ rhs: [Character],
        maximumDistance: Int
    ) -> Int? {
        guard abs(lhs.count - rhs.count) <= maximumDistance else { return nil }
        if lhs.isEmpty {
            return rhs.count <= maximumDistance ? rhs.count : nil
        }
        if rhs.isEmpty {
            return lhs.count <= maximumDistance ? lhs.count : nil
        }

        let sentinel = maximumDistance + 1
        var previous = Array(repeating: sentinel, count: rhs.count + 1)
        var current = Array(repeating: sentinel, count: rhs.count + 1)
        for index in 0...min(rhs.count, maximumDistance) {
            previous[index] = index
        }

        for lhsIndex in 1...lhs.count {
            let lowerBound = max(1, lhsIndex - maximumDistance)
            let upperBound = min(rhs.count, lhsIndex + maximumDistance)
            guard lowerBound <= upperBound else { return nil }

            current[lowerBound - 1] = lowerBound == 1 ? lhsIndex : sentinel
            for rhsIndex in lowerBound...upperBound {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }
            if upperBound < rhs.count {
                current[upperBound + 1] = sentinel
            }
            swap(&previous, &current)
        }

        let distance = previous[rhs.count]
        return distance <= maximumDistance ? distance : nil
    }

    private static let fuzzySimilarityThreshold = 0.78

    private static let genericStopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and"
    ]

    private static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

}

nonisolated final class BundledTeamIdentityCatalog: @unchecked Sendable {
    nonisolated static let shared = BundledTeamIdentityCatalog()

    private nonisolated(unsafe) var canonicalNameByKey: [String: String] = [:]
    private nonisolated(unsafe) var namesByCanonicalKey: [String: [String]] = [:]
    private nonisolated(unsafe) var exactToCanonicalKey: [String: String] = [:]

    private init() {
        load()
    }

    nonisolated func names(for rawValue: String) -> [String] {
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
