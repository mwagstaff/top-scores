import Foundation
import WidgetKit

enum AppGroupConfig {
    nonisolated static let identifier = "group.dev.skynolimit.topscores"
    nonisolated static let sharedMatchesFileName = "shared-matches.json"
    nonisolated static let watchSharedMatchesFileName = "watch-shared-matches.json"
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
    nonisolated static let liveActivityDiagnosticsKey = "live_activity.diagnostics"
    nonisolated static let liveActivityDiagnosticsFileName = "live-activity-diagnostics.log"
}

struct WidgetSharedMatchTransfer: Codable, Equatable, Sendable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeTeamId: String?
    let awayTeamId: String?
    let homeShortName: String?
    let awayShortName: String?
    let league: String
    let leagueSubcategory: String?
    let competitionWeight: Double?
    let matchDetailsIDValue: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let scoreStatus: String?
    let penaltyResult: String?

    nonisolated init(_ match: Match) {
        date = match.date
        time = match.time
        homeTeam = match.homeTeam
        awayTeam = match.awayTeam
        homeTeamId = match.homeTeamId
        awayTeamId = match.awayTeamId
        homeShortName = match.homeShortName
        awayShortName = match.awayShortName
        league = match.league
        leagueSubcategory = match.leagueSubcategory
        competitionWeight = match.competitionWeight
        matchDetailsIDValue = match.matchDetailsID
        tvChannels = match.tvChannels.map(\.name)
        homeScore = match.homeScore
        awayScore = match.awayScore
        aggregateHomeScore = match.aggregateHomeScore
        aggregateAwayScore = match.aggregateAwayScore
        firstLegHomeScore = match.firstLegHomeScore
        firstLegAwayScore = match.firstLegAwayScore
        scoreStatus = match.scoreStatus
        penaltyResult = match.penaltyResult
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeTeamId = "home_team_id"
        case awayTeamId = "away_team_id"
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
        case league
        case leagueSubcategory = "league_subcategory"
        case competitionWeight = "competition_weight"
        case matchDetailsIDValue = "match_details_id"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
        case firstLegHomeScore = "first_leg_home_score"
        case firstLegAwayScore = "first_leg_away_score"
        case scoreStatus = "score_status"
        case penaltyResult = "penalty_result"
    }
}

struct SharedMatchesPayload: Codable, Equatable, Sendable {
    let snapshot: PreferencesSnapshot
    let matches: [WidgetSharedMatchTransfer]
    let lastUpdated: Date?
    let generatedAt: Date

    nonisolated static func == (lhs: SharedMatchesPayload, rhs: SharedMatchesPayload) -> Bool {
        lhs.snapshot == rhs.snapshot &&
        lhs.matches == rhs.matches &&
        lhs.lastUpdated == rhs.lastUpdated
    }
}

private struct WatchSharedMatchesTransferPayload: Codable, Sendable {
    let snapshot: PreferencesSnapshot
    let matches: [WatchSharedMatchTransfer]
    let unfilteredMatches: [WatchSharedMatchTransfer]
    let lastUpdated: Date?
    let generatedAt: Date
}

private struct WatchSharedMatchTransfer: Codable, Sendable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeTeamId: String?
    let awayTeamId: String?
    let homeShortName: String?
    let awayShortName: String?
    let league: String
    let leagueSubcategory: String?
    let competitionWeight: Double?
    let matchDetailsIDValue: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let scoreStatus: String?
    let penaltyResult: String?

    init(_ match: Match) {
        date = match.date
        time = match.time
        homeTeam = match.homeTeam
        awayTeam = match.awayTeam
        homeTeamId = match.homeTeamId
        awayTeamId = match.awayTeamId
        homeShortName = match.homeShortName
        awayShortName = match.awayShortName
        league = match.league
        leagueSubcategory = match.leagueSubcategory
        competitionWeight = match.competitionWeight
        matchDetailsIDValue = match.matchDetailsID
        tvChannels = match.tvChannels.map(\.name)
        homeScore = match.homeScore
        awayScore = match.awayScore
        scoreStatus = match.scoreStatus
        penaltyResult = match.penaltyResult
    }

    init(_ match: WidgetSharedMatchTransfer) {
        date = match.date
        time = match.time
        homeTeam = match.homeTeam
        awayTeam = match.awayTeam
        homeTeamId = match.homeTeamId
        awayTeamId = match.awayTeamId
        homeShortName = match.homeShortName
        awayShortName = match.awayShortName
        league = match.league
        leagueSubcategory = match.leagueSubcategory
        competitionWeight = match.competitionWeight
        matchDetailsIDValue = match.matchDetailsIDValue
        tvChannels = match.tvChannels
        homeScore = match.homeScore
        awayScore = match.awayScore
        scoreStatus = match.scoreStatus
        penaltyResult = match.penaltyResult
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeTeamId = "home_team_id"
        case awayTeamId = "away_team_id"
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
        case league
        case leagueSubcategory = "league_subcategory"
        case competitionWeight = "competition_weight"
        case matchDetailsIDValue = "match_details_id"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case scoreStatus = "score_status"
        case penaltyResult = "penalty_result"
    }
}

struct FantasySharedImportPayload: Codable, Equatable, Sendable {
    let rawURL: String
    let updatedAt: TimeInterval

    nonisolated var trimmedRawURL: String {
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
    // Throttles widget reloads / watch transfers during rapid live-match updates
    // (e.g. goals/incidents), where the underlying payload can change every refresh tick.
    private static let minSyncInterval: TimeInterval = 30
    nonisolated static let widgetFixtureLimit = 80
    private static let watchFixtureLimit = 80
    private static let watchFixtureHistoryDays = 7
    private static let watchResultHistoryDays = 7
    private static let lock = NSLock()
    private static var lastSyncedAt: Date?

    nonisolated static func saveAndSync(matches: [Match], unfilteredMatches: [Match], lastUpdated: Date?, snapshot: PreferencesSnapshot) {
        let generatedAt = Date()
        let payload = makeWidgetPayload(
            matches: matches,
            unfilteredMatches: unfilteredMatches,
            lastUpdated: lastUpdated,
            snapshot: snapshot,
            generatedAt: generatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        let shouldPublish = shouldSync(payload)

        saveRawData(data)
        if let watchData = makeWatchTransferData(
            matches: matches,
            unfilteredMatches: unfilteredMatches,
            lastUpdated: lastUpdated,
            snapshot: snapshot,
            generatedAt: generatedAt,
            encoder: encoder
        ) {
            saveWatchTransferData(watchData)
        }
        saveSnapshotToSharedDefaults(snapshot)

        guard shouldPublish else { return }

        let now = Date()
        lock.lock()
        if let last = lastSyncedAt, now.timeIntervalSince(last) < minSyncInterval {
            lock.unlock()
            return
        }
        lastSyncedAt = now
        lock.unlock()

        WidgetCenter.shared.reloadAllTimelines()
        Task { @MainActor in
            PhoneWatchSyncService.shared.activate()
            PhoneWatchSyncService.shared.sendLatestPayload(loadWatchTransferData() ?? data)
        }
    }

    nonisolated static func makeWidgetPayload(
        matches: [Match],
        unfilteredMatches: [Match],
        lastUpdated: Date?,
        snapshot: PreferencesSnapshot,
        generatedAt: Date
    ) -> SharedMatchesPayload {
        let sourceMatches = snapshot.showAllMatches && !unfilteredMatches.isEmpty
            ? unfilteredMatches
            : matches
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: generatedAt)
        let compactMatches = sourceMatches
            .filter { match in
                guard !match.isFinished, let date = match.dateOnly else { return false }
                return calendar.startOfDay(for: date) >= today
            }
            .sorted(by: ascendingMatchDate)
            .prefix(widgetFixtureLimit)
            .map(WidgetSharedMatchTransfer.init)

        return SharedMatchesPayload(
            snapshot: snapshot,
            matches: compactMatches,
            lastUpdated: lastUpdated,
            generatedAt: generatedAt
        )
    }

    nonisolated static func loadRawData() -> Data? {
        guard let url = sharedFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated static func saveRawData(_ data: Data) {
        guard let url = sharedFileURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    nonisolated static func loadWatchTransferData() -> Data? {
        if let url = watchTransferFileURL,
           let data = try? Data(contentsOf: url) {
            return data
        }
        return makeWatchTransferDataFromCachedPayload()
    }

    private nonisolated static func saveWatchTransferData(_ data: Data) {
        guard let url = watchTransferFileURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private nonisolated static func shouldSync(_ payload: SharedMatchesPayload) -> Bool {
        guard let existing = loadPayload() else { return true }
        return existing != payload
    }

    private nonisolated static func loadPayload() -> SharedMatchesPayload? {
        guard let data = loadRawData() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedMatchesPayload.self, from: data)
    }

    nonisolated static func saveSnapshotToSharedDefaults(_ snapshot: PreferencesSnapshot) {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.set(snapshot.selectedLeagues, forKey: AppGroupConfig.selectedLeaguesKey)
        defaults.set(snapshot.selectedChannels, forKey: AppGroupConfig.selectedChannelsKey)
        defaults.set(snapshot.usesFixtureCompetitionSelection, forKey: AppGroupConfig.competitionFilterEnabledKey)
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

    nonisolated static func clear() {
        for url in [sharedFileURL, watchTransferFileURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private nonisolated static func makeWatchTransferData(
        matches: [Match],
        unfilteredMatches: [Match],
        lastUpdated: Date?,
        snapshot: PreferencesSnapshot,
        generatedAt: Date,
        encoder: JSONEncoder
    ) -> Data? {
        let payload = WatchSharedMatchesTransferPayload(
            snapshot: snapshot,
            matches: watchMatches(from: matches),
            unfilteredMatches: matches.isEmpty ? watchMatches(from: unfilteredMatches) : [],
            lastUpdated: lastUpdated,
            generatedAt: generatedAt
        )
        return try? encoder.encode(payload)
    }

    private nonisolated static func makeWatchTransferDataFromCachedPayload() -> Data? {
        guard let payload = loadPayload() else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let watchPayload = WatchSharedMatchesTransferPayload(
            snapshot: payload.snapshot,
            matches: payload.matches.map(WatchSharedMatchTransfer.init),
            unfilteredMatches: [],
            lastUpdated: payload.lastUpdated,
            generatedAt: payload.generatedAt
        )
        guard let data = try? encoder.encode(watchPayload) else { return nil }
        saveWatchTransferData(data)
        return data
    }

    private nonisolated static func watchMatches(from matches: [Match]) -> [WatchSharedMatchTransfer] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let fixtureEnd = calendar.date(
            byAdding: .day,
            value: watchFixtureHistoryDays,
            to: today
        ) ?? today
        let resultStart = calendar.date(
            byAdding: .day,
            value: 1 - watchResultHistoryDays,
            to: today
        ) ?? today

        let fixtures = matches
            .filter { match in
                guard let date = match.dateOnly else { return false }
                let day = calendar.startOfDay(for: date)
                return day >= today && day <= fixtureEnd && !match.isFinished
            }
            .sorted(by: ascendingMatchDate)
            .prefix(watchFixtureLimit)

        let results = matches
            .filter { match in
                guard let date = match.dateOnly else { return false }
                let day = calendar.startOfDay(for: date)
                return day >= resultStart && day <= today && match.isFinished
            }
            .sorted(by: descendingMatchDate)

        return (Array(fixtures) + results)
            .sorted(by: ascendingMatchDate)
            .map(WatchSharedMatchTransfer.init)
    }

    private nonisolated static func ascendingMatchDate(_ lhs: Match, _ rhs: Match) -> Bool {
        let leftDate = lhs.dateTime ?? lhs.dateOnly ?? .distantFuture
        let rightDate = rhs.dateTime ?? rhs.dateOnly ?? .distantFuture
        if leftDate != rightDate {
            return leftDate < rightDate
        }
        if lhs.competitionWeight != rhs.competitionWeight {
            return (lhs.competitionWeight ?? 0) > (rhs.competitionWeight ?? 0)
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func descendingMatchDate(_ lhs: Match, _ rhs: Match) -> Bool {
        let leftDate = lhs.dateTime ?? lhs.dateOnly ?? .distantPast
        let rightDate = rhs.dateTime ?? rhs.dateOnly ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        if lhs.competitionWeight != rhs.competitionWeight {
            return (lhs.competitionWeight ?? 0) > (rhs.competitionWeight ?? 0)
        }
        return lhs.id < rhs.id
    }

    private nonisolated static var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)?
            .appendingPathComponent(AppGroupConfig.sharedMatchesFileName)
    }

    private nonisolated static var watchTransferFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)?
            .appendingPathComponent(AppGroupConfig.watchSharedMatchesFileName)
    }
}
