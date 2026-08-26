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

nonisolated enum FixtureViewOptionID {
    static let all = "scope:all"
    static let topTeamsPreset = "preset:top-teams"
    static let topUEFAClubs = "rule:top-uefa-clubs"
    static let premierLeagueTeams = "rule:premier-league-teams"
    static let uefaClubCompetitionStableIDs: Set<String> = [
        "uefa-champions-league",
        "uefa-europa-league",
        "uefa-conference-league",
        "uefa-super-cup",
    ]
    static let mutuallyExclusiveUEFATeamRules: Set<String> = [
        topUEFAClubs,
        premierLeagueTeams,
    ]
    static let premierLeagueMatchesPresetOptionIDs: Set<String> = Set(
        [competition("premier-league"), premierLeagueTeams] +
        uefaClubCompetitionStableIDs.map(competition)
    )

    static func competition(_ stableID: String) -> String {
        "competition:\(stableID)"
    }

    static func team(_ stableID: String) -> String {
        "team:\(stableID)"
    }

    static func teamStableID(from optionID: String) -> String? {
        guard optionID.hasPrefix("team:") else { return nil }
        let stableID = String(optionID.dropFirst("team:".count))
        return stableID.isEmpty ? nil : stableID
    }

    static func replacingTeams(
        in optionIDs: Set<String>,
        with teamIDs: Set<String>
    ) -> Set<String> {
        optionIDs
            .filter { teamStableID(from: $0) == nil }
            .union(teamIDs.map(team))
    }

    static func rivalry(_ stableID: String) -> String {
        "rivalry:\(stableID)"
    }

    static func competitionStableID(from optionID: String) -> String? {
        guard optionID.hasPrefix("competition:") else { return nil }
        return String(optionID.dropFirst("competition:".count))
    }

    static func toggling(_ optionID: String, in optionIDs: Set<String>) -> Set<String> {
        var updated = optionIDs
        updated.remove(all)
        if updated.contains(optionID) {
            updated.remove(optionID)
        } else {
            if mutuallyExclusiveUEFATeamRules.contains(optionID) {
                updated.subtract(mutuallyExclusiveUEFATeamRules)
            }
            updated.insert(optionID)
        }
        return updated
    }

    static func legacyCompetition(_ name: String) -> String {
        let normalizedName = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stableID: String
        switch normalizedName {
        case "english-premier-league": stableID = "premier-league"
        case "english-fa-cup": stableID = "fa-cup"
        case "efl-cup", "carabao-cup": stableID = "english-league-cup"
        case "spanish-la-liga": stableID = "la-liga"
        case "german-bundesliga": stableID = "bundesliga"
        case "italian-serie-a": stableID = "serie-a"
        case "french-ligue-1": stableID = "ligue-1"
        default: stableID = normalizedName
        }
        return competition(stableID)
    }
}

nonisolated struct FixtureViewSpecialOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let regionID: String
    let logoTeamNames: [String]
    let systemImage: String?

    static let all: [FixtureViewSpecialOption] = [
        .init(id: FixtureViewOptionID.rivalry("el-clasico"), title: "El Clásico", subtitle: "Barcelona vs Real Madrid", regionID: "spain", logoTeamNames: ["Barcelona", "Real Madrid"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("real-madrid"), title: "Real Madrid", subtitle: "All Real Madrid matches", regionID: "spain", logoTeamNames: ["Real Madrid"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("barcelona"), title: "Barcelona", subtitle: "All Barcelona matches", regionID: "spain", logoTeamNames: ["Barcelona"], systemImage: nil),
        .init(id: FixtureViewOptionID.rivalry("old-firm"), title: "Old Firm", subtitle: "Celtic vs Rangers", regionID: "scotland", logoTeamNames: ["Celtic", "Rangers"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("celtic"), title: "Celtic", subtitle: "All Celtic matches", regionID: "scotland", logoTeamNames: ["Celtic"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("rangers"), title: "Rangers", subtitle: "All Rangers matches", regionID: "scotland", logoTeamNames: ["Rangers"], systemImage: nil),
        .init(id: FixtureViewOptionID.rivalry("der-klassiker"), title: "Der Klassiker", subtitle: "Bayern Munich vs Borussia Dortmund", regionID: "germany", logoTeamNames: ["Bayern Munich", "Borussia Dortmund"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("bayern-munich"), title: "Bayern Munich", subtitle: "All Bayern Munich matches", regionID: "germany", logoTeamNames: ["Bayern Munich"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("borussia-dortmund"), title: "Borussia Dortmund", subtitle: "All Dortmund matches", regionID: "germany", logoTeamNames: ["Borussia Dortmund"], systemImage: nil),
        .init(id: FixtureViewOptionID.rivalry("derby-della-madonnina"), title: "Derby della Madonnina", subtitle: "Inter vs AC Milan", regionID: "italy", logoTeamNames: ["Inter Milan", "AC Milan"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("inter"), title: "Inter", subtitle: "All Inter matches", regionID: "italy", logoTeamNames: ["Inter Milan"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("ac-milan"), title: "AC Milan", subtitle: "All AC Milan matches", regionID: "italy", logoTeamNames: ["AC Milan"], systemImage: nil),
        .init(id: FixtureViewOptionID.team("juventus"), title: "Juventus", subtitle: "All Juventus matches", regionID: "italy", logoTeamNames: ["Juventus"], systemImage: nil),
        .init(id: FixtureViewOptionID.rivalry("le-classique"), title: "Le Classique", subtitle: "Paris Saint-Germain vs Marseille", regionID: "france", logoTeamNames: ["Paris Saint-Germain", "Marseille"], systemImage: nil),
        .init(id: FixtureViewOptionID.topUEFAClubs, title: "Major European clubs", subtitle: "High-ranked clubs in UEFA competitions", regionID: "europe", logoTeamNames: [], systemImage: "chart.line.uptrend.xyaxis"),
        .init(id: FixtureViewOptionID.premierLeagueTeams, title: "Premier League teams only", subtitle: "Premier League clubs in UEFA competitions", regionID: "europe", logoTeamNames: [], systemImage: nil)
    ]

    static func options(in regionID: String) -> [FixtureViewSpecialOption] {
        all.filter { $0.regionID == regionID }
    }
}

struct PreferencesSnapshot: Codable, Equatable, Sendable {
    let selectedLeagues: [String]
    let selectedFixtureViewOptionIDs: [String]
    let favouriteFixtureViewOptionIDs: [String]
    let favouriteShowPredictedScores: Bool
    let selectedNotificationLeagues: [String]
    let selectedNotificationViewOptionIDs: [String]
    let selectedChannels: [String]
    let fixtureAllMajorMatchesEnabled: Bool
    let notificationMatchesFixturesEnabled: Bool
    let notificationAllMajorMatchesEnabled: Bool
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

    nonisolated var usesFixtureCompetitionSelection: Bool {
        !fixtureAllMajorMatchesEnabled && !showAllMatches
    }

    nonisolated var effectiveFixtureViewOptionIDs: [String] {
        if showAllMatches { return [] }
        let optionIDs = fixtureAllMajorMatchesEnabled
            ? favouriteFixtureViewOptionIDs
            : selectedFixtureViewOptionIDs
        return optionIDs.contains(FixtureViewOptionID.all) ? [] : optionIDs
    }

    nonisolated var fixtureViewShowsAll: Bool {
        showAllMatches || (
            fixtureAllMajorMatchesEnabled &&
            favouriteFixtureViewOptionIDs.contains(FixtureViewOptionID.all)
        )
    }

    nonisolated var effectiveEnglishPremierLeagueTeamsOnly: Bool {
        fixtureAllMajorMatchesEnabled && englishPremierLeagueTeamsOnly
    }

    nonisolated var effectiveMajorUEFAClubGamesEnabled: Bool {
        fixtureAllMajorMatchesEnabled && englishPremierLeagueTeamsOnly && majorUEFAClubGamesEnabled
    }

    nonisolated var effectiveHomeNationsFilterEnabled: Bool {
        fixtureAllMajorMatchesEnabled && englishPremierLeagueTeamsOnly && homeNationsFilterEnabled
    }

    nonisolated var effectiveMajorTournamentsFilterEnabled: Bool {
        fixtureAllMajorMatchesEnabled && englishPremierLeagueTeamsOnly && majorTournamentsFilterEnabled
    }

    nonisolated init(
        selectedLeagues: [String],
        selectedFixtureViewOptionIDs: [String] = PreferencesStore.defaultFavouriteFixtureViewOptionIDs,
        favouriteFixtureViewOptionIDs: [String] = PreferencesStore.defaultFavouriteFixtureViewOptionIDs,
        favouriteShowPredictedScores: Bool = PreferencesStore.defaultFavouriteShowPredictedScores,
        selectedNotificationLeagues: [String] = PreferencesStore.defaultSelectedNotificationLeagues,
        selectedNotificationViewOptionIDs: [String] = PreferencesStore.defaultSelectedNotificationViewOptionIDs,
        selectedChannels: [String],
        fixtureAllMajorMatchesEnabled: Bool = PreferencesStore.defaultFixtureAllMajorMatchesEnabled,
        notificationMatchesFixturesEnabled: Bool = PreferencesStore.defaultNotificationMatchesFixturesEnabled,
        notificationAllMajorMatchesEnabled: Bool = PreferencesStore.defaultNotificationAllMajorMatchesEnabled,
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
        self.selectedFixtureViewOptionIDs = selectedFixtureViewOptionIDs
        self.favouriteFixtureViewOptionIDs = favouriteFixtureViewOptionIDs
        self.favouriteShowPredictedScores = favouriteShowPredictedScores
        self.selectedNotificationLeagues = selectedNotificationLeagues
        self.selectedNotificationViewOptionIDs = selectedNotificationViewOptionIDs
        self.selectedChannels = selectedChannels
        self.fixtureAllMajorMatchesEnabled = fixtureAllMajorMatchesEnabled
        self.notificationMatchesFixturesEnabled = notificationMatchesFixturesEnabled
        self.notificationAllMajorMatchesEnabled = notificationAllMajorMatchesEnabled
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
        case selectedFixtureViewOptionIDs
        case favouriteFixtureViewOptionIDs
        case favouriteShowPredictedScores
        case selectedNotificationLeagues
        case selectedNotificationViewOptionIDs
        case selectedChannels
        case fixtureAllMajorMatchesEnabled
        case notificationMatchesFixturesEnabled
        case notificationAllMajorMatchesEnabled
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
        selectedFixtureViewOptionIDs = try container.decodeIfPresent([String].self, forKey: .selectedFixtureViewOptionIDs)
            ?? selectedLeagues.map(FixtureViewOptionID.legacyCompetition)
        favouriteFixtureViewOptionIDs = try container.decodeIfPresent([String].self, forKey: .favouriteFixtureViewOptionIDs)
            ?? PreferencesStore.defaultFavouriteFixtureViewOptionIDs
        favouriteShowPredictedScores = try container.decodeIfPresent(Bool.self, forKey: .favouriteShowPredictedScores)
            ?? PreferencesStore.defaultFavouriteShowPredictedScores
        selectedNotificationLeagues = try container.decodeIfPresent([String].self, forKey: .selectedNotificationLeagues)
            ?? selectedLeagues
        selectedNotificationViewOptionIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .selectedNotificationViewOptionIDs
        ) ?? selectedNotificationLeagues.map(FixtureViewOptionID.legacyCompetition)
        selectedChannels = try container.decode([String].self, forKey: .selectedChannels)
        competitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .competitionFilterEnabled) ?? PreferencesStore.defaultCompetitionFilterEnabled
        channelFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .channelFilterEnabled) ?? PreferencesStore.defaultChannelFilterEnabled
        englishPremierLeagueTeamsOnly = try container.decode(Bool.self, forKey: .englishPremierLeagueTeamsOnly)
        majorUEFAClubGamesEnabled = try container.decodeIfPresent(Bool.self, forKey: .majorUEFAClubGamesEnabled) ?? PreferencesStore.defaultMajorUEFAClubGamesEnabled
        homeNationsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .homeNationsFilterEnabled) ?? PreferencesStore.defaultHomeNationsFilterEnabled
        majorTournamentsFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .majorTournamentsFilterEnabled) ?? PreferencesStore.defaultMajorTournamentsFilterEnabled
        fixtureAllMajorMatchesEnabled = try container.decodeIfPresent(Bool.self, forKey: .fixtureAllMajorMatchesEnabled)
            ?? (
                englishPremierLeagueTeamsOnly &&
                majorUEFAClubGamesEnabled &&
                homeNationsFilterEnabled &&
                majorTournamentsFilterEnabled
            )
        notificationMatchesFixturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationMatchesFixturesEnabled)
            ?? PreferencesStore.defaultNotificationMatchesFixturesEnabled
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
        notificationAllMajorMatchesEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationAllMajorMatchesEnabled)
            ?? (
                notificationPremierLeagueTeamsOnly &&
                notificationMajorUEFAClubGamesEnabled &&
                notificationHomeNationsFilterEnabled &&
                notificationMajorTournamentsFilterEnabled
            )
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
        try container.encode(selectedFixtureViewOptionIDs, forKey: .selectedFixtureViewOptionIDs)
        try container.encode(favouriteFixtureViewOptionIDs, forKey: .favouriteFixtureViewOptionIDs)
        try container.encode(favouriteShowPredictedScores, forKey: .favouriteShowPredictedScores)
        try container.encode(selectedNotificationLeagues, forKey: .selectedNotificationLeagues)
        try container.encode(selectedNotificationViewOptionIDs, forKey: .selectedNotificationViewOptionIDs)
        try container.encode(selectedChannels, forKey: .selectedChannels)
        try container.encode(fixtureAllMajorMatchesEnabled, forKey: .fixtureAllMajorMatchesEnabled)
        try container.encode(notificationMatchesFixturesEnabled, forKey: .notificationMatchesFixturesEnabled)
        try container.encode(notificationAllMajorMatchesEnabled, forKey: .notificationAllMajorMatchesEnabled)
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
        lhs.selectedFixtureViewOptionIDs == rhs.selectedFixtureViewOptionIDs &&
        lhs.favouriteFixtureViewOptionIDs == rhs.favouriteFixtureViewOptionIDs &&
        lhs.favouriteShowPredictedScores == rhs.favouriteShowPredictedScores &&
        lhs.selectedNotificationLeagues == rhs.selectedNotificationLeagues &&
        lhs.selectedNotificationViewOptionIDs == rhs.selectedNotificationViewOptionIDs &&
        lhs.selectedChannels == rhs.selectedChannels &&
        lhs.fixtureAllMajorMatchesEnabled == rhs.fixtureAllMajorMatchesEnabled &&
        lhs.notificationMatchesFixturesEnabled == rhs.notificationMatchesFixturesEnabled &&
        lhs.notificationAllMajorMatchesEnabled == rhs.notificationAllMajorMatchesEnabled &&
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
    private let userDefaults: UserDefaults

    nonisolated static let defaultSelectedLeagues = [
        "Premier League",
        "FA Cup",
        "UEFA Nations League"
    ]
    nonisolated static let defaultFavouriteFixtureViewOptionIDs = [
        FixtureViewOptionID.competition("premier-league"),
        FixtureViewOptionID.competition("fa-cup"),
        FixtureViewOptionID.rivalry("der-klassiker"),
        FixtureViewOptionID.team("bayern-munich"),
        FixtureViewOptionID.rivalry("el-clasico"),
        FixtureViewOptionID.team("barcelona"),
        FixtureViewOptionID.team("real-madrid"),
        FixtureViewOptionID.rivalry("derby-della-madonnina"),
        FixtureViewOptionID.rivalry("le-classique"),
        FixtureViewOptionID.topUEFAClubs,
        FixtureViewOptionID.competition("uefa-nations-league")
    ]
    nonisolated static let defaultFavouriteShowPredictedScores = false
    nonisolated static let defaultSelectedNotificationLeagues = [
        "Premier League",
        "FIFA World Cup 2026",
        "FIFA World Cup Qualifying - European",
        "UEFA Champions League",
        "UEFA Conference League",
        "UEFA Europa League",
        "UEFA Super Cup"
    ]
    nonisolated static let defaultSelectedNotificationViewOptionIDs =
        defaultSelectedNotificationLeagues.map(FixtureViewOptionID.legacyCompetition)
    nonisolated static let defaultFixtureAllMajorMatchesEnabled = true
    nonisolated static let defaultNotificationMatchesFixturesEnabled = true
    nonisolated static let defaultNotificationAllMajorMatchesEnabled = true
    nonisolated static let productionApiBaseURL = "https://api.skynolimit.dev/top-scores/api/v1"
    nonisolated static let developmentApiBaseURL = "http://Mikes-MacBook-Air.local:3011/api/v1"
    nonisolated static let defaultApiBaseURL = productionApiBaseURL

    nonisolated static func resolvedAPIBaseURL(userDefaults: UserDefaults = .standard) -> String {
        #if DEBUG
        return userDefaults.string(forKey: Keys.apiBaseURL) ?? defaultApiBaseURL
        #else
        return productionApiBaseURL
        #endif
    }

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
    nonisolated static let defaultShowPredictedScores = false

    @Published var selectedLeagues: [String] {
        didSet { persist() }
    }

    @Published var selectedFixtureViewOptionIDs: [String] {
        didSet { persist() }
    }

    @Published var favouriteFixtureViewOptionIDs: [String] {
        didSet { persist() }
    }

    @Published var favouriteShowPredictedScores: Bool {
        didSet { persist() }
    }

    @Published var selectedNotificationLeagues: [String] {
        didSet { persist() }
    }

    @Published var selectedNotificationViewOptionIDs: [String] {
        didSet { persist() }
    }

    @Published var selectedChannels: [String] {
        didSet { persist() }
    }

    @Published var competitionFilterEnabled: Bool {
        didSet { persist() }
    }

    @Published var fixtureAllMajorMatchesEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationMatchesFixturesEnabled: Bool {
        didSet { persist() }
    }

    @Published var notificationAllMajorMatchesEnabled: Bool {
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

    /// Whether predicted scores are shown inline on Fixtures/Results rows. Purely a
    /// display toggle — not part of `PreferencesSnapshot` since it doesn't affect what
    /// matches are fetched or filtered, only how a row already on screen is rendered.
    @Published var showPredictedScores: Bool {
        didSet { persist() }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let leagues = userDefaults.stringArray(forKey: Keys.selectedLeagues) ?? Self.defaultSelectedLeagues
        let selectedFixtureViewOptionIDs = userDefaults.stringArray(forKey: Keys.selectedFixtureViewOptionIDs)
            ?? leagues.map(FixtureViewOptionID.legacyCompetition)
        let favouriteFixtureViewOptionIDs = userDefaults.stringArray(forKey: Keys.favouriteFixtureViewOptionIDs)
            ?? Self.defaultFavouriteFixtureViewOptionIDs
        let favouriteShowPredictedScores = userDefaults.object(forKey: Keys.favouriteShowPredictedScores) as? Bool
            ?? Self.defaultFavouriteShowPredictedScores
        let notificationLeagues = userDefaults.stringArray(forKey: Keys.selectedNotificationLeagues) ?? leagues
        let notificationViewOptionIDs = userDefaults.stringArray(forKey: Keys.selectedNotificationViewOptionIDs)
            ?? notificationLeagues.map(FixtureViewOptionID.legacyCompetition)
        let channels = userDefaults.stringArray(forKey: Keys.selectedChannels) ?? Self.defaultSelectedChannels
        let competitionFilterEnabled = userDefaults.object(forKey: Keys.competitionFilterEnabled) as? Bool
            ?? Self.defaultCompetitionFilterEnabled
        let fixtureAllMajorMatchesEnabled = userDefaults.object(forKey: Keys.fixtureAllMajorMatchesEnabled) as? Bool
            ?? (
                (userDefaults.object(forKey: Keys.englishPremierLeagueTeamsOnly) as? Bool ?? Self.defaultEnglishPremierLeagueTeamsOnly) &&
                (userDefaults.object(forKey: Keys.majorUEFAClubGamesEnabled) as? Bool ?? Self.defaultMajorUEFAClubGamesEnabled) &&
                (userDefaults.object(forKey: Keys.homeNationsFilterEnabled) as? Bool ?? Self.defaultHomeNationsFilterEnabled) &&
                (userDefaults.object(forKey: Keys.majorTournamentsFilterEnabled) as? Bool ?? Self.defaultMajorTournamentsFilterEnabled)
            )
        let notificationMatchesFixturesEnabled = userDefaults.object(forKey: Keys.notificationMatchesFixturesEnabled) as? Bool
            ?? Self.defaultNotificationMatchesFixturesEnabled
        let notificationAllMajorMatchesEnabled = userDefaults.object(forKey: Keys.notificationAllMajorMatchesEnabled) as? Bool
            ?? (
                (userDefaults.object(forKey: Keys.notificationPremierLeagueTeamsOnly) as? Bool ?? Self.defaultNotificationPremierLeagueTeamsOnly) &&
                (userDefaults.object(forKey: Keys.notificationMajorUEFAClubGamesEnabled) as? Bool ?? Self.defaultNotificationMajorUEFAClubGamesEnabled) &&
                (userDefaults.object(forKey: Keys.notificationHomeNationsFilterEnabled) as? Bool ?? Self.defaultNotificationHomeNationsFilterEnabled) &&
                (userDefaults.object(forKey: Keys.notificationMajorTournamentsFilterEnabled) as? Bool ?? Self.defaultNotificationMajorTournamentsFilterEnabled)
            )
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
        let apiBaseURL = Self.resolvedAPIBaseURL(userDefaults: userDefaults)
        #if !DEBUG
        if userDefaults.string(forKey: Keys.apiBaseURL) != apiBaseURL {
            userDefaults.set(apiBaseURL, forKey: Keys.apiBaseURL)
        }
        #endif
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
        let showPredictedScores = userDefaults.object(forKey: Keys.showPredictedScores) as? Bool
            ?? Self.defaultShowPredictedScores

        self.selectedLeagues = leagues
        self.selectedFixtureViewOptionIDs = selectedFixtureViewOptionIDs
        self.favouriteFixtureViewOptionIDs = favouriteFixtureViewOptionIDs
        self.favouriteShowPredictedScores = favouriteShowPredictedScores
        self.selectedNotificationLeagues = notificationLeagues
        self.selectedNotificationViewOptionIDs = notificationViewOptionIDs
        self.selectedChannels = ChannelSelection.normalizedSelectedOptions(channels)
        self.competitionFilterEnabled = competitionFilterEnabled
        self.fixtureAllMajorMatchesEnabled = fixtureAllMajorMatchesEnabled
        self.notificationMatchesFixturesEnabled = notificationMatchesFixturesEnabled
        self.notificationAllMajorMatchesEnabled = notificationAllMajorMatchesEnabled
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
        self.showPredictedScores = showPredictedScores

        if !showTodayUnfinishedFixturesBadge {
            Task {
                await AppIconBadgeManager.clear()
            }
        }
    }

    var snapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: selectedLeagues,
            selectedFixtureViewOptionIDs: selectedFixtureViewOptionIDs,
            favouriteFixtureViewOptionIDs: favouriteFixtureViewOptionIDs,
            favouriteShowPredictedScores: favouriteShowPredictedScores,
            selectedNotificationLeagues: selectedNotificationLeagues,
            selectedNotificationViewOptionIDs: selectedNotificationViewOptionIDs,
            selectedChannels: selectedChannels,
            fixtureAllMajorMatchesEnabled: fixtureAllMajorMatchesEnabled,
            notificationMatchesFixturesEnabled: notificationMatchesFixturesEnabled,
            notificationAllMajorMatchesEnabled: notificationAllMajorMatchesEnabled,
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

    var currentFixtureViewOptionIDs: Set<String> {
        if showAllMatches { return [FixtureViewOptionID.all] }
        if fixtureAllMajorMatchesEnabled { return Set(favouriteFixtureViewOptionIDs) }
        return Set(selectedFixtureViewOptionIDs)
    }

    var hasUnsavedFixtureViewChanges: Bool {
        currentFixtureViewOptionIDs != Set(favouriteFixtureViewOptionIDs) ||
        showPredictedScores != favouriteShowPredictedScores
    }

    var unfilteredSnapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: selectedLeagues,
            selectedFixtureViewOptionIDs: selectedFixtureViewOptionIDs,
            favouriteFixtureViewOptionIDs: favouriteFixtureViewOptionIDs,
            favouriteShowPredictedScores: favouriteShowPredictedScores,
            selectedNotificationLeagues: selectedNotificationLeagues,
            selectedNotificationViewOptionIDs: selectedNotificationViewOptionIDs,
            selectedChannels: selectedChannels,
            fixtureAllMajorMatchesEnabled: false,
            notificationMatchesFixturesEnabled: notificationMatchesFixturesEnabled,
            notificationAllMajorMatchesEnabled: notificationAllMajorMatchesEnabled,
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

    func persist(userDefaults: UserDefaults? = nil) {
        let userDefaults = userDefaults ?? self.userDefaults
        userDefaults.set(selectedLeagues, forKey: Keys.selectedLeagues)
        userDefaults.set(selectedFixtureViewOptionIDs, forKey: Keys.selectedFixtureViewOptionIDs)
        userDefaults.set(favouriteFixtureViewOptionIDs, forKey: Keys.favouriteFixtureViewOptionIDs)
        userDefaults.set(favouriteShowPredictedScores, forKey: Keys.favouriteShowPredictedScores)
        userDefaults.set(selectedNotificationLeagues, forKey: Keys.selectedNotificationLeagues)
        userDefaults.set(selectedNotificationViewOptionIDs, forKey: Keys.selectedNotificationViewOptionIDs)
        userDefaults.set(selectedChannels, forKey: Keys.selectedChannels)
        userDefaults.set(competitionFilterEnabled, forKey: Keys.competitionFilterEnabled)
        userDefaults.set(fixtureAllMajorMatchesEnabled, forKey: Keys.fixtureAllMajorMatchesEnabled)
        userDefaults.set(notificationMatchesFixturesEnabled, forKey: Keys.notificationMatchesFixturesEnabled)
        userDefaults.set(notificationAllMajorMatchesEnabled, forKey: Keys.notificationAllMajorMatchesEnabled)
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
        userDefaults.set(showPredictedScores, forKey: Keys.showPredictedScores)
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
        let selectedFixtureViewOptionIDs = userDefaults.stringArray(forKey: Keys.selectedFixtureViewOptionIDs)
            ?? leagues.map(FixtureViewOptionID.legacyCompetition)
        let favouriteFixtureViewOptionIDs = userDefaults.stringArray(forKey: Keys.favouriteFixtureViewOptionIDs)
            ?? Self.defaultFavouriteFixtureViewOptionIDs
        let favouriteShowPredictedScores = userDefaults.object(forKey: Keys.favouriteShowPredictedScores) as? Bool
            ?? Self.defaultFavouriteShowPredictedScores
        let notificationLeagues = userDefaults.stringArray(forKey: Keys.selectedNotificationLeagues) ?? leagues
        let notificationViewOptionIDs = userDefaults.stringArray(forKey: Keys.selectedNotificationViewOptionIDs)
            ?? notificationLeagues.map(FixtureViewOptionID.legacyCompetition)
        let channels = userDefaults.stringArray(forKey: Keys.selectedChannels) ?? Self.defaultSelectedChannels
        let competitionFilterEnabled = userDefaults.object(forKey: Keys.competitionFilterEnabled) as? Bool
            ?? Self.defaultCompetitionFilterEnabled
        let fixtureAllMajorMatchesEnabled = userDefaults.object(forKey: Keys.fixtureAllMajorMatchesEnabled) as? Bool
            ?? (
                (userDefaults.object(forKey: Keys.englishPremierLeagueTeamsOnly) as? Bool ?? Self.defaultEnglishPremierLeagueTeamsOnly) &&
                (userDefaults.object(forKey: Keys.majorUEFAClubGamesEnabled) as? Bool ?? Self.defaultMajorUEFAClubGamesEnabled) &&
                (userDefaults.object(forKey: Keys.homeNationsFilterEnabled) as? Bool ?? Self.defaultHomeNationsFilterEnabled) &&
                (userDefaults.object(forKey: Keys.majorTournamentsFilterEnabled) as? Bool ?? Self.defaultMajorTournamentsFilterEnabled)
            )
        let notificationMatchesFixturesEnabled = userDefaults.object(forKey: Keys.notificationMatchesFixturesEnabled) as? Bool
            ?? Self.defaultNotificationMatchesFixturesEnabled
        let notificationAllMajorMatchesEnabled = userDefaults.object(forKey: Keys.notificationAllMajorMatchesEnabled) as? Bool
            ?? (
                (userDefaults.object(forKey: Keys.notificationPremierLeagueTeamsOnly) as? Bool ?? Self.defaultNotificationPremierLeagueTeamsOnly) &&
                (userDefaults.object(forKey: Keys.notificationMajorUEFAClubGamesEnabled) as? Bool ?? Self.defaultNotificationMajorUEFAClubGamesEnabled) &&
                (userDefaults.object(forKey: Keys.notificationHomeNationsFilterEnabled) as? Bool ?? Self.defaultNotificationHomeNationsFilterEnabled) &&
                (userDefaults.object(forKey: Keys.notificationMajorTournamentsFilterEnabled) as? Bool ?? Self.defaultNotificationMajorTournamentsFilterEnabled)
            )
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
        let apiBaseURL = Self.resolvedAPIBaseURL(userDefaults: userDefaults)
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
            selectedFixtureViewOptionIDs: selectedFixtureViewOptionIDs,
            favouriteFixtureViewOptionIDs: favouriteFixtureViewOptionIDs,
            favouriteShowPredictedScores: favouriteShowPredictedScores,
            selectedNotificationLeagues: notificationLeagues,
            selectedNotificationViewOptionIDs: notificationViewOptionIDs,
            selectedChannels: ChannelSelection.normalizedSelectedOptions(channels),
            fixtureAllMajorMatchesEnabled: fixtureAllMajorMatchesEnabled,
            notificationMatchesFixturesEnabled: notificationMatchesFixturesEnabled,
            notificationAllMajorMatchesEnabled: notificationAllMajorMatchesEnabled,
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
        static let selectedFixtureViewOptionIDs = "preferences.selectedFixtureViewOptionIDs"
        static let favouriteFixtureViewOptionIDs = "preferences.favouriteFixtureViewOptionIDs"
        static let favouriteShowPredictedScores = "preferences.favouriteShowPredictedScores"
        static let selectedNotificationLeagues = "preferences.selectedNotificationLeagues"
        static let selectedNotificationViewOptionIDs = "preferences.selectedNotificationViewOptionIDs"
        static let selectedChannels = "preferences.selectedChannels"
        static let competitionFilterEnabled = "preferences.competitionFilterEnabled"
        static let fixtureAllMajorMatchesEnabled = "preferences.fixtureAllMajorMatchesEnabled"
        static let notificationMatchesFixturesEnabled = "preferences.notificationMatchesFixturesEnabled"
        static let notificationAllMajorMatchesEnabled = "preferences.notificationAllMajorMatchesEnabled"
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
        static let showPredictedScores = "preferences.showPredictedScores"
    }
}
