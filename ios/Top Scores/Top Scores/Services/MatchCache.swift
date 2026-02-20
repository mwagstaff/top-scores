import Foundation

struct MatchCachePayload: Codable {
    let snapshot: PreferencesSnapshot
    let matches: [Match]
    let lastUpdated: Date?
}

enum MatchCache {
    private static let fileName = "matches-cache.json"

    static func load(for snapshot: PreferencesSnapshot) -> MatchCachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(MatchCachePayload.self, from: data) else { return nil }
        guard payload.snapshot == snapshot else { return nil }
        return payload
    }

    static func save(matches: [Match], lastUpdated: Date?, snapshot: PreferencesSnapshot) {
        let payload = MatchCachePayload(snapshot: snapshot, matches: matches, lastUpdated: lastUpdated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}
