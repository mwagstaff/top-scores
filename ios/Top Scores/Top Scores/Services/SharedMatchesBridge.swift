import Foundation
import WidgetKit

enum AppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
    static let matchesPayloadContextKey = "matches_payload"
    static let requestMatchesSyncMessageKey = "request_matches_sync"
    static let fantasySharedEntryURLKey = "fantasy.sharedEntryURL"
    static let fantasySharedEntryUpdatedAtKey = "fantasy.sharedEntryUpdatedAt"
    static let fantasyManagerEntryIDKey = "fantasy.managerEntryID"

    static let selectedLeaguesKey = "preferences.selectedLeagues"
    static let selectedChannelsKey = "preferences.selectedChannels"
    static let competitionFilterEnabledKey = "preferences.competitionFilterEnabled"
    static let channelFilterEnabledKey = "preferences.channelFilterEnabled"
    static let englishPremierLeagueTeamsOnlyKey = "preferences.englishPremierLeagueTeamsOnly"
    static let apiBaseURLKey = "preferences.apiBaseURL"
    static let refreshIntervalMinutesKey = "preferences.refreshIntervalMinutes"
    static let showAllMatchesKey = "preferences.showAllMatches"
    static let matchGroupSortOrderKey = "preferences.matchGroupSortOrder"
}

struct SharedMatchesPayload: Codable {
    let snapshot: PreferencesSnapshot
    let matches: [Match]
    let unfilteredMatches: [Match]
    let lastUpdated: Date?
    let generatedAt: Date
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

    static func saveSnapshotToSharedDefaults(_ snapshot: PreferencesSnapshot) {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.set(snapshot.selectedLeagues, forKey: AppGroupConfig.selectedLeaguesKey)
        defaults.set(snapshot.selectedChannels, forKey: AppGroupConfig.selectedChannelsKey)
        defaults.set(snapshot.competitionFilterEnabled, forKey: AppGroupConfig.competitionFilterEnabledKey)
        defaults.set(snapshot.channelFilterEnabled, forKey: AppGroupConfig.channelFilterEnabledKey)
        defaults.set(snapshot.englishPremierLeagueTeamsOnly, forKey: AppGroupConfig.englishPremierLeagueTeamsOnlyKey)
        defaults.set(snapshot.apiBaseURL, forKey: AppGroupConfig.apiBaseURLKey)
        defaults.set(snapshot.refreshIntervalMinutes, forKey: AppGroupConfig.refreshIntervalMinutesKey)
        defaults.set(snapshot.showAllMatches, forKey: AppGroupConfig.showAllMatchesKey)
        defaults.set(snapshot.matchGroupSortOrder.rawValue, forKey: AppGroupConfig.matchGroupSortOrderKey)
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
