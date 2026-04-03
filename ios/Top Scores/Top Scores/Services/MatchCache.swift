import Foundation

struct CacheGenerationSnapshot: Codable, Hashable {
    let matches: Int
    let matchDetails: Int
    let bbcLive: Int
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case matches
        case matchDetails = "match_details"
        case bbcLive = "bbc_live"
        case updatedAt = "updated_at"
    }

    init(matches: Int = 0, matchDetails: Int = 0, bbcLive: Int = 0, updatedAt: Date? = nil) {
        self.matches = max(0, matches)
        self.matchDetails = max(0, matchDetails)
        self.bbcLive = max(0, bbcLive)
        self.updatedAt = updatedAt
    }

    var hasAnyGeneration: Bool {
        matches > 0 || matchDetails > 0 || bbcLive > 0
    }

    func merged(with other: CacheGenerationSnapshot) -> CacheGenerationSnapshot {
        CacheGenerationSnapshot(
            matches: max(matches, other.matches),
            matchDetails: max(matchDetails, other.matchDetails),
            bbcLive: max(bbcLive, other.bbcLive),
            updatedAt: [updatedAt, other.updatedAt].compactMap { $0 }.max()
        )
    }

    func invalidationResult(comparedTo previous: CacheGenerationSnapshot) -> CacheInvalidationResult {
        CacheInvalidationResult(
            matchesChanged: matches > previous.matches,
            matchDetailsChanged: matchDetails > previous.matchDetails,
            bbcLiveChanged: bbcLive > previous.bbcLive
        )
    }
}

struct CacheInvalidationResult: Hashable {
    let matchesChanged: Bool
    let matchDetailsChanged: Bool
    let bbcLiveChanged: Bool

    static let none = CacheInvalidationResult(
        matchesChanged: false,
        matchDetailsChanged: false,
        bbcLiveChanged: false
    )

    var hasChanges: Bool {
        matchesChanged || matchDetailsChanged || bbcLiveChanged
    }

    var shouldClearMatchCaches: Bool {
        matchesChanged || matchDetailsChanged
    }

    var shouldClearBbcLiveCache: Bool {
        bbcLiveChanged
    }
}

struct MatchCachePayload: Codable {
    let cacheFormatVersion: Int?
    let snapshot: PreferencesSnapshot
    let matches: [Match]
    let lastUpdated: Date?
    let fixtureCoverageEnd: Date?
    let cacheGenerations: CacheGenerationSnapshot?

    enum CodingKeys: String, CodingKey {
        case cacheFormatVersion = "cache_format_version"
        case snapshot
        case matches
        case lastUpdated
        case fixtureCoverageEnd = "fixture_coverage_end"
        case cacheGenerations = "cache_generations"
    }

    init(
        cacheFormatVersion: Int?,
        snapshot: PreferencesSnapshot,
        matches: [Match],
        lastUpdated: Date?,
        fixtureCoverageEnd: Date?,
        cacheGenerations: CacheGenerationSnapshot?
    ) {
        self.cacheFormatVersion = cacheFormatVersion
        self.snapshot = snapshot
        self.matches = matches
        self.lastUpdated = lastUpdated
        self.fixtureCoverageEnd = fixtureCoverageEnd
        self.cacheGenerations = cacheGenerations
    }
}

enum MatchCache {
    private static let fileName = "matches-cache.json"
    private static let knownGenerationsKey = "match_cache.known_server_generations"
    private static let currentCacheFormatVersion = 2

    static func load(for snapshot: PreferencesSnapshot) -> MatchCachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(MatchCachePayload.self, from: data) else { return nil }
        guard payload.cacheFormatVersion == currentCacheFormatVersion else {
            clear()
            return nil
        }
        guard payload.snapshot.apiBaseURL == snapshot.apiBaseURL else { return nil }
        let knownGenerations = knownServerGenerations()
        if isPayloadStale(payload, comparedTo: knownGenerations) {
            clear()
            return nil
        }
        return payload
    }

    static func save(
        matches: [Match],
        lastUpdated: Date?,
        fixtureCoverageEnd: Date?,
        snapshot: PreferencesSnapshot
    ) {
        let knownGenerations = knownServerGenerations()
        let payload = MatchCachePayload(
            cacheFormatVersion: currentCacheFormatVersion,
            snapshot: snapshot,
            matches: matches,
            lastUpdated: lastUpdated,
            fixtureCoverageEnd: fixtureCoverageEnd,
            cacheGenerations: knownGenerations.hasAnyGeneration ? knownGenerations : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    static func knownServerGenerations() -> CacheGenerationSnapshot {
        guard let data = UserDefaults.standard.data(forKey: knownGenerationsKey) else {
            return CacheGenerationSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CacheGenerationSnapshot.self, from: data)) ?? CacheGenerationSnapshot()
    }

    @discardableResult
    static func applyServerCacheState(_ incoming: CacheGenerationSnapshot) -> CacheInvalidationResult {
        let previous = knownServerGenerations()
        let merged = previous.merged(with: incoming)
        guard merged != previous else { return .none }
        persistKnownServerGenerations(merged)
        return merged.invalidationResult(comparedTo: previous)
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private static func isPayloadStale(
        _ payload: MatchCachePayload,
        comparedTo knownGenerations: CacheGenerationSnapshot
    ) -> Bool {
        let payloadGenerations = payload.cacheGenerations ?? CacheGenerationSnapshot()
        return payloadGenerations.matches < knownGenerations.matches ||
            payloadGenerations.matchDetails < knownGenerations.matchDetails
    }

    private static func persistKnownServerGenerations(_ generations: CacheGenerationSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(generations) else { return }
        UserDefaults.standard.set(data, forKey: knownGenerationsKey)
    }
}
