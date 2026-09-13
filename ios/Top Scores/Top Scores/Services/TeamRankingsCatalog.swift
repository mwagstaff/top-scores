import Foundation

struct TeamRatingResolution: Sendable {
    let rating: Double
    let usedDefault: Bool
}

struct TeamRatingLookup: Sendable {
    private final class ResolutionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: TeamRatingResolution] = [:]

        func value(for key: String) -> TeamRatingResolution? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: TeamRatingResolution, for key: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }

    private struct Candidate: Sendable {
        let key: String
        let keyCharacters: [Character]
        let tokens: [String]
        let tokenSet: Set<String>
        let rating: Double
    }

    private let exactByKey: [String: Double]
    private let candidates: [Candidate]
    private let candidateIndexesByTrigram: [String: [Int]]
    private let candidateIndexesByToken: [String: [Int]]
    private let defaultPoints: Double
    private let resolutionCache: ResolutionCache
    private nonisolated static let minimumAcceptedConfidence = 0.86
    private nonisolated static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk", "club", "de", "the", "and"
    ]
    nonisolated init(entries: [TeamRankingEntry], defaultPoints: Double = TeamRankingSettings.defaultDefaultElo) {
        var exact: [String: Double] = [:]
        var candidateList: [Candidate] = []
        var candidateKeys: Set<String> = []
        candidateList.reserveCapacity(entries.count * 2)

        for entry in entries {
            if Task.isCancelled { break }
            guard let points = entry.points, points.isFinite else { continue }
            var names = [entry.name]
            names.append(contentsOf: entry.aliases)
            let dedupedNames = Array(
                Set(names.flatMap { TeamIdentityStore.shared.names(for: $0) })
            ).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            for name in dedupedNames {
                if Task.isCancelled { break }
                let key = Self.normalizedKey(name)
                guard !key.isEmpty else { continue }
                exact[key] = exact[key] ?? points
                guard candidateKeys.insert(key).inserted else { continue }
                let tokens = Self.normalizedTokens(name)
                candidateList.append(
                    Candidate(
                        key: key,
                        keyCharacters: Array(key),
                        tokens: tokens,
                        tokenSet: Set(tokens),
                        rating: points
                    )
                )
            }
        }

        self.defaultPoints = defaultPoints
        exactByKey = exact
        candidates = candidateList
        var trigramIndex: [String: [Int]] = [:]
        var tokenIndex: [String: [Int]] = [:]
        for (index, candidate) in candidateList.enumerated() {
            for trigram in Self.trigrams(candidate.keyCharacters) {
                trigramIndex[trigram, default: []].append(index)
            }
            for token in candidate.tokenSet {
                tokenIndex[token, default: []].append(index)
            }
        }
        candidateIndexesByTrigram = trigramIndex
        candidateIndexesByToken = tokenIndex
        resolutionCache = ResolutionCache()
    }

    nonisolated func rating(for teamName: String) -> Double? {
        guard !Task.isCancelled else { return nil }
        var bestRating: Double?
        var bestConfidence = 0.0

        for variant in TeamIdentityStore.shared.names(for: teamName) {
            guard !Task.isCancelled else { return nil }
            let key = Self.normalizedKey(variant)
            guard !key.isEmpty else { continue }

            if let direct = exactByKey[key] {
                return direct
            }

            let sourceTokens = Self.normalizedTokens(variant)
            let sourceTokenSet = Set(sourceTokens)
            let keyCharacters = Array(key)
            let candidateIndexes = candidateIndexes(
                keyCharacters: keyCharacters,
                tokens: sourceTokenSet
            )
            for (scanIndex, candidateIndex) in candidateIndexes.enumerated() {
                if scanIndex.isMultiple(of: 64), Task.isCancelled {
                    return nil
                }
                let candidate = candidates[candidateIndex]
                let confidence = Self.similarity(
                    lhsKey: key,
                    lhsKeyCharacters: keyCharacters,
                    rhsKey: candidate.key,
                    lhsTokens: sourceTokens,
                    lhsTokenSet: sourceTokenSet,
                    rhs: candidate,
                    currentBestConfidence: bestConfidence
                )
                if confidence > bestConfidence {
                    bestConfidence = confidence
                    bestRating = candidate.rating
                }
            }
        }

        guard bestConfidence >= Self.minimumAcceptedConfidence else { return nil }
        return bestRating
    }

    /// A rating can only clear the fuzzy threshold when the names share a
    /// substantial part of their spelling, an exact token, or are very short.
    /// Index those signals once so each unseen team does not compare itself to
    /// every alias in the ratings catalogue.
    private nonisolated func candidateIndexes(
        keyCharacters: [Character],
        tokens: Set<String>
    ) -> [Int] {
        guard keyCharacters.count >= 5 else {
            return Array(candidates.indices)
        }

        var result: Set<Int> = []
        for trigram in Self.trigrams(keyCharacters) {
            if let indexes = candidateIndexesByTrigram[trigram] {
                result.formUnion(indexes)
            }
        }
        for token in tokens {
            if let indexes = candidateIndexesByToken[token] {
                result.formUnion(indexes)
            }
        }
        return result.sorted()
    }

    nonisolated func resolvedRating(for teamName: String) -> Double {
        resolveRating(for: teamName).rating
    }

    nonisolated func resolveRating(for teamName: String) -> TeamRatingResolution {
        guard !Task.isCancelled else {
            return TeamRatingResolution(rating: defaultPoints, usedDefault: true)
        }
        let cacheKey = Self.normalizedKey(teamName)
        if let cached = resolutionCache.value(for: cacheKey) {
            return cached
        }
        let resolution: TeamRatingResolution
        if let exactRating = rating(for: teamName) {
            resolution = TeamRatingResolution(rating: exactRating, usedDefault: false)
        } else {
            resolution = TeamRatingResolution(rating: defaultPoints, usedDefault: true)
        }
        // A cancelled speculative grouping must not poison the cache with a
        // fallback value produced by its early exit.
        guard !Task.isCancelled else {
            return TeamRatingResolution(rating: defaultPoints, usedDefault: true)
        }
        resolutionCache.store(resolution, for: cacheKey)
        return resolution
    }

    private nonisolated static func normalizedTokens(_ value: String) -> [String] {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { !stopWords.contains($0) }
    }

    private nonisolated static func normalizedKey(_ value: String) -> String {
        let tokens = normalizedTokens(value)
        if !tokens.isEmpty {
            return tokens.joined()
        }
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private nonisolated static func trigrams(_ characters: [Character]) -> Set<String> {
        guard characters.count >= 3 else { return [] }
        var result: Set<String> = []
        result.reserveCapacity(characters.count - 2)
        for index in 0..<(characters.count - 2) {
            result.insert(String(characters[index...(index + 2)]))
        }
        return result
    }

    private nonisolated static func similarity(
        lhsKey: String,
        lhsKeyCharacters: [Character],
        rhsKey: String,
        lhsTokens: [String],
        lhsTokenSet: Set<String>,
        rhs: Candidate,
        currentBestConfidence: Double
    ) -> Double {
        let dice = diceCoefficient(
            lhsTokens,
            rhs.tokens,
            lhsTokenSet: lhsTokenSet,
            rhsTokenSet: rhs.tokenSet
        )
        let prefix = prefixSimilarity(lhsKey, rhsKey, lhsTokens, rhs.tokens)
        var confidence = max(dice, prefix)

        // The edit score cannot exceed the ratio implied by the two lengths.
        // Avoid the matrix calculation for candidates that cannot clear the
        // acceptance threshold or improve the result already found. This is
        // particularly important for unranked lower-league fixtures, where the
        // old all-candidate scan could consume seconds of CPU.
        let maxLength = max(lhsKeyCharacters.count, rhs.keyCharacters.count)
        if maxLength > 0 {
            let lengthUpperBound = 1 - (
                Double(abs(lhsKeyCharacters.count - rhs.keyCharacters.count)) /
                    Double(maxLength)
            )
            let confidenceToBeat = max(currentBestConfidence, confidence)
            if lengthUpperBound >= minimumAcceptedConfidence,
               lengthUpperBound > confidenceToBeat {
                confidence = max(
                    confidence,
                    normalizedEditSimilarity(lhsKeyCharacters, rhs.keyCharacters)
                )
            }
        }
        return confidence
    }

    private nonisolated static func normalizedEditSimilarity(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Double {
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(levenshtein(lhs, rhs)) / Double(maxLength))
    }

    private nonisolated static func diceCoefficient(
        _ lhs: [String],
        _ rhs: [String],
        lhsTokenSet: Set<String>,
        rhsTokenSet: Set<String>
    ) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let overlap = lhsTokenSet.reduce(into: 0) { count, token in
            if rhsTokenSet.contains(token) {
                count += 1
            }
        }
        return (2 * Double(overlap)) / Double(lhs.count + rhs.count)
    }

    private nonisolated static func prefixSimilarity(
        _ lhsKey: String,
        _ rhsKey: String,
        _ lhsTokens: [String],
        _ rhsTokens: [String]
    ) -> Double {
        guard min(lhsTokens.count, rhsTokens.count) == 1 else { return 0 }
        if lhsKey.hasPrefix(rhsKey) || rhsKey.hasPrefix(lhsKey) {
            let shorter = min(lhsKey.count, rhsKey.count)
            let longer = max(lhsKey.count, rhsKey.count)
            guard longer > 0 else { return 1 }
            return min(1, (Double(shorter) / Double(longer)) + 0.30)
        }
        return 0
    }

    private nonisolated static func levenshtein(
        _ lhsCharacters: [Character],
        _ rhsCharacters: [Character]
    ) -> Int {
        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for (i, lhsChar) in lhsCharacters.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsCharacters.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsCharacters.count]
    }
}

struct TeamRankingSettings: Codable, Hashable, Sendable {
    nonisolated static let defaultDefaultElo = 1000.0

    let defaultElo: Double
    let updatedAt: Date?

    nonisolated init(defaultElo: Double = TeamRankingSettings.defaultDefaultElo, updatedAt: Date? = nil) {
        self.defaultElo = defaultElo
        self.updatedAt = updatedAt
    }
}

private struct TeamRankingSettingsCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let settings: TeamRankingSettings

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case settings
    }

    nonisolated init(fetchedAt: Date, settings: TeamRankingSettings) {
        self.fetchedAt = fetchedAt
        self.settings = settings
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        settings = try container.decode(TeamRankingSettings.self, forKey: .settings)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(settings, forKey: .settings)
    }
}

actor TeamRankingSettingsCatalog {
    static let shared = TeamRankingSettingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "team-ranking-settings-cache.json"

    private var didLoadCache = false
    private var cachedSettings = TeamRankingSettings()
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<TeamRankingSettings, Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid team ranking settings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<TeamRankingSettings, Error> {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchTeamRankingSettings()
            return TeamRankingSettings(
                defaultElo: response.defaultElo,
                updatedAt: response.updatedAt
            )
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetched = try await task.value
            cachedSettings = fetched
            cachedFetchedAt = Date()
            persistCache()
            log("Team ranking settings cache refreshed with default Elo \(Int(fetched.defaultElo.rounded())).")
        } catch {
            log("Team ranking settings refresh failed: \(String(describing: error))")
        }
    }

    func settings() -> TeamRankingSettings {
        loadCacheIfNeeded()
        return cachedSettings
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TeamRankingSettingsCachePayload.self, from: data) else {
            log("Failed to decode team ranking settings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedSettings = payload.settings
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }

        let payload = TeamRankingSettingsCachePayload(
            fetchedAt: fetchedAt,
            settings: cachedSettings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        try? data.write(to: cacheURL, options: [.atomic])
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: @autoclosure () -> String) {
        diagnosticLog("[TeamRankingSettingsCatalog] \(message())")
    }
}

private struct TeamRankingsCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let entries: [TeamRankingEntry]

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case entries
    }

    nonisolated init(fetchedAt: Date, entries: [TeamRankingEntry]) {
        self.fetchedAt = fetchedAt
        self.entries = entries
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        entries = try container.decode([TeamRankingEntry].self, forKey: .entries)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(entries, forKey: .entries)
    }
}

actor TeamRankingsCatalog {
    static let shared = TeamRankingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "team-rankings-cache.json"

    private var didLoadCache = false
    private var cachedEntriesStore: [TeamRankingEntry] = []
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[TeamRankingEntry], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid team rankings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[TeamRankingEntry], Error> {
            let client = APIClient(baseURL: baseURL)
            return try await client.fetchTeamRankings(type: "club")
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetched = try await task.value
            let normalized = normalize(entries: fetched)
            guard !normalized.isEmpty else {
                log("Team rankings refresh returned an empty payload; keeping existing cache.")
                return
            }

            cachedEntriesStore = normalized
            cachedFetchedAt = Date()
            persistCache()
            log("Team rankings cache refreshed with \(normalized.count) teams.")
        } catch {
            log("Team rankings refresh failed: \(String(describing: error))")
        }
    }

    func cachedEntries() -> [TeamRankingEntry] {
        loadCacheIfNeeded()
        return cachedEntriesStore
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedEntriesStore.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TeamRankingsCachePayload.self, from: data) else {
            log("Failed to decode team rankings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedEntriesStore = normalize(entries: payload.entries)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }

        let payload = TeamRankingsCachePayload(
            fetchedAt: fetchedAt,
            entries: cachedEntriesStore
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        try? data.write(to: cacheURL, options: [.atomic])
    }

    private nonisolated func normalize(entries: [TeamRankingEntry]) -> [TeamRankingEntry] {
        var seen = Set<String>()
        var normalized: [TeamRankingEntry] = []
        normalized.reserveCapacity(entries.count)

        for entry in entries {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            let key = normalizedKey(trimmedName)
            guard !key.isEmpty else { continue }
            guard seen.insert(key).inserted else { continue }

            var aliasSet = Set<String>()
            let aliases = entry.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && normalizedKey($0) != key && aliasSet.insert(normalizedKey($0)).inserted }

            normalized.append(
                TeamRankingEntry(
                    name: trimmedName,
                    points: entry.points,
                    aliases: aliases
                )
            )
        }

        return normalized
    }

    private nonisolated func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: @autoclosure () -> String) {
        diagnosticLog("[TeamRankingsCatalog] \(message())")
    }
}

private struct FantasyTeamShortNameMappingsCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let mappings: [String: String]

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case mappings
    }

    nonisolated init(fetchedAt: Date, mappings: [String: String]) {
        self.fetchedAt = fetchedAt
        self.mappings = mappings
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        mappings = try container.decode([String: String].self, forKey: .mappings)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(mappings, forKey: .mappings)
    }
}

final class FantasyTeamShortNameMappingsStore: @unchecked Sendable {
    nonisolated static let shared = FantasyTeamShortNameMappingsStore()

    private let lock = NSLock()
    private nonisolated(unsafe) var mappings: [String: String] = [:]

    private init() {}

    nonisolated func updateMappings(_ nextMappings: [String: String]) {
        lock.lock()
        mappings = nextMappings
        lock.unlock()
    }

    nonisolated func resolveTeamName(for rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let canonical = TeamIdentityStore.shared.canonicalName(for: trimmed)
        if canonical.caseInsensitiveCompare(trimmed) != .orderedSame {
            return canonical
        }

        let key = trimmed.uppercased()
        lock.lock()
        let mapped = mappings[key]
        lock.unlock()
        return mapped ?? trimmed
    }
}

actor FantasyTeamShortNameMappingsCatalog {
    static let shared = FantasyTeamShortNameMappingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "fantasy-team-short-name-mappings-cache.json"

    private var didLoadCache = false
    private var cachedMappings: [String: String] = [:]
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[String: String], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        applyCachedMappingsToStore()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid fantasy mappings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[String: String], Error> {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchFantasyTeamShortNameMappings()
            return Self.normalize(mappings: response.mappings)
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetchedMappings = try await task.value
            guard !fetchedMappings.isEmpty else {
                log("Fantasy mappings refresh returned empty payload; keeping existing cache.")
                return
            }

            cachedMappings = fetchedMappings
            cachedFetchedAt = Date()
            persistCache()
            applyCachedMappingsToStore()
            log("Fantasy mappings cache refreshed with \(fetchedMappings.count) entries.")
        } catch {
            log("Fantasy mappings refresh failed: \(String(describing: error))")
        }
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedMappings.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FantasyTeamShortNameMappingsCachePayload.self, from: data) else {
            log("Failed to decode fantasy mappings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedMappings = Self.normalize(mappings: payload.mappings)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }
        let payload = FantasyTeamShortNameMappingsCachePayload(
            fetchedAt: fetchedAt,
            mappings: cachedMappings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static func normalize(mappings rawMappings: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(rawMappings.count)

        for (rawKey, rawValue) in rawMappings {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            normalized[key] = value
        }

        return normalized
    }

    private func applyCachedMappingsToStore() {
        FantasyTeamShortNameMappingsStore.shared.updateMappings(cachedMappings)
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: @autoclosure () -> String) {
        diagnosticLog("[FantasyTeamShortNameMappingsCatalog] \(message())")
    }
}
