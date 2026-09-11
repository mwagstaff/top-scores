import Foundation

/// Keep persistence and JSON work off the main actor, including cache hits on navigation.
actor MatchDetailsCache {
    static let shared = MatchDetailsCache()

    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load(for detailsID: String) -> MatchDetailsPayload? {
        let started = ProcessInfo.processInfo.systemUptime
        guard let data = defaults.data(forKey: key(for: detailsID)) else { return nil }
        do {
            let cached = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            diagnosticLogAsync("[MatchDetailCache] loaded id=\(detailsID) bytes=\(data.count) duration_ms=\(durationMs) updated_at=\(cached.updatedAt ?? "-")")
            return cached
        } catch {
            diagnosticLogAsync("[MatchDetailCache] load_failed id=\(detailsID) error=\(error)")
            return nil
        }
    }

    func save(_ details: MatchDetailsPayload, for detailsID: String) {
        // Preserve populated events while the server is backfilling an empty response.
        if !hasEvents(details), let cached = load(for: detailsID), hasEvents(cached) {
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let encoded = try JSONEncoder().encode(details)
            defaults.set(encoded, forKey: key(for: detailsID))
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            diagnosticLogAsync("[MatchDetailCache] saved id=\(detailsID) bytes=\(encoded.count) duration_ms=\(durationMs)")
        } catch {
            diagnosticLogAsync("[MatchDetailCache] save_failed id=\(detailsID) error=\(error)")
        }
    }

    private func hasEvents(_ details: MatchDetailsPayload) -> Bool {
        !details.homeGoalScorers.isEmpty || !details.awayGoalScorers.isEmpty ||
            !details.homeRedCards.isEmpty || !details.awayRedCards.isEmpty
    }

    private func key(for detailsID: String) -> String {
        "match.details.cache.\(detailsID)"
    }
}
