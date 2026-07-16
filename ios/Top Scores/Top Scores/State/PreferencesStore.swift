import Foundation
import Combine

enum MatchGroupSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum FixturesViewDensity: String, Codable, Sendable {
    case compact

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = FixturesViewDensity(rawValue: rawValue) ?? .compact
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PreferencesSnapshot: Codable, Equatable, Sendable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let competitionFilterEnabled: Bool
    let channelFilterEnabled: Bool
    let englishPremierLeagueTeamsOnly: Bool
    let majorUEFAClubGamesEnabled: Bool
    let homeNationsFilterEnabled: Bool
    let majorTournamentsFilterEnabled: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
    let showAllMatches: Bool
    let matchGroupSortOrder: MatchGroupSortOrder
    let notificationsEnabled: Bool
    let notificationDelayMinutes: Int
    let notificationEventTypes: Set<String>
    let notificationPremierLeagueTeamsOnly: Bool
    let notificationMajorUEFAClubGamesEnabled: Bool
    let notificationHomeNationsFilterEnabled: Bool
    let notificationMajorTournamentsFilterEnabled: Bool
    let fantasyDeadlineRemindersEnabled: Bool
    let showTodayUnfinishedFixturesBadge: Bool
    let fixturesViewDensity: FixturesViewDensity
    let showCompactFixtureTvLogo: Bool
    let showCompactFixtureFantasyLogo: Bool
    let showKickoffTimeDividers: Bool
    let showFantasyFixtureLogos: Bool
    let showFantasyExpectedPoints: Bool
    let showFantasyRealTimePoints: Bool
    let premierLeagueMatchesFirst: Bool
    let showPostponedGames: Bool

    nonisolated var showsFantasyDataInFixtures: Bool {
        showFantasyFixtureLogos || showFantasyExpectedPoints || showFantasyRealTimePoints
    }

    nonisolated var effectiveEnglishPremierLeagueTeamsOnly: Bool {
        englishPremierLeagueTeamsOnly
    }

    nonisolated var effectiveMajorUEFAClubGamesEnabled: Bool {
        englishPremierLeagueTeamsOnly && majorUEFAClubGamesEnabled
    }

    nonisolated var effectiveHomeNationsFilterEnabled: Bool {
        englishPremierLeagueTeamsOnly && homeNationsFilterEnabled
    }

    nonisolated var effectiveMajorTournamentsFilterEnabled: Bool {
        englishPremierLeagueTeamsOnly && majorTournamentsFilterEnabled
    }

    nonisolated init(
        selectedLeagues: [String],
        selectedChannels: [String],
        competitionFilterEnabled: Bool = PreferencesStore.defaultCompetitionFilterEnabled,
        channelFilterEnabled: Bool = PreferencesStore.defaultChannelFilterEnabled,
        englishPremierLeagueTeamsOnly: Bool,
        majorUEFAClubGamesEnabled: Bool = PreferencesStore.defaultMajorUEFAClubGamesEnabled,
        homeNationsFilterEnabled: Bool = PreferencesStore.defaultHomeNationsFilterEnabled,
        majorTournamentsFilterEnabled: Bool = PreferencesStore.defaultMajorTournamentsFilterEnabled,
        apiBaseURL: String,
        refreshIntervalMinutes: Int,
        showAllMatches: Bool = false,
        matchGroupSortOrder: MatchGroupSortOrder = PreferencesStore.defaultMatchGroupSortOrder,
        notificationsEnabled: Bool = PreferencesStore.defaultNotificationsEnabled,
        notificationDelayMinutes: Int = PreferencesStore.defaultNotificationDelayMinutes,
        notificationEventTypes: Set<String> = PreferencesStore.defaultNotificationEventTypes,
        notificationPremierLeagueTeamsOnly: Bool = PreferencesStore.defaultNotificationPremierLeagueTeamsOnly,
        notificationMajorUEFAClubGamesEnabled: Bool = PreferencesStore.defaultNotificationMajorUEFAClubGamesEnabled,
        notificationHomeNationsFilterEnabled: Bool = PreferencesStore.defaultNotificationHomeNationsFilterEnabled,
        notificationMajorTournamentsFilterEnabled: Bool = PreferencesStore.defaultNotificationMajorTournamentsFilterEnabled,
        fantasyDeadlineRemindersEnabled: Bool = PreferencesStore.defaultFantasyDeadlineRemindersEnabled,
        showTodayUnfinishedFixturesBadge: Bool = PreferencesStore.defaultShowTodayUnfinishedFixturesBadge,
        fixturesViewDensity: FixturesViewDensity = PreferencesStore.defaultFixturesViewDensity,
        showCompactFixtureTvLogo: Bool = PreferencesStore.defaultShowCompactFixtureTvLogo,
        showCompactFixtureFantasyLogo: Bool = PreferencesStore.defaultShowCompactFixtureFantasyLogo,
        showKickoffTimeDividers: Bool = PreferencesStore.defaultShowKickoffTimeDividers,
        showFantasyFixtureLogos: Bool = PreferencesStore.defaultShowFantasyFixtureLogos,
        showFantasyExpectedPoints: Bool = PreferencesStore.defaultShowFantasyExpectedPoints,
        showFantasyRealTimePoints: Bool = PreferencesStore.defaultShowFantasyRealTimePoints,
        premierLeagueMatchesFirst: Bool = PreferencesStore.defaultPremierLeagueMatchesFirst,
        showPostponedGames: Bool = PreferencesStore.defaultShowPostponedGames
    ) {
        self.selectedLeagues = selectedLeagues
        self.selectedChannels = selectedChannels
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.majorUEFAClubGamesEnabled = majorUEFAClubGamesEnabled
        self.homeNationsFilterEnabled = homeNationsFilterEnabled
        self.majorTournamentsFilterEnabled = majorTournamentsFilterEnabled
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.showAllMatches = showAllMatches
        self.matchGroupSortOrder = matchGroupSortOrder
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = notificationDelayMinutes
        self.notificationEventTypes = notificationEventTypes
        self.notificationPremierLeagueTeamsOnly = notificationPremierLeagueTeamsOnly
        self.notificationMajorUEFAClubGamesEnabled = notificationMajorUEFAClubGamesEnabled
        self.notificationHomeNationsFilterEnabled = notificationHomeNationsFilterEnabled
        self.notificationMajorTournamentsFilterEnabled = notificationMajorTournamentsFilterEnabled
        self.fantasyDeadlineRemindersEnabled = fantasyDeadlineRemindersEnabled
        self.showTodayUnfinishedFixturesBadge = showTodayUnfinishedFixturesBadge
        self.fixturesViewDensity = fixturesViewDensity
        self.showCompactFixtureTvLogo = showCompactFixtureTvLogo
        self.showCompactFixtureFantasyLogo = showCompactFixtureFantasyLogo
        self.showKickoffTimeDividers = showKickoffTimeDividers
        self.showFantasyFixtureLogos = showFantasyFixtureLogos
        self.showFantasyExpectedPoints = showFantasyExpectedPoints
        self.showFantasyRealTimePoints = showFantasyRealTimePoints
        self.premierLeagueMatchesFirst = premierLeagueMatchesFirst
        self.showPostponedGames = showPostponedGames
    }

    enum CodingKeys: String, CodingKey {
        case selectedLeagues
        case selectedChannels
        case competitionFilterEnabled
        case channelFilterEnabled
        case englishPremierLeagueTeamsOnly
        case majorUEFAClubGamesEnabled
        case homeNationsFilterEnabled
        case majorTournamentsFilterEnabled
        case apiBaseURL
        case refreshIntervalMinutes
        case showAllMatches
        case matchGroupSortOrder
        case notificationsEnabled
        case notificationDelayMinutes
        case notificationEventTypes
        case notificationPremierLeagueTeamsOnly
        case notificationMajorUEFAClubGamesEnabled
        case notificationHomeNationsFilterEnabled
        case notificationMajorTournamentsFilterEnabled
        case fantasyDeadlineRemindersEnabled
        case showTodayUnfinishedFixturesBadge
        case fixturesViewDensity
        case showCompactFixtureTvLogo
        case showCompactFixtureFantasyLogo
        case showKickoffTimeDividers
        case showFantasyFixtureLogos
        case showFantasyExpectedPoints
        case showFantasyRealTimePoints
        case premierLeagueMatchesFirst
        case showPostponedGames
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case showFantasyMatchPills
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLeagues = try container.decode([String].self, forKey: .selectedLeagues)
        selectedChannels = try container.decode([String].self, forKey: .selectedChannels)
        competitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .competitionFilterEnabled) ?? PreferencesStore.defaultCompetitionFilterEnabled
        channelFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .channelFilterEnabled) ?? PreferencesStore.defaultChannelFilterEnabled
        englishPremierLeagueTeamsOnly = try container.decode(Bool.self, forKey: .englishPremierLeagueTeamsOnly)
        majorUEFAClubGamesEnabled = try container.decodeIfPresent(Bool.self, forKey: .majorUEFAClubGamesEnabled) ?? PreferencesStore.defaultMajorUEFAClubGamesEnabled
        homeNationsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .homeNationsFilterEnabled) ?? PreferencesStore.defaultHomeNationsFilterEnabled
        majorTournamentsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .majorTournamentsFilterEnabled) ?? PreferencesStore.defaultMajorTournamentsFilterEnabled
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
        notificationPremierLeagueTeamsOnly = try container.decodeIfPresent(Bool.self, forKey: .notificationPremierLeagueTeamsOnly) ?? PreferencesStore.defaultNotificationPremierLeagueTeamsOnly
        notificationMajorUEFAClubGamesEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationMajorUEFAClubGamesEnabled) ?? PreferencesStore.defaultNotificationMajorUEFAClubGamesEnabled
        notificationHomeNationsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationHomeNationsFilterEnabled) ?? PreferencesStore.defaultNotificationHomeNationsFilterEnabled
        notificationMajorTournamentsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationMajorTournamentsFilterEnabled) ?? PreferencesStore.defaultNotificationMajorTournamentsFilterEnabled
        fantasyDeadlineRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .fantasyDeadlineRemindersEnabled) ?? PreferencesStore.defaultFantasyDeadlineRemindersEnabled
        showTodayUnfinishedFixturesBadge = try container.decodeIfPresent(Bool.self, forKey: .showTodayUnfinishedFixturesBadge) ?? PreferencesStore.defaultShowTodayUnfinishedFixturesBadge
        fixturesViewDensity = try container.decodeIfPresent(FixturesViewDensity.self, forKey: .fixturesViewDensity) ?? PreferencesStore.defaultFixturesViewDensity
        showCompactFixtureTvLogo = try container.decodeIfPresent(Bool.self, forKey: .showCompactFixtureTvLogo) ?? PreferencesStore.defaultShowCompactFixtureTvLogo
        showCompactFixtureFantasyLogo = try container.decodeIfPresent(Bool.self, forKey: .showCompactFixtureFantasyLogo) ?? PreferencesStore.defaultShowCompactFixtureFantasyLogo
        showKickoffTimeDividers = try container.decodeIfPresent(Bool.self, forKey: .showKickoffTimeDividers) ?? PreferencesStore.defaultShowKickoffTimeDividers
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyShowFantasyMatchPills =
            try legacyContainer.decodeIfPresent(Bool.self, forKey: .showFantasyMatchPills)
            ?? PreferencesStore.defaultShowFantasyMatchPills
        showFantasyFixtureLogos = try container.decodeIfPresent(Bool.self, forKey: .showFantasyFixtureLogos) ?? legacyShowFantasyMatchPills
        showFantasyExpectedPoints = try container.decodeIfPresent(Bool.self, forKey: .showFantasyExpectedPoints) ?? legacyShowFantasyMatchPills
        showFantasyRealTimePoints = try container.decodeIfPresent(Bool.self, forKey: .showFantasyRealTimePoints) ?? legacyShowFantasyMatchPills
        premierLeagueMatchesFirst = try container.decodeIfPresent(Bool.self, forKey: .premierLeagueMatchesFirst) ?? PreferencesStore.defaultPremierLeagueMatchesFirst
        showPostponedGames = try container.decodeIfPresent(Bool.self, forKey: .showPostponedGames) ?? PreferencesStore.defaultShowPostponedGames
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedLeagues, forKey: .selectedLeagues)
        try container.encode(selectedChannels, forKey: .selectedChannels)
        try container.encode(competitionFilterEnabled, forKey: .competitionFilterEnabled)
        try container.encode(channelFilterEnabled, forKey: .channelFilterEnabled)
        try container.encode(englishPremierLeagueTeamsOnly, forKey: .englishPremierLeagueTeamsOnly)
        try container.encode(majorUEFAClubGamesEnabled, forKey: .majorUEFAClubGamesEnabled)
        try container.encode(homeNationsFilterEnabled, forKey: .homeNationsFilterEnabled)
        try container.encode(majorTournamentsFilterEnabled, forKey: .majorTournamentsFilterEnabled)
        try container.encode(apiBaseURL, forKey: .apiBaseURL)
        try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
        try container.encode(showAllMatches, forKey: .showAllMatches)
        try container.encode(matchGroupSortOrder, forKey: .matchGroupSortOrder)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(notificationDelayMinutes, forKey: .notificationDelayMinutes)
        try container.encode(Array(notificationEventTypes).sorted(), forKey: .notificationEventTypes)
        try container.encode(notificationPremierLeagueTeamsOnly, forKey: .notificationPremierLeagueTeamsOnly)
        try container.encode(notificationMajorUEFAClubGamesEnabled, forKey: .notificationMajorUEFAClubGamesEnabled)
        try container.encode(notificationHomeNationsFilterEnabled, forKey: .notificationHomeNationsFilterEnabled)
        try container.encode(notificationMajorTournamentsFilterEnabled, forKey: .notificationMajorTournamentsFilterEnabled)
        try container.encode(fantasyDeadlineRemindersEnabled, forKey: .fantasyDeadlineRemindersEnabled)
        try container.encode(showTodayUnfinishedFixturesBadge, forKey: .showTodayUnfinishedFixturesBadge)
        try container.encode(fixturesViewDensity, forKey: .fixturesViewDensity)
        try container.encode(showCompactFixtureTvLogo, forKey: .showCompactFixtureTvLogo)
        try container.encode(showCompactFixtureFantasyLogo, forKey: .showCompactFixtureFantasyLogo)
        try container.encode(showKickoffTimeDividers, forKey: .showKickoffTimeDividers)
        try container.encode(showFantasyFixtureLogos, forKey: .showFantasyFixtureLogos)
        try container.encode(showFantasyExpectedPoints, forKey: .showFantasyExpectedPoints)
        try container.encode(showFantasyRealTimePoints, forKey: .showFantasyRealTimePoints)
        try container.encode(premierLeagueMatchesFirst, forKey: .premierLeagueMatchesFirst)
        try container.encode(showPostponedGames, forKey: .showPostponedGames)
    }

    nonisolated static func == (lhs: PreferencesSnapshot, rhs: PreferencesSnapshot) -> Bool {
        lhs.selectedLeagues == rhs.selectedLeagues &&
        lhs.selectedChannels == rhs.selectedChannels &&
        lhs.competitionFilterEnabled == rhs.competitionFilterEnabled &&
        lhs.channelFilterEnabled == rhs.channelFilterEnabled &&
        lhs.englishPremierLeagueTeamsOnly == rhs.englishPremierLeagueTeamsOnly &&
        lhs.majorUEFAClubGamesEnabled == rhs.majorUEFAClubGamesEnabled &&
        lhs.homeNationsFilterEnabled == rhs.homeNationsFilterEnabled &&
        lhs.majorTournamentsFilterEnabled == rhs.majorTournamentsFilterEnabled &&
        lhs.apiBaseURL == rhs.apiBaseURL &&
        lhs.refreshIntervalMinutes == rhs.refreshIntervalMinutes &&
        lhs.showAllMatches == rhs.showAllMatches &&
        lhs.matchGroupSortOrder == rhs.matchGroupSortOrder &&
        lhs.notificationsEnabled == rhs.notificationsEnabled &&
        lhs.notificationDelayMinutes == rhs.notificationDelayMinutes &&
        lhs.notificationEventTypes == rhs.notificationEventTypes &&
        lhs.notificationPremierLeagueTeamsOnly == rhs.notificationPremierLeagueTeamsOnly &&
        lhs.notificationMajorUEFAClubGamesEnabled == rhs.notificationMajorUEFAClubGamesEnabled &&
        lhs.notificationHomeNationsFilterEnabled == rhs.notificationHomeNationsFilterEnabled &&
        lhs.notificationMajorTournamentsFilterEnabled == rhs.notificationMajorTournamentsFilterEnabled &&
        lhs.fantasyDeadlineRemindersEnabled == rhs.fantasyDeadlineRemindersEnabled &&
        lhs.showTodayUnfinishedFixturesBadge == rhs.showTodayUnfinishedFixturesBadge &&
        lhs.fixturesViewDensity == rhs.fixturesViewDensity &&
        lhs.showCompactFixtureTvLogo == rhs.showCompactFixtureTvLogo &&
        lhs.showCompactFixtureFantasyLogo == rhs.showCompactFixtureFantasyLogo &&
        lhs.showKickoffTimeDividers == rhs.showKickoffTimeDividers &&
        lhs.showFantasyFixtureLogos == rhs.showFantasyFixtureLogos &&
        lhs.showFantasyExpectedPoints == rhs.showFantasyExpectedPoints &&
        lhs.showFantasyRealTimePoints == rhs.showFantasyRealTimePoints &&
        lhs.premierLeagueMatchesFirst == rhs.premierLeagueMatchesFirst &&
        lhs.showPostponedGames == rhs.showPostponedGames
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    nonisolated static let defaultSelectedLeagues = [
        "Premier League",
        "FIFA World Cup 2026",
        "FIFA World Cup Qualifying - European",
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
    nonisolated static let defaultMajorUEFAClubGamesEnabled = true
    nonisolated static let defaultHomeNationsFilterEnabled = true
    nonisolated static let defaultMajorTournamentsFilterEnabled = true
    nonisolated static let defaultCompetitionFilterEnabled = false
    nonisolated static let defaultChannelFilterEnabled = false
    nonisolated static let defaultShowAllMatches = false
    nonisolated static let defaultMatchGroupSortOrder: MatchGroupSortOrder = .kickoffThenTeamScore
    nonisolated static let defaultNotificationsEnabled = true
    nonisolated static let defaultNotificationDelayMinutes = 2
    nonisolated static let defaultNotificationEventTypes: Set<String> = ["goal", "kickoff", "halftime", "fulltime", "redcard"]
    nonisolated static let defaultNotificationPremierLeagueTeamsOnly = true
    nonisolated static let defaultNotificationMajorUEFAClubGamesEnabled = true
    nonisolated static let defaultNotificationHomeNationsFilterEnabled = true
    nonisolated static let defaultNotificationMajorTournamentsFilterEnabled = true
    nonisolated static let defaultFantasyDeadlineRemindersEnabled = true
    nonisolated static let defaultShowTodayUnfinishedFixturesBadge = false
    nonisolated static let defaultFixturesViewDensity: FixturesViewDensity = .compact
    nonisolated static let defaultShowCompactFixtureTvLogo = true
    nonisolated static let defaultShowCompactFixtureFantasyLogo = true
    nonisolated static let defaultShowKickoffTimeDividers = false
    nonisolated static let defaultShowFantasyFixtureLogos = false
    nonisolated static let defaultShowFantasyExpectedPoints = false
    nonisolated static let defaultShowFantasyRealTimePoints = false
    nonisolated static let defaultShowFantasyMatchPills = false
    nonisolated static let defaultPremierLeagueMatchesFirst = true
    nonisolated static let defaultShowPostponedGames = false
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

    @Published var majorUEFAClubGamesEnabled: Bool {
        didSet { persist() }
    }

    @Published var homeNationsFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var majorTournamentsFilterEnabled: Bool {
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

    @Published var notificationPremierLeagueTeamsOnly: Bool {
        didSet { persist() }
    }

    @Published var notificationMajorUEFAClubGamesEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationHomeNationsFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationMajorTournamentsFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var fantasyDeadlineRemindersEnabled: Bool {
        didSet { persist() }
    }

    @Published var showTodayUnfinishedFixturesBadge: Bool {
        didSet { persist() }
    }

    @Published var fixturesViewDensity: FixturesViewDensity {
        didSet { persist() }
    }

    @Published var showCompactFixtureTvLogo: Bool {
        didSet { persist() }
    }

    @Published var showCompactFixtureFantasyLogo: Bool {
        didSet { persist() }
    }

    @Published var showKickoffTimeDividers: Bool {
        didSet { persist() }
    }

    @Published var showFantasyFixtureLogos: Bool {
        didSet { persist() }
    }

    @Published var showFantasyExpectedPoints: Bool {
        didSet { persist() }
    }

    @Published var showFantasyRealTimePoints: Bool {
        didSet { persist() }
    }

    @Published var premierLeagueMatchesFirst: Bool {
        didSet { persist() }
    }

    @Published var showPostponedGames: Bool {
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
        let majorUEFAClubGamesEnabled = userDefaults.object(forKey: Keys.majorUEFAClubGamesEnabled) as? Bool
            ?? Self.defaultMajorUEFAClubGamesEnabled
        let homeNationsFilterEnabled = userDefaults.object(forKey: Keys.homeNationsFilterEnabled) as? Bool
            ?? Self.defaultHomeNationsFilterEnabled
        let majorTournamentsFilterEnabled = userDefaults.object(forKey: Keys.majorTournamentsFilterEnabled) as? Bool
            ?? Self.defaultMajorTournamentsFilterEnabled
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
        let notificationPremierLeagueTeamsOnly = userDefaults.object(forKey: Keys.notificationPremierLeagueTeamsOnly) as? Bool
            ?? Self.defaultNotificationPremierLeagueTeamsOnly
        let notificationMajorUEFAClubGamesEnabled = userDefaults.object(forKey: Keys.notificationMajorUEFAClubGamesEnabled) as? Bool
            ?? Self.defaultNotificationMajorUEFAClubGamesEnabled
        let notificationHomeNationsFilterEnabled = userDefaults.object(forKey: Keys.notificationHomeNationsFilterEnabled) as? Bool
            ?? Self.defaultNotificationHomeNationsFilterEnabled
        let notificationMajorTournamentsFilterEnabled = userDefaults.object(forKey: Keys.notificationMajorTournamentsFilterEnabled) as? Bool
            ?? Self.defaultNotificationMajorTournamentsFilterEnabled
        let fantasyDeadlineRemindersEnabled = userDefaults.object(forKey: Keys.fantasyDeadlineRemindersEnabled) as? Bool
            ?? Self.defaultFantasyDeadlineRemindersEnabled
        let showTodayUnfinishedFixturesBadge = userDefaults.object(forKey: Keys.showTodayUnfinishedFixturesBadge) as? Bool
            ?? Self.defaultShowTodayUnfinishedFixturesBadge
        let fixturesViewDensity = userDefaults.string(forKey: Keys.fixturesViewDensity)
            .flatMap(FixturesViewDensity.init(rawValue:))
            ?? Self.defaultFixturesViewDensity
        let showCompactFixtureTvLogo = userDefaults.object(forKey: Keys.showCompactFixtureTvLogo) as? Bool
            ?? Self.defaultShowCompactFixtureTvLogo
        let showCompactFixtureFantasyLogo = userDefaults.object(forKey: Keys.showCompactFixtureFantasyLogo) as? Bool
            ?? Self.defaultShowCompactFixtureFantasyLogo
        let showKickoffTimeDividers = userDefaults.object(forKey: Keys.showKickoffTimeDividers) as? Bool
            ?? Self.defaultShowKickoffTimeDividers
        let legacyShowFantasyMatchPills = userDefaults.object(forKey: Keys.showFantasyMatchPills) as? Bool
            ?? Self.defaultShowFantasyMatchPills
        let showFantasyFixtureLogos = userDefaults.object(forKey: Keys.showFantasyFixtureLogos) as? Bool
            ?? legacyShowFantasyMatchPills
        let showFantasyExpectedPoints = userDefaults.object(forKey: Keys.showFantasyExpectedPoints) as? Bool
            ?? legacyShowFantasyMatchPills
        let showFantasyRealTimePoints = userDefaults.object(forKey: Keys.showFantasyRealTimePoints) as? Bool
            ?? legacyShowFantasyMatchPills
        let premierLeagueMatchesFirst = userDefaults.object(forKey: Keys.premierLeagueMatchesFirst) as? Bool
            ?? Self.defaultPremierLeagueMatchesFirst
        let showPostponedGames = userDefaults.object(forKey: Keys.showPostponedGames) as? Bool
            ?? Self.defaultShowPostponedGames
        #if DEBUG
        let showPredictionRedoButton = userDefaults.object(forKey: Keys.showPredictionRedoButton) as? Bool
            ?? Self.defaultShowPredictionRedoButton
        #endif

        self.selectedLeagues = leagues
        self.selectedChannels = ChannelSelection.normalizedSelectedOptions(channels)
        self.competitionFilterEnabled = competitionFilterEnabled
        self.channelFilterEnabled = channelFilterEnabled
        self.englishPremierLeagueTeamsOnly = englishPremierLeagueTeamsOnly
        self.majorUEFAClubGamesEnabled = majorUEFAClubGamesEnabled
        self.homeNationsFilterEnabled = homeNationsFilterEnabled
        self.majorTournamentsFilterEnabled = majorTournamentsFilterEnabled
        self.apiBaseURL = apiBaseURL
        self.refreshIntervalMinutes = max(1, refreshInterval)
        self.showAllMatches = showAllMatches
        self.matchGroupSortOrder = matchGroupSortOrder
        self.notificationsEnabled = notificationsEnabled
        self.notificationDelayMinutes = max(0, min(10, notificationDelayMinutes))
        self.notificationEventTypes = notificationEventTypes
        self.notificationPremierLeagueTeamsOnly = notificationPremierLeagueTeamsOnly
        self.notificationMajorUEFAClubGamesEnabled = notificationMajorUEFAClubGamesEnabled
        self.notificationHomeNationsFilterEnabled = notificationHomeNationsFilterEnabled
        self.notificationMajorTournamentsFilterEnabled = notificationMajorTournamentsFilterEnabled
        self.fantasyDeadlineRemindersEnabled = fantasyDeadlineRemindersEnabled
        self.showTodayUnfinishedFixturesBadge = showTodayUnfinishedFixturesBadge
        self.fixturesViewDensity = fixturesViewDensity
        self.showCompactFixtureTvLogo = showCompactFixtureTvLogo
        self.showCompactFixtureFantasyLogo = showCompactFixtureFantasyLogo
        self.showKickoffTimeDividers = showKickoffTimeDividers
        self.showFantasyFixtureLogos = showFantasyFixtureLogos
        self.showFantasyExpectedPoints = showFantasyExpectedPoints
        self.showFantasyRealTimePoints = showFantasyRealTimePoints
        self.premierLeagueMatchesFirst = premierLeagueMatchesFirst
        self.showPostponedGames = showPostponedGames
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
            majorUEFAClubGamesEnabled: majorUEFAClubGamesEnabled,
            homeNationsFilterEnabled: homeNationsFilterEnabled,
            majorTournamentsFilterEnabled: majorTournamentsFilterEnabled,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            showAllMatches: showAllMatches,
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationPremierLeagueTeamsOnly: notificationPremierLeagueTeamsOnly,
            notificationMajorUEFAClubGamesEnabled: notificationMajorUEFAClubGamesEnabled,
            notificationHomeNationsFilterEnabled: notificationHomeNationsFilterEnabled,
            notificationMajorTournamentsFilterEnabled: notificationMajorTournamentsFilterEnabled,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            fixturesViewDensity: fixturesViewDensity,
            showCompactFixtureTvLogo: showCompactFixtureTvLogo,
            showCompactFixtureFantasyLogo: showCompactFixtureFantasyLogo,
            showKickoffTimeDividers: showKickoffTimeDividers,
            showFantasyFixtureLogos: showFantasyFixtureLogos,
            showFantasyExpectedPoints: showFantasyExpectedPoints,
            showFantasyRealTimePoints: showFantasyRealTimePoints,
            premierLeagueMatchesFirst: premierLeagueMatchesFirst,
            showPostponedGames: showPostponedGames
        )
    }

    var showsFantasyDataInFixtures: Bool {
        snapshot.showsFantasyDataInFixtures
    }

    var unfilteredSnapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: selectedLeagues,
            selectedChannels: selectedChannels,
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: false,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            showAllMatches: showAllMatches,
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: notificationDelayMinutes,
            notificationEventTypes: notificationEventTypes,
            notificationPremierLeagueTeamsOnly: notificationPremierLeagueTeamsOnly,
            notificationMajorUEFAClubGamesEnabled: notificationMajorUEFAClubGamesEnabled,
            notificationHomeNationsFilterEnabled: notificationHomeNationsFilterEnabled,
            notificationMajorTournamentsFilterEnabled: notificationMajorTournamentsFilterEnabled,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            fixturesViewDensity: fixturesViewDensity,
            showCompactFixtureTvLogo: showCompactFixtureTvLogo,
            showCompactFixtureFantasyLogo: showCompactFixtureFantasyLogo,
            showKickoffTimeDividers: showKickoffTimeDividers,
            showFantasyFixtureLogos: showFantasyFixtureLogos,
            showFantasyExpectedPoints: showFantasyExpectedPoints,
            showFantasyRealTimePoints: showFantasyRealTimePoints,
            premierLeagueMatchesFirst: premierLeagueMatchesFirst,
            showPostponedGames: showPostponedGames
        )
    }

    func persist(userDefaults: UserDefaults = .standard) {
        userDefaults.set(selectedLeagues, forKey: Keys.selectedLeagues)
        userDefaults.set(selectedChannels, forKey: Keys.selectedChannels)
        userDefaults.set(competitionFilterEnabled, forKey: Keys.competitionFilterEnabled)
        userDefaults.set(channelFilterEnabled, forKey: Keys.channelFilterEnabled)
        userDefaults.set(englishPremierLeagueTeamsOnly, forKey: Keys.englishPremierLeagueTeamsOnly)
        userDefaults.set(majorUEFAClubGamesEnabled, forKey: Keys.majorUEFAClubGamesEnabled)
        userDefaults.set(homeNationsFilterEnabled, forKey: Keys.homeNationsFilterEnabled)
        userDefaults.set(majorTournamentsFilterEnabled, forKey: Keys.majorTournamentsFilterEnabled)
        userDefaults.set(apiBaseURL, forKey: Keys.apiBaseURL)
        userDefaults.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
        userDefaults.set(showAllMatches, forKey: Keys.showAllMatches)
        userDefaults.set(matchGroupSortOrder.rawValue, forKey: Keys.matchGroupSortOrder)
        userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        userDefaults.set(notificationDelayMinutes, forKey: Keys.notificationDelayMinutes)
        userDefaults.set(Array(notificationEventTypes), forKey: Keys.notificationEventTypes)
        userDefaults.set(notificationPremierLeagueTeamsOnly, forKey: Keys.notificationPremierLeagueTeamsOnly)
        userDefaults.set(notificationMajorUEFAClubGamesEnabled, forKey: Keys.notificationMajorUEFAClubGamesEnabled)
        userDefaults.set(notificationHomeNationsFilterEnabled, forKey: Keys.notificationHomeNationsFilterEnabled)
        userDefaults.set(notificationMajorTournamentsFilterEnabled, forKey: Keys.notificationMajorTournamentsFilterEnabled)
        userDefaults.set(fantasyDeadlineRemindersEnabled, forKey: Keys.fantasyDeadlineRemindersEnabled)
        userDefaults.set(showTodayUnfinishedFixturesBadge, forKey: Keys.showTodayUnfinishedFixturesBadge)
        userDefaults.set(fixturesViewDensity.rawValue, forKey: Keys.fixturesViewDensity)
        userDefaults.set(showCompactFixtureTvLogo, forKey: Keys.showCompactFixtureTvLogo)
        userDefaults.set(showCompactFixtureFantasyLogo, forKey: Keys.showCompactFixtureFantasyLogo)
        userDefaults.set(showKickoffTimeDividers, forKey: Keys.showKickoffTimeDividers)
        userDefaults.set(showFantasyFixtureLogos, forKey: Keys.showFantasyFixtureLogos)
        userDefaults.set(showFantasyExpectedPoints, forKey: Keys.showFantasyExpectedPoints)
        userDefaults.set(showFantasyRealTimePoints, forKey: Keys.showFantasyRealTimePoints)
        userDefaults.set(premierLeagueMatchesFirst, forKey: Keys.premierLeagueMatchesFirst)
        userDefaults.set(showPostponedGames, forKey: Keys.showPostponedGames)
        userDefaults.set(showsFantasyDataInFixtures, forKey: Keys.showFantasyMatchPills)
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
        let majorUEFAClubGamesEnabled = userDefaults.object(forKey: Keys.majorUEFAClubGamesEnabled) as? Bool
            ?? Self.defaultMajorUEFAClubGamesEnabled
        let homeNationsFilterEnabled = userDefaults.object(forKey: Keys.homeNationsFilterEnabled) as? Bool
            ?? Self.defaultHomeNationsFilterEnabled
        let majorTournamentsFilterEnabled = userDefaults.object(forKey: Keys.majorTournamentsFilterEnabled) as? Bool
            ?? Self.defaultMajorTournamentsFilterEnabled
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
        let notificationPremierLeagueTeamsOnly = userDefaults.object(forKey: Keys.notificationPremierLeagueTeamsOnly) as? Bool
            ?? Self.defaultNotificationPremierLeagueTeamsOnly
        let notificationMajorUEFAClubGamesEnabled = userDefaults.object(forKey: Keys.notificationMajorUEFAClubGamesEnabled) as? Bool
            ?? Self.defaultNotificationMajorUEFAClubGamesEnabled
        let notificationHomeNationsFilterEnabled = userDefaults.object(forKey: Keys.notificationHomeNationsFilterEnabled) as? Bool
            ?? Self.defaultNotificationHomeNationsFilterEnabled
        let notificationMajorTournamentsFilterEnabled = userDefaults.object(forKey: Keys.notificationMajorTournamentsFilterEnabled) as? Bool
            ?? Self.defaultNotificationMajorTournamentsFilterEnabled
        let fantasyDeadlineRemindersEnabled = userDefaults.object(forKey: Keys.fantasyDeadlineRemindersEnabled) as? Bool
            ?? Self.defaultFantasyDeadlineRemindersEnabled
        let showTodayUnfinishedFixturesBadge = userDefaults.object(forKey: Keys.showTodayUnfinishedFixturesBadge) as? Bool
            ?? Self.defaultShowTodayUnfinishedFixturesBadge
        let fixturesViewDensity = userDefaults.string(forKey: Keys.fixturesViewDensity)
            .flatMap(FixturesViewDensity.init(rawValue:))
            ?? Self.defaultFixturesViewDensity
        let showCompactFixtureTvLogo = userDefaults.object(forKey: Keys.showCompactFixtureTvLogo) as? Bool
            ?? Self.defaultShowCompactFixtureTvLogo
        let showCompactFixtureFantasyLogo = userDefaults.object(forKey: Keys.showCompactFixtureFantasyLogo) as? Bool
            ?? Self.defaultShowCompactFixtureFantasyLogo
        let showKickoffTimeDividers = userDefaults.object(forKey: Keys.showKickoffTimeDividers) as? Bool
            ?? Self.defaultShowKickoffTimeDividers
        let legacyShowFantasyMatchPills = userDefaults.object(forKey: Keys.showFantasyMatchPills) as? Bool
            ?? Self.defaultShowFantasyMatchPills
        let showFantasyFixtureLogos = userDefaults.object(forKey: Keys.showFantasyFixtureLogos) as? Bool
            ?? legacyShowFantasyMatchPills
        let showFantasyExpectedPoints = userDefaults.object(forKey: Keys.showFantasyExpectedPoints) as? Bool
            ?? legacyShowFantasyMatchPills
        let showFantasyRealTimePoints = userDefaults.object(forKey: Keys.showFantasyRealTimePoints) as? Bool
            ?? legacyShowFantasyMatchPills
        let premierLeagueMatchesFirst = userDefaults.object(forKey: Keys.premierLeagueMatchesFirst) as? Bool
            ?? Self.defaultPremierLeagueMatchesFirst
        let showPostponedGames = userDefaults.object(forKey: Keys.showPostponedGames) as? Bool
            ?? Self.defaultShowPostponedGames

        return PreferencesSnapshot(
            selectedLeagues: leagues,
            selectedChannels: ChannelSelection.normalizedSelectedOptions(channels),
            competitionFilterEnabled: competitionFilterEnabled,
            channelFilterEnabled: channelFilterEnabled,
            englishPremierLeagueTeamsOnly: englishPremierLeagueTeamsOnly,
            majorUEFAClubGamesEnabled: majorUEFAClubGamesEnabled,
            homeNationsFilterEnabled: homeNationsFilterEnabled,
            majorTournamentsFilterEnabled: majorTournamentsFilterEnabled,
            apiBaseURL: apiBaseURL,
            refreshIntervalMinutes: max(1, refreshInterval),
            showAllMatches: showAllMatches,
            matchGroupSortOrder: matchGroupSortOrder,
            notificationsEnabled: notificationsEnabled,
            notificationDelayMinutes: max(0, min(10, notificationDelayMinutes)),
            notificationEventTypes: notificationEventTypes,
            notificationPremierLeagueTeamsOnly: notificationPremierLeagueTeamsOnly,
            notificationMajorUEFAClubGamesEnabled: notificationMajorUEFAClubGamesEnabled,
            notificationHomeNationsFilterEnabled: notificationHomeNationsFilterEnabled,
            notificationMajorTournamentsFilterEnabled: notificationMajorTournamentsFilterEnabled,
            fantasyDeadlineRemindersEnabled: fantasyDeadlineRemindersEnabled,
            showTodayUnfinishedFixturesBadge: showTodayUnfinishedFixturesBadge,
            fixturesViewDensity: fixturesViewDensity,
            showCompactFixtureTvLogo: showCompactFixtureTvLogo,
            showCompactFixtureFantasyLogo: showCompactFixtureFantasyLogo,
            showKickoffTimeDividers: showKickoffTimeDividers,
            showFantasyFixtureLogos: showFantasyFixtureLogos,
            showFantasyExpectedPoints: showFantasyExpectedPoints,
            showFantasyRealTimePoints: showFantasyRealTimePoints,
            premierLeagueMatchesFirst: premierLeagueMatchesFirst,
            showPostponedGames: showPostponedGames
        )
    }

    private enum Keys {
        static let selectedLeagues = "preferences.selectedLeagues"
        static let selectedChannels = "preferences.selectedChannels"
        static let competitionFilterEnabled = "preferences.competitionFilterEnabled"
        static let channelFilterEnabled = "preferences.channelFilterEnabled"
        static let englishPremierLeagueTeamsOnly = "preferences.englishPremierLeagueTeamsOnly"
        static let majorUEFAClubGamesEnabled = "preferences.majorUEFAClubGamesEnabled"
        static let homeNationsFilterEnabled = "preferences.homeNationsFilterEnabled"
        static let majorTournamentsFilterEnabled = "preferences.majorTournamentsFilterEnabled"
        static let apiBaseURL = "preferences.apiBaseURL"
        static let refreshIntervalMinutes = "preferences.refreshIntervalMinutes"
        static let showAllMatches = "preferences.showAllMatches"
        static let matchGroupSortOrder = "preferences.matchGroupSortOrder"
        static let notificationsEnabled = "preferences.notificationsEnabled"
        static let notificationDelayMinutes = "preferences.notificationDelayMinutes"
        static let notificationEventTypes = "preferences.notificationEventTypes"
        static let notificationPremierLeagueTeamsOnly = "preferences.notificationPremierLeagueTeamsOnly"
        static let notificationMajorUEFAClubGamesEnabled = "preferences.notificationMajorUEFAClubGamesEnabled"
        static let notificationHomeNationsFilterEnabled = "preferences.notificationHomeNationsFilterEnabled"
        static let notificationMajorTournamentsFilterEnabled = "preferences.notificationMajorTournamentsFilterEnabled"
        static let fantasyDeadlineRemindersEnabled = "preferences.fantasyDeadlineRemindersEnabled"
        static let showTodayUnfinishedFixturesBadge = "preferences.showTodayUnfinishedFixturesBadge"
        static let fixturesViewDensity = "preferences.fixturesViewDensity"
        static let showCompactFixtureTvLogo = "preferences.showCompactFixtureTvLogo"
        static let showCompactFixtureFantasyLogo = "preferences.showCompactFixtureFantasyLogo"
        static let showKickoffTimeDividers = "preferences.showKickoffTimeDividers"
        static let showFantasyFixtureLogos = "preferences.showFantasyFixtureLogos"
        static let showFantasyExpectedPoints = "preferences.showFantasyExpectedPoints"
        static let showFantasyRealTimePoints = "preferences.showFantasyRealTimePoints"
        static let showFantasyMatchPills = "preferences.showFantasyMatchPills"
        static let premierLeagueMatchesFirst = "preferences.premierLeagueMatchesFirst"
        static let showPostponedGames = "preferences.showPostponedGames"
        #if DEBUG
        static let showPredictionRedoButton = "preferences.showPredictionRedoButton"
        #endif
    }
}
