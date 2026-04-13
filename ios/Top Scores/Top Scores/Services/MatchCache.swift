import Foundation

struct CacheGenerationSnapshot: Codable, Hashable, Sendable {
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

    nonisolated init(matches: Int = 0, matchDetails: Int = 0, bbcLive: Int = 0, updatedAt: Date? = nil) {
        self.matches = max(0, matches)
        self.matchDetails = max(0, matchDetails)
        self.bbcLive = max(0, bbcLive)
        self.updatedAt = updatedAt
    }

    nonisolated var hasAnyGeneration: Bool {
        matches > 0 || matchDetails > 0 || bbcLive > 0
    }

    nonisolated func merged(with other: CacheGenerationSnapshot) -> CacheGenerationSnapshot {
        CacheGenerationSnapshot(
            matches: max(matches, other.matches),
            matchDetails: max(matchDetails, other.matchDetails),
            bbcLive: max(bbcLive, other.bbcLive),
            updatedAt: [updatedAt, other.updatedAt].compactMap { $0 }.max()
        )
    }

    nonisolated func invalidationResult(comparedTo previous: CacheGenerationSnapshot) -> CacheInvalidationResult {
        CacheInvalidationResult(
            matchesChanged: matches > previous.matches,
            matchDetailsChanged: matchDetails > previous.matchDetails,
            bbcLiveChanged: bbcLive > previous.bbcLive
        )
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matches = max(0, try container.decodeIfPresent(Int.self, forKey: .matches) ?? 0)
        matchDetails = max(0, try container.decodeIfPresent(Int.self, forKey: .matchDetails) ?? 0)
        bbcLive = max(0, try container.decodeIfPresent(Int.self, forKey: .bbcLive) ?? 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matches, forKey: .matches)
        try container.encode(matchDetails, forKey: .matchDetails)
        try container.encode(bbcLive, forKey: .bbcLive)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    nonisolated static func == (lhs: CacheGenerationSnapshot, rhs: CacheGenerationSnapshot) -> Bool {
        lhs.matches == rhs.matches &&
        lhs.matchDetails == rhs.matchDetails &&
        lhs.bbcLive == rhs.bbcLive &&
        lhs.updatedAt == rhs.updatedAt
    }
}

struct CacheInvalidationResult: Hashable, Sendable {
    let matchesChanged: Bool
    let matchDetailsChanged: Bool
    let bbcLiveChanged: Bool

    nonisolated static let none = CacheInvalidationResult(
        matchesChanged: false,
        matchDetailsChanged: false,
        bbcLiveChanged: false
    )

    nonisolated var hasChanges: Bool {
        matchesChanged || matchDetailsChanged || bbcLiveChanged
    }

    nonisolated var shouldClearMatchCaches: Bool {
        matchesChanged || matchDetailsChanged
    }

    nonisolated var shouldClearBbcLiveCache: Bool {
        bbcLiveChanged
    }
}

struct MatchCachePayload: Codable, Sendable {
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

    nonisolated init(
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

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheFormatVersion = try container.decodeIfPresent(Int.self, forKey: .cacheFormatVersion)
        snapshot = try container.decode(PreferencesSnapshot.self, forKey: .snapshot)
        matches = try container.decode([Match].self, forKey: .matches)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        fixtureCoverageEnd = try container.decodeIfPresent(Date.self, forKey: .fixtureCoverageEnd)
        cacheGenerations = try container.decodeIfPresent(CacheGenerationSnapshot.self, forKey: .cacheGenerations)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cacheFormatVersion, forKey: .cacheFormatVersion)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(matches, forKey: .matches)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(fixtureCoverageEnd, forKey: .fixtureCoverageEnd)
        try container.encodeIfPresent(cacheGenerations, forKey: .cacheGenerations)
    }
}

enum MatchCache {
    private nonisolated static let fileName = "matches-cache.json"
    private nonisolated static let knownGenerationsKey = "match_cache.known_server_generations"
    private nonisolated static let currentCacheFormatVersion = 3

    nonisolated static func load(for snapshot: PreferencesSnapshot) -> MatchCachePayload? {
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

    nonisolated static func save(
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

    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    nonisolated static func knownServerGenerations() -> CacheGenerationSnapshot {
        guard let data = UserDefaults.standard.data(forKey: knownGenerationsKey) else {
            return CacheGenerationSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CacheGenerationSnapshot.self, from: data)) ?? CacheGenerationSnapshot()
    }

    @discardableResult
    nonisolated static func applyServerCacheState(_ incoming: CacheGenerationSnapshot) -> CacheInvalidationResult {
        let previous = knownServerGenerations()
        let merged = previous.merged(with: incoming)
        guard merged != previous else { return .none }
        persistKnownServerGenerations(merged)
        return merged.invalidationResult(comparedTo: previous)
    }

    private nonisolated static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private nonisolated static func isPayloadStale(
        _ payload: MatchCachePayload,
        comparedTo knownGenerations: CacheGenerationSnapshot
    ) -> Bool {
        let payloadGenerations = payload.cacheGenerations ?? CacheGenerationSnapshot()
        return payloadGenerations.matches < knownGenerations.matches ||
            payloadGenerations.matchDetails < knownGenerations.matchDetails
    }

    private nonisolated static func persistKnownServerGenerations(_ generations: CacheGenerationSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(generations) else { return }
        UserDefaults.standard.set(data, forKey: knownGenerationsKey)
    }
}
