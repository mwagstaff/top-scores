import Foundation
import Combine

enum MatchGroupSortOrder: String, Codable, CaseIterable, Identifiable {
    case alphabetical
    case teamScore
    case kickoffThenAlphabetical
    case kickoffThenTeamScore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical:
            return "Alphabetical"
        case .teamScore:
            return "Team score"
        case .kickoffThenAlphabetical:
            return "Kick-off then alphabetical"
        case .kickoffThenTeamScore:
            return "Kick-off then team score"
        }
    }

    var usesTeamScore: Bool {
        switch self {
        case .teamScore, .kickoffThenTeamScore:
            return true
        case .alphabetical, .kickoffThenAlphabetical:
            return false
        }
    }
}

struct PreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let competitionFilterEnabled: Bool
    let channelFilterEnabled: Bool
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
    let showAllMatches: Bool
    let matchGroupSortOrder: MatchGroupSortOrder
    let notificationsEnabled: Bool
    let notificationDelayMinutes: Int
    let notificationEventTypes: Set<String>
    let notificationUseViewingFilter: Bool
    let notificationCompetitionFilterEnabled: Bool
    let notificationSelectedLeagues: [String]
    let fantasyDeadlineRemindersEnabled: Bool
    let showTodayUnfinishedFixturesBadge: Bool
    let showFantasyMatchPills: Bool

    nonisolated init(
        selectedLeagues: [String],
        selectedChannels: [String],
        competitionFilterEnabled: Bool = PreferencesStore.defaultCompetitionFilterEnabled,
        channelFilterEnabled: Bool = PreferencesStore.defaultChannelFilterEnabled,
        englishPremierLeagueTeamsOnly: Bool,
        apiBaseURL: String,
        refreshIntervalMinutes: Int,
        showAllMatches: Bool = false,
        matchGroupSortOrder: MatchGroupSortOrder = PreferencesStore.defaultMatchGroupSortOrder,
        notificationsEnabled: Bool = PreferencesStore.defaultNotificationsEnabled,
        notificationDelayMinutes: Int = PreferencesStore.defaultNotificationDelayMinutes,
        notificationEventTypes: Set<String> = PreferencesStore.defaultNotificationEventTypes,
        notificationUseViewingFilter: Bool = PreferencesStore.defaultNotificationUseViewingFilter,
        notificationCompetitionFilterEnabled: Bool = PreferencesStore.defaultNotificationCompetitionFilterEnabled,
        notificationSelectedLeagues: [String] = PreferencesStore.defaultNotificationSelectedLeagues,
        fantasyDeadlineRemindersEnabled: Bool = PreferencesStore.defaultFantasyDeadlineRemindersEnabled,
        showTodayUnfinishedFixturesBadge: Bool = PreferencesStore.defaultShowTodayUnfinishedFixturesBadge,
        showFantasyMatchPills: Bool = PreferencesStore.defaultShowFantasyMatchPills
    ) {
        self.selectedLeagues = selectedLeagues
        self.selectedChannels = selectedChannels
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.showAllMatches = showAllMatches
        self.matchGroupSortOrder = matchGroupSortOrder
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = notificationDelayMinutes
        self.notificationEventTypes = notificationEventTypes
        self.notificationUseViewingFilter = notificationUseViewingFilter
        self.notificationCompetitionFilterEnabled = notificationCompetitionFilterEnabled
        self.notificationSelectedLeagues = notificationSelectedLeagues
        self.fantasyDeadlineRemindersEnabled = fantasyDeadlineRemindersEnabled
        self.showTodayUnfinishedFixturesBadge = showTodayUnfinishedFixturesBadge
        self.showFantasyMatchPills = showFantasyMatchPills
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
        case matchGroupSortOrder
        case notificationsEnabled
        case notificationDelayMinutes
        case notificationEventTypes
        case notificationUseViewingFilter
        case notificationCompetitionFilterEnabled
        case notificationSelectedLeagues
        case fantasyDeadlineRemindersEnabled
        case showTodayUnfinishedFixturesBadge
        case showFantasyMatchPills
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLeagues = try container.decode([String].self, forKey: .selectedLeagues)
        selectedChannels = try container.decode([String].self, forKey: .selectedChannels)
        competitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .competitionFilterEnabled) ?? PreferencesStore.defaultCompetitionFilterEnabled
        channelFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .channelFilterEnabled) ?? PreferencesStore.defaultChannelFilterEnabled
        englishPremierLeagueTeamsOnly = try container.decode(Bool.self, forKey: .englishPremierLeagueTeamsOnly)
        apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        refreshIntervalMinutes = try container.decode(Int.self, forKey: .refreshIntervalMinutes)
        showAllMatches = try container.decodeIfPresent(Bool.self, forKey: .showAllMatches) ?? false
        matchGroupSortOrder =
            try container.decodeIfPresent(MatchGroupSortOrder.self, forKey: .matchGroupSortOrder)
            ?? PreferencesStore.defaultMatchGroupSortOrder
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? PreferencesStore.defaultNotificationsEnabled
        notificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .notificationDelayMinutes) ?? PreferencesStore.defaultNotificationDelayMinutes
        let eventTypesArray = try container.decodeIfPresent([String].self, forKey: .notificationEventTypes)
        notificationEventTypes = eventTypesArray.map { Set($0) } ?? PreferencesStore.defaultNotificationEventTypes
        notificationUseViewingFilter = try container.decodeIfPresent(Bool.self, forKey: .notificationUseViewingFilter) ?? PreferencesStore.defaultNotificationUseViewingFilter
        notificationCompetitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationCompetitionFilterEnabled) ?? PreferencesStore.defaultNotificationCompetitionFilterEnabled
        notificationSelectedLeagues = try container.decodeIfPresent([String].self, forKey: .notificationSelectedLeagues) ?? PreferencesStore.defaultNotificationSelectedLeagues
        fantasyDeadlineRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .fantasyDeadlineRemindersEnabled) ?? PreferencesStore.defaultFantasyDeadlineRemindersEnabled
        showTodayUnfinishedFixturesBadge = try container.decodeIfPresent(Bool.self, forKey: .showTodayUnfinishedFixturesBadge) ?? PreferencesStore.defaultShowTodayUnfinishedFixturesBadge
        showFantasyMatchPills = try container.decodeIfPresent(Bool.self, forKey: .showFantasyMatchPills) ?? PreferencesStore.defaultShowFantasyMatchPills
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
    nonisolated static let defaultEnglishPremierLeagueTeamsOnly = true
    nonisolated static let defaultCompetitionFilterEnabled = false
    nonisolated static let defaultChannelFilterEnabled = false
    nonisolated static let defaultShowAllMatches = false
    nonisolated static let defaultMatchGroupSortOrder: MatchGroupSortOrder = .kickoffThenTeamScore
    nonisolated static let defaultNotificationsEnabled = true
    nonisolated static let defaultNotificationDelayMinutes = 2
    nonisolated static let defaultNotificationEventTypes: Set<String> = ["goal", "kickoff", "halftime", "fulltime", "redcard"]
    nonisolated static let defaultNotificationUseViewingFilter = true
    nonisolated static let defaultNotificationCompetitionFilterEnabled = true
    nonisolated static let defaultNotificationSelectedLeagues: [String] = []
    nonisolated static let defaultFantasyDeadlineRemindersEnabled = true
    nonisolated static let defaultShowTodayUnfinishedFixturesBadge = false
    nonisolated static let defaultShowFantasyMatchPills = true
    #if DEBUG
    nonisolated static let defaultShowPredictionRedoButton = false
    #endif

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

    @Published var matchGroupSortOrder: MatchGroupSortOrder {
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

    @Published var fantasyDeadlineRemindersEnabled: Bool {
        didSet { persist() }
    }

    @Published var showTodayUnfinishedFixturesBadge: Bool {
        didSet { persist() }
    }

    @Published var showFantasyMatchPills: Bool {
        didSet { persist() }
    }

    #if DEBUG
    @Published var showPredictionRedoButton: Bool {
        didSet { persist() }
    }
    #endif

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
        let matchGroupSortOrderRawValue = userDefaults.string(forKey: Keys.matchGroupSortOrder)
        let matchGroupSortOrder = matchGroupSortOrderRawValue
            .flatMap(MatchGroupSortOrder.init(rawValue:))
            ?? Self.defaultMatchGroupSortOrder
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
        let fantasyDeadlineRemindersEnabled = userDefaults.object(forKey: Keys.fantasyDeadlineRemindersEnabled) as? Bool
            ?? Self.defaultFantasyDeadlineRemindersEnabled
        let showTodayUnfinishedFixturesBadge = userDefaults.object(forKey: Keys.showTodayUnfinishedFixturesBadge) as? Bool
            ?? Self.defaultShowTodayUnfinishedFixturesBadge
        let showFantasyMatchPills = userDefaults.object(forKey: Keys.showFantasyMatchPills) as? Bool
            ?? Self.defaultShowFantasyMatchPills
        #if DEBUG
        let showPredictionRedoButton = userDefaults.object(forKey: Keys.showPredictionRedoButton) as? Bool
            ?? Self.defaultShowPredictionRedoButton
        #endif

        self.selectedLeagues = leagues
        self.selectedChannels = ChannelSelection.normalizedSelectedOptions(channels)
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = max(1, refreshInterval)
        self.showAllMatches = showAllMatches
        self.matchGroupSortOrder = matchGroupSortOrder
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = max(0, min(10, notificationDelayMinutes))
        self.notificationEventTypes = notificationEventTypes
        self.notificationUseViewingFilter = notificationUseViewingFilter
        self.notificationCompetitionFilterEnabled = notificationCompetitionFilterEnabled
        self.notificationSelectedLeagues = notificationSelectedLeagues
        self.fantasyDeadlineRemindersEnabled = fantasyDeadlineRemindersEnabled
        self.showTodayUnfinishedFixturesBadge = showTodayUnfinishedFixturesBadge
        self.showFantasyMatchPills = showFantasyMatchPills
        #if DEBUG
        self.showPredictionRedoButton = showPredictionRedoButton
        #endif

        if !showTodayUnfinishedFixturesBadge {
            Task {
                await AppIconBadgeManager.clear()
            }
        }
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
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            showFantasyMatchPills: showFantasyMatchPills
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
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            showFantasyMatchPills: showFantasyMatchPills
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
        userDefaults.set(matchGroupSortOrder.rawValue, forKey: Keys.matchGroupSortOrder)
        userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        userDefaults.set(notificationDelayMinutes, forKey: Keys.notificationDelayMinutes)
        userDefaults.set(Array(notificationEventTypes), forKey: Keys.notificationEventTypes)
        userDefaults.set(notificationUseViewingFilter, forKey: Keys.notificationUseViewingFilter)
        userDefaults.set(notificationCompetitionFilterEnabled, forKey: Keys.notificationCompetitionFilterEnabled)
        userDefaults.set(notificationSelectedLeagues, forKey: Keys.notificationSelectedLeagues)
        userDefaults.set(fantasyDeadlineRemindersEnabled, forKey: Keys.fantasyDeadlineRemindersEnabled)
        userDefaults.set(showTodayUnfinishedFixturesBadge, forKey: Keys.showTodayUnfinishedFixturesBadge)
        userDefaults.set(showFantasyMatchPills, forKey: Keys.showFantasyMatchPills)
        #if DEBUG
        userDefaults.set(showPredictionRedoButton, forKey: Keys.showPredictionRedoButton)
        #endif
        SharedMatchesBridge.saveSnapshotToSharedDefaults(snapshot)

        if !showTodayUnfinishedFixturesBadge {
            Task {
                await AppIconBadgeManager.clear()
            }
        }

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
        let matchGroupSortOrderRawValue = userDefaults.string(forKey: Keys.matchGroupSortOrder)
        let matchGroupSortOrder = matchGroupSortOrderRawValue
            .flatMap(MatchGroupSortOrder.init(rawValue:))
            ?? Self.defaultMatchGroupSortOrder
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
        let fantasyDeadlineRemindersEnabled = userDefaults.object(forKey: Keys.fantasyDeadlineRemindersEnabled) as? Bool
            ?? Self.defaultFantasyDeadlineRemindersEnabled
        let showTodayUnfinishedFixturesBadge = userDefaults.object(forKey: Keys.showTodayUnfinishedFixturesBadge) as? Bool
            ?? Self.defaultShowTodayUnfinishedFixturesBadge
        let showFantasyMatchPills = userDefaults.object(forKey: Keys.showFantasyMatchPills) as? Bool
            ?? Self.defaultShowFantasyMatchPills

        return PreferencesSnapshot(
            selectedLeagues: leagues,
            selectedChannels: ChannelSelection.normalizedSelectedOptions(channels),
            competitionFilterEnabled: competitionFilterEnabled,
            channelFilterEnabled: channelFilterEnabled,
            englishPremierLeagueTeamsOnly: englishPremierLeagueTeamsOnly,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: max(1, refreshInterval),
            showAllMatches: showAllMatches,
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: max(0, min(10, notificationDelayMinutes)),
            notificationEventTypes: notificationEventTypes,
            notificationUseViewingFilter: notificationUseViewingFilter,
            notificationCompetitionFilterEnabled: notificationCompetitionFilterEnabled,
            notificationSelectedLeagues: notificationSelectedLeagues,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            showFantasyMatchPills: showFantasyMatchPills
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
        static let matchGroupSortOrder = "preferences.matchGroupSortOrder"
        static let notificationsEnabled = "preferences.notificationsEnabled"
        static let notificationDelayMinutes = "preferences.notificationDelayMinutes"
        static let notificationEventTypes = "preferences.notificationEventTypes"
        static let notificationUseViewingFilter = "preferences.notificationUseViewingFilter"
        static let notificationCompetitionFilterEnabled = "preferences.notificationCompetitionFilterEnabled"
        static let notificationSelectedLeagues = "preferences.notificationSelectedLeagues"
        static let fantasyDeadlineRemindersEnabled = "preferences.fantasyDeadlineRemindersEnabled"
        static let showTodayUnfinishedFixturesBadge = "preferences.showTodayUnfinishedFixturesBadge"
        static let showFantasyMatchPills = "preferences.showFantasyMatchPills"
        #if DEBUG
        static let showPredictionRedoButton = "preferences.showPredictionRedoButton"
        #endif
    }
}
