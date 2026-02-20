import Foundation
import Combine

struct PreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let competitionFilterEnabled: Bool
    let channelFilterEnabled: Bool
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
    let showAllMatches: Bool
    let notificationsEnabled: Bool
    let notificationDelayMinutes: Int
    let notificationEventTypes: Set<String>
    let notificationUseViewingFilter: Bool
    let notificationCompetitionFilterEnabled: Bool
    let notificationSelectedLeagues: [String]

    nonisolated init(
        selectedLeagues: [String],
        selectedChannels: [String],
        competitionFilterEnabled: Bool = true,
        channelFilterEnabled: Bool = true,
        englishPremierLeagueTeamsOnly: Bool,
        apiBaseURL: String,
        refreshIntervalMinutes: Int,
        showAllMatches: Bool = false,
        notificationsEnabled: Bool = false,
        notificationDelayMinutes: Int = 0,
        notificationEventTypes: Set<String> = PreferencesStore.defaultNotificationEventTypes,
        notificationUseViewingFilter: Bool = true,
        notificationCompetitionFilterEnabled: Bool = true,
        notificationSelectedLeagues: [String] = []
    ) {
        self.selectedLeagues = selectedLeagues
        self.selectedChannels = selectedChannels
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.showAllMatches = showAllMatches
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = notificationDelayMinutes
        self.notificationEventTypes = notificationEventTypes
        self.notificationUseViewingFilter = notificationUseViewingFilter
        self.notificationCompetitionFilterEnabled = notificationCompetitionFilterEnabled
        self.notificationSelectedLeagues = notificationSelectedLeagues
    }

    enum CodingKeys: String, CodingKey {
        case selectedLeagues
        case selectedChannels
        case competitionFilterEnabled
        case channelFilterEnabled
        case englishPremierLeagueTeamsOnly
        case apiBaseURL
        case refreshIntervalMinutes
        case showAllMatches
        case notificationsEnabled
        case notificationDelayMinutes
        case notificationEventTypes
        case notificationUseViewingFilter
        case notificationCompetitionFilterEnabled
        case notificationSelectedLeagues
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLeagues = try container.decode([String].self, forKey: .selectedLeagues)
        selectedChannels = try container.decode([String].self, forKey: .selectedChannels)
        competitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .competitionFilterEnabled) ?? true
        channelFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .channelFilterEnabled) ?? true
        englishPremierLeagueTeamsOnly = try container.decode(Bool.self, forKey: .englishPremierLeagueTeamsOnly)
        apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        refreshIntervalMinutes = try container.decode(Int.self, forKey: .refreshIntervalMinutes)
        showAllMatches = try container.decodeIfPresent(Bool.self, forKey: .showAllMatches) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        notificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .notificationDelayMinutes) ?? 0
        let eventTypesArray = try container.decodeIfPresent([String].self, forKey: .notificationEventTypes)
        notificationEventTypes = eventTypesArray.map { Set($0) } ?? PreferencesStore.defaultNotificationEventTypes
        notificationUseViewingFilter = try container.decodeIfPresent(Bool.self, forKey: .notificationUseViewingFilter) ?? true
        notificationCompetitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationCompetitionFilterEnabled) ?? true
        notificationSelectedLeagues = try container.decodeIfPresent([String].self, forKey: .notificationSelectedLeagues) ?? []
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    nonisolated static let defaultSelectedLeagues = [
        "Premier League",
        "FIFA World Cup 2026",
        "UEFA Champions League",
        "UEFA Conference League",
        "UEFA Europa League"
    ]
    nonisolated static let productionApiBaseURL = "https://api.skynolimit.dev/top-scores/api/v1"
    nonisolated static let developmentApiBaseURL = "http://Mikes-MacBook-Air.local:3011/api/v1"
    nonisolated static let defaultApiBaseURL = productionApiBaseURL
    nonisolated static let defaultRefreshIntervalMinutes = 10
    nonisolated static let defaultSelectedChannels = ["Amazon (all)", "BBC (all)", "ITV (all)", "Sky (all)", "TNT (all)"]
    nonisolated static let defaultEnglishPremierLeagueTeamsOnly = false
    nonisolated static let defaultCompetitionFilterEnabled = true
    nonisolated static let defaultChannelFilterEnabled = true
    nonisolated static let defaultShowAllMatches = false
    nonisolated static let defaultNotificationsEnabled = false
    nonisolated static let defaultNotificationDelayMinutes = 0
    nonisolated static let defaultNotificationEventTypes: Set<String> = ["goal", "kickoff", "halftime", "fulltime", "redcard"]
    nonisolated static let defaultNotificationUseViewingFilter = true
    nonisolated static let defaultNotificationCompetitionFilterEnabled = true
    nonisolated static let defaultNotificationSelectedLeagues: [String] = []

    @Published var selectedLeagues: [String] {
        didSet { persist() }
    }

    @Published var selectedChannels: [String] {
        didSet { persist() }
    }

    @Published var competitionFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var channelFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var englishPremierLeagueTeamsOnly: Bool {
        didSet { persist() }
    }

    @Published var apiBaseURL: String {
        didSet { persist() }
    }

    @Published var refreshIntervalMinutes: Int {
        didSet { persist() }
    }

    @Published var showAllMatches: Bool {
        didSet { persist() }
    }

    @Published var notificationsEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationDelayMinutes: Int {
        didSet { persist() }
    }

    @Published var notificationEventTypes: Set<String> {
        didSet { persist() }
    }

    @Published var notificationUseViewingFilter: Bool {
        didSet { persist() }
    }

    @Published var notificationCompetitionFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationSelectedLeagues: [String] {
        didSet { persist() }
    }

    init(userDefaults: UserDefaults = .standard) {
        let leagues = userDefaults.stringArray(forKey: Keys.selectedLeagues) ?? Self.defaultSelectedLeagues
        let channels = userDefaults.stringArray(forKey: Keys.selectedChannels) ?? Self.defaultSelectedChannels
        let competitionFilterEnabled = userDefaults.object(forKey: Keys.competitionFilterEnabled) as? Bool
            ?? Self.defaultCompetitionFilterEnabled
        let channelFilterEnabled = userDefaults.object(forKey: Keys.channelFilterEnabled) as? Bool
            ?? Self.defaultChannelFilterEnabled
        let englishPremierLeagueTeamsOnly = userDefaults.object(forKey: Keys.englishPremierLeagueTeamsOnly) as? Bool
            ?? Self.defaultEnglishPremierLeagueTeamsOnly
        let apiBaseURL = userDefaults.string(forKey: Keys.apiBaseURL) ?? Self.defaultApiBaseURL
        let refreshInterval = userDefaults.object(forKey: Keys.refreshIntervalMinutes) as? Int
            ?? Self.defaultRefreshIntervalMinutes
        let showAllMatches = userDefaults.object(forKey: Keys.showAllMatches) as? Bool
            ?? Self.defaultShowAllMatches
        let notificationsEnabled = userDefaults.object(forKey: Keys.notificationsEnabled) as? Bool
            ?? Self.defaultNotificationsEnabled
        let notificationDelayMinutes = userDefaults.object(forKey: Keys.notificationDelayMinutes) as? Int
            ?? Self.defaultNotificationDelayMinutes
        let notificationEventTypesArray = userDefaults.stringArray(forKey: Keys.notificationEventTypes)
        let notificationEventTypes = notificationEventTypesArray.map { Set($0) } ?? Self.defaultNotificationEventTypes
        let notificationUseViewingFilter = userDefaults.object(forKey: Keys.notificationUseViewingFilter) as? Bool
            ?? Self.defaultNotificationUseViewingFilter
        let notificationCompetitionFilterEnabled = userDefaults.object(forKey: Keys.notificationCompetitionFilterEnabled) as? Bool
            ?? Self.defaultNotificationCompetitionFilterEnabled
        let notificationSelectedLeagues = userDefaults.stringArray(forKey: Keys.notificationSelectedLeagues)
            ?? Self.defaultNotificationSelectedLeagues

        self.selectedLeagues = leagues
        self.selectedChannels = ChannelSelection.normalizedSelectedOptions(channels)
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = max(1, refreshInterval)
        self.showAllMatches = showAllMatches
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = max(0, min(10, notificationDelayMinutes))
        self.notificationEventTypes = notificationEventTypes
        self.notificationUseViewingFilter = notificationUseViewingFilter
        self.notificationCompetitionFilterEnabled = notificationCompetitionFilterEnabled
        self.notificationSelectedLeagues = notificationSelectedLeagues
    }

    var snapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: selectedLeagues,
            selectedChannels: selectedChannels,
            competitionFilterEnabled: competitionFilterEnabled,
            channelFilterEnabled: channelFilterEnabled,
            englishPremierLeagueTeamsOnly: englishPremierLeagueTeamsOnly,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            showAllMatches: showAllMatches,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues
        )
    }

    var unfilteredSnapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: selectedLeagues,
            selectedChannels: selectedChannels,
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            showAllMatches: showAllMatches,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues
        )
    }

    func persist(userDefaults: UserDefaults = .standard) {
        userDefaults.set(selectedLeagues, forKey: Keys.selectedLeagues)
        userDefaults.set(selectedChannels, forKey: Keys.selectedChannels)
        userDefaults.set(competitionFilterEnabled, forKey: Keys.competitionFilterEnabled)
        userDefaults.set(channelFilterEnabled, forKey: Keys.channelFilterEnabled)
        userDefaults.set(englishPremierLeagueTeamsOnly, forKey: Keys.englishPremierLeagueTeamsOnly)
        userDefaults.set(apiBaseURL, forKey: Keys.apiBaseURL)
        userDefaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
        userDefaults.set(showAllMatches, forKey: Keys.showAllMatches)
        userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        userDefaults.set(notificationDelayMinutes, forKey: Keys.notificationDelayMinutes)
        userDefaults.set(Array(notificationEventTypes), forKey: Keys.notificationEventTypes)
        userDefaults.set(notificationUseViewingFilter, forKey: Keys.notificationUseViewingFilter)
        userDefaults.set(notificationCompetitionFilterEnabled, forKey: Keys.notificationCompetitionFilterEnabled)
        userDefaults.set(notificationSelectedLeagues, forKey: Keys.notificationSelectedLeagues)
        SharedMatchesBridge.saveSnapshotToSharedDefaults(snapshot)

        // Sync preferences to Redis
        Task {
            await PreferencesSyncService.shared.syncPreferences(snapshot)
        }
    }

    static func loadSnapshot(userDefaults: UserDefaults = .standard) -> PreferencesSnapshot {
        let leagues = userDefaults.stringArray(forKey: Keys.selectedLeagues) ?? Self.defaultSelectedLeagues
        let channels = userDefaults.stringArray(forKey: Keys.selectedChannels) ?? Self.defaultSelectedChannels
        let competitionFilterEnabled = userDefaults.object(forKey: Keys.competitionFilterEnabled) as? Bool
            ?? Self.defaultCompetitionFilterEnabled
        let channelFilterEnabled = userDefaults.object(forKey: Keys.channelFilterEnabled) as? Bool
            ?? Self.defaultChannelFilterEnabled
        let englishPremierLeagueTeamsOnly = userDefaults.object(forKey: Keys.englishPremierLeagueTeamsOnly) as? Bool
            ?? Self.defaultEnglishPremierLeagueTeamsOnly
        let apiBaseURL = userDefaults.string(forKey: Keys.apiBaseURL) ?? Self.defaultApiBaseURL
        let refreshInterval = userDefaults.object(forKey: Keys.refreshIntervalMinutes) as? Int
            ?? Self.defaultRefreshIntervalMinutes
        let showAllMatches = userDefaults.object(forKey: Keys.showAllMatches) as? Bool
            ?? Self.defaultShowAllMatches
        let notificationsEnabled = userDefaults.object(forKey: Keys.notificationsEnabled) as? Bool
            ?? Self.defaultNotificationsEnabled
        let notificationDelayMinutes = userDefaults.object(forKey: Keys.notificationDelayMinutes) as? Int
            ?? Self.defaultNotificationDelayMinutes
        let notificationEventTypesArray = userDefaults.stringArray(forKey: Keys.notificationEventTypes)
        let notificationEventTypes = notificationEventTypesArray.map { Set($0) } ?? Self.defaultNotificationEventTypes
        let notificationUseViewingFilter = userDefaults.object(forKey: Keys.notificationUseViewingFilter) as? Bool
            ?? Self.defaultNotificationUseViewingFilter
        let notificationCompetitionFilterEnabled = userDefaults.object(forKey: Keys.notificationCompetitionFilterEnabled) as? Bool
            ?? Self.defaultNotificationCompetitionFilterEnabled
        let notificationSelectedLeagues = userDefaults.stringArray(forKey: Keys.notificationSelectedLeagues)
            ?? Self.defaultNotificationSelectedLeagues

        return PreferencesSnapshot(
            selectedLeagues: leagues,
            selectedChannels: ChannelSelection.normalizedSelectedOptions(channels),
            competitionFilterEnabled: competitionFilterEnabled,
            channelFilterEnabled: channelFilterEnabled,
            englishPremierLeagueTeamsOnly: englishPremierLeagueTeamsOnly,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: max(1, refreshInterval),
            showAllMatches: showAllMatches,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: max(0, min(10, notificationDelayMinutes)),
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues
        )
    }

    private enum Keys {
        static let selectedLeagues = "preferences.selectedLeagues"
        static let selectedChannels = "preferences.selectedChannels"
        static let competitionFilterEnabled = "preferences.competitionFilterEnabled"
        static let channelFilterEnabled = "preferences.channelFilterEnabled"
        static let englishPremierLeagueTeamsOnly = "preferences.englishPremierLeagueTeamsOnly"
        static let apiBaseURL = "preferences.apiBaseURL"
        static let refreshIntervalMinutes = "preferences.refreshIntervalMinutes"
        static let showAllMatches = "preferences.showAllMatches"
        static let notificationsEnabled = "preferences.notificationsEnabled"
        static let notificationDelayMinutes = "preferences.notificationDelayMinutes"
        static let notificationEventTypes = "preferences.notificationEventTypes"
        static let notificationUseViewingFilter = "preferences.notificationUseViewingFilter"
        static let notificationCompetitionFilterEnabled = "preferences.notificationCompetitionFilterEnabled"
        static let notificationSelectedLeagues = "preferences.notificationSelectedLeagues"
    }
}
