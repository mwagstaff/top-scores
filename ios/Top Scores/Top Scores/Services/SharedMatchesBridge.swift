import Foundation
import WidgetKit

enum AppGroupConfig {
    nonisolated static let identifier = "group.dev.skynolimit.topscores"
    nonisolated static let sharedMatchesFileName = "shared-matches.json"
    nonisolated static let matchesPayloadContextKey = "matches_payload"
    nonisolated static let requestMatchesSyncMessageKey = "request_matches_sync"
    nonisolated static let fantasySharedImportQueueKey = "fantasy.sharedImportQueue"
    nonisolated static let fantasySharedEntryURLKey = "fantasy.sharedEntryURL"
    nonisolated static let fantasySharedEntryUpdatedAtKey = "fantasy.sharedEntryUpdatedAt"
    nonisolated static let fantasyManagerEntryIDKey = "fantasy.managerEntryID"

    nonisolated static let selectedLeaguesKey = "preferences.selectedLeagues"
    nonisolated static let selectedChannelsKey = "preferences.selectedChannels"
    nonisolated static let competitionFilterEnabledKey = "preferences.competitionFilterEnabled"
    nonisolated static let channelFilterEnabledKey = "preferences.channelFilterEnabled"
    nonisolated static let englishPremierLeagueTeamsOnlyKey = "preferences.englishPremierLeagueTeamsOnly"
    nonisolated static let majorUEFAClubGamesEnabledKey = "preferences.majorUEFAClubGamesEnabled"
    nonisolated static let apiBaseURLKey = "preferences.apiBaseURL"
    nonisolated static let refreshIntervalMinutesKey = "preferences.refreshIntervalMinutes"
    nonisolated static let showAllMatchesKey = "preferences.showAllMatches"
    nonisolated static let matchGroupSortOrderKey = "preferences.matchGroupSortOrder"
    nonisolated static let showFantasyFixtureLogosKey = "preferences.showFantasyFixtureLogos"
    nonisolated static let showFantasyExpectedPointsKey = "preferences.showFantasyExpectedPoints"
    nonisolated static let showFantasyRealTimePointsKey = "preferences.showFantasyRealTimePoints"
    nonisolated static let showFantasyMatchPillsKey = "preferences.showFantasyMatchPills"
    nonisolated static let competitionCatalogWeightsDataKey = "catalog.competitionWeightsData"
    nonisolated static let competitionCatalogUpdatedAtKey = "catalog.competitionWeightsUpdatedAt"
    nonisolated static let competitionCatalogFetchedAtKey = "catalog.competitionWeightsFetchedAt"
}

struct SharedMatchesPayload: Codable, Equatable {
    let snapshot: PreferencesSnapshot
    let matches: [Match]
    let unfilteredMatches: [Match]
    let lastUpdated: Date?
    let generatedAt: Date

    static func == (lhs: SharedMatchesPayload, rhs: SharedMatchesPayload) -> Bool {
        lhs.snapshot == rhs.snapshot &&
        lhs.matches == rhs.matches &&
        lhs.unfilteredMatches == rhs.unfilteredMatches &&
        lhs.lastUpdated == rhs.lastUpdated
    }
}

struct FantasySharedImportPayload: Codable, Equatable {
    let rawURL: String
    let updatedAt: TimeInterval

    var trimmedRawURL: String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FantasySharedImportStore {
    static func loadQueue(from defaults: UserDefaults) -> [FantasySharedImportPayload] {
        guard let data = defaults.data(forKey: AppGroupConfig.fantasySharedImportQueueKey),
              let decoded = try? JSONDecoder().decode([FantasySharedImportPayload].self, from: data) else {
            return []
        }
        return decoded.filter { !$0.trimmedRawURL.isEmpty }
    }

    static func saveQueue(_ queue: [FantasySharedImportPayload], to defaults: UserDefaults) {
        let sanitizedQueue = queue.filter { !$0.trimmedRawURL.isEmpty }
        if sanitizedQueue.isEmpty {
            defaults.removeObject(forKey: AppGroupConfig.fantasySharedImportQueueKey)
        } else if let data = try? JSONEncoder().encode(sanitizedQueue) {
            defaults.set(data, forKey: AppGroupConfig.fantasySharedImportQueueKey)
        }
        saveLegacyPayload(sanitizedQueue.last, to: defaults)
    }

    static func loadLegacyPayload(from defaults: UserDefaults) -> FantasySharedImportPayload? {
        guard let rawURL = defaults.string(forKey: AppGroupConfig.fantasySharedEntryURLKey) else {
            return nil
        }

        let payload = FantasySharedImportPayload(
            rawURL: rawURL,
            updatedAt: defaults.double(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
        )
        return payload.trimmedRawURL.isEmpty ? nil : payload
    }

    static func saveLegacyPayload(_ payload: FantasySharedImportPayload?, to defaults: UserDefaults) {
        guard let payload else {
            defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryURLKey)
            defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
            return
        }

        defaults.set(payload.trimmedRawURL, forKey: AppGroupConfig.fantasySharedEntryURLKey)
        defaults.set(payload.updatedAt, forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
    }
}

enum SharedMatchesBridge {
    static func saveAndSync(matches: [Match], unfilteredMatches: [Match], lastUpdated: Date?, snapshot: PreferencesSnapshot) {
        let payload = SharedMatchesPayload(
            snapshot: snapshot,
            matches: matches,
            unfilteredMatches: unfilteredMatches,
            lastUpdated: lastUpdated,
            generatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        guard shouldSync(payload) else { return }

        saveRawData(data)
        saveSnapshotToSharedDefaults(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        PhoneWatchSyncService.shared.activate()
        PhoneWatchSyncService.shared.sendLatestPayload(data)
    }

    static func loadRawData() -> Data? {
        guard let url = sharedFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    static func saveRawData(_ data: Data) {
        guard let url = sharedFileURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func shouldSync(_ payload: SharedMatchesPayload) -> Bool {
        guard let existing = loadPayload() else { return true }
        return existing != payload
    }

    private static func loadPayload() -> SharedMatchesPayload? {
        guard let data = loadRawData() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedMatchesPayload.self, from: data)
    }

    static func saveSnapshotToSharedDefaults(_ snapshot: PreferencesSnapshot) {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.set(snapshot.selectedLeagues, forKey: AppGroupConfig.selectedLeaguesKey)
        defaults.set(snapshot.selectedChannels, forKey: AppGroupConfig.selectedChannelsKey)
        defaults.set(snapshot.competitionFilterEnabled, forKey: AppGroupConfig.competitionFilterEnabledKey)
        defaults.set(snapshot.channelFilterEnabled, forKey: AppGroupConfig.channelFilterEnabledKey)
        defaults.set(snapshot.englishPremierLeagueTeamsOnly, forKey: AppGroupConfig.englishPremierLeagueTeamsOnlyKey)
        defaults.set(snapshot.majorUEFAClubGamesEnabled, forKey: AppGroupConfig.majorUEFAClubGamesEnabledKey)
        defaults.set(snapshot.apiBaseURL, forKey: AppGroupConfig.apiBaseURLKey)
        defaults.set(snapshot.refreshIntervalMinutes, forKey: AppGroupConfig.refreshIntervalMinutesKey)
        defaults.set(snapshot.showAllMatches, forKey: AppGroupConfig.showAllMatchesKey)
        defaults.set(snapshot.matchGroupSortOrder.rawValue, forKey: AppGroupConfig.matchGroupSortOrderKey)
        defaults.set(snapshot.showFantasyFixtureLogos, forKey: AppGroupConfig.showFantasyFixtureLogosKey)
        defaults.set(snapshot.showFantasyExpectedPoints, forKey: AppGroupConfig.showFantasyExpectedPointsKey)
        defaults.set(snapshot.showFantasyRealTimePoints, forKey: AppGroupConfig.showFantasyRealTimePointsKey)
        defaults.set(snapshot.showsFantasyDataInFixtures, forKey: AppGroupConfig.showFantasyMatchPillsKey)
    }

    static func clear() {
        guard let url = sharedFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)?
            .appendingPathComponent(AppGroupConfig.sharedMatchesFileName)
    }
}
