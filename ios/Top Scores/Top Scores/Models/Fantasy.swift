import Foundation

struct FantasyGameweek: Codable, Hashable {
    let id: Int
    let name: String?
    let isCurrent: Bool?
    let isNext: Bool?
    let deadlineTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isCurrent = "is_current"
        case isNext = "is_next"
        case deadlineTime = "deadline_time"
    }
}

struct FantasyBootstrapLookup: Codable, Hashable {
    let updatedAt: String?
    let elements: [FantasyBootstrapElement]
    let teams: [FantasyBootstrapTeam]
    let elementTypes: [FantasyBootstrapElementType]
    let events: [FantasyGameweek]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case elements
        case teams
        case elementTypes = "element_types"
        case events
    }
}

struct FantasyBootstrapElement: Codable, Hashable {
    let id: Int
    let webName: String
    let firstName: String
    let secondName: String
    let team: Int
    let elementType: Int
    let photo: String?
    let status: String?
    let news: String?
    let nowCost: Int?
    let form: String?
    let pointsPerGame: String?
    let eventPoints: Int?
    let totalPoints: Int?
    let bonus: Int?
    let ictIndex: String?
    let selectedByPercent: String?
    let chanceOfPlayingThisRound: Int?
    let chanceOfPlayingNextRound: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case webName = "web_name"
        case firstName = "first_name"
        case secondName = "second_name"
        case team
        case elementType = "element_type"
        case photo
        case status
        case news
        case nowCost = "now_cost"
        case form
        case pointsPerGame = "points_per_game"
        case eventPoints = "event_points"
        case totalPoints = "total_points"
        case bonus
        case ictIndex = "ict_index"
        case selectedByPercent = "selected_by_percent"
        case chanceOfPlayingThisRound = "chance_of_playing_this_round"
        case chanceOfPlayingNextRound = "chance_of_playing_next_round"
    }
}

struct FantasyBootstrapTeam: Codable, Hashable {
    let id: Int
    let name: String
    let shortName: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortName = "short_name"
    }
}

struct FantasyBootstrapElementType: Codable, Hashable {
    let id: Int
    let singularName: String
    let singularNameShort: String

    enum CodingKeys: String, CodingKey {
        case id
        case singularName = "singular_name"
        case singularNameShort = "singular_name_short"
    }
}

struct FantasyPicksResponse: Codable, Hashable {
    let picks: [FantasyPick]
    let entryHistory: FantasyEntryHistory

    enum CodingKeys: String, CodingKey {
        case picks
        case entryHistory = "entry_history"
    }
}

struct FantasyPick: Codable, Hashable {
    let element: Int
    let position: Int
    let multiplier: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let elementType: Int?

    enum CodingKeys: String, CodingKey {
        case element
        case position
        case multiplier
        case isCaptain = "is_captain"
        case isViceCaptain = "is_vice_captain"
        case elementType = "element_type"
    }
}

struct FantasyEntryHistory: Codable, Hashable {
    let event: Int
    let points: Int
    let rank: Int?
    let overallRank: Int?
    let eventTransfersCost: Int?
    let pointsOnBench: Int?

    enum CodingKeys: String, CodingKey {
        case event
        case points
        case rank
        case overallRank = "overall_rank"
        case eventTransfersCost = "event_transfers_cost"
        case pointsOnBench = "points_on_bench"
    }
}

struct FantasyEventLiveResponse: Codable, Hashable {
    let elements: [FantasyLiveElement]
}

struct FantasyElementSummaryResponse: Codable, Hashable {
    let fixtures: [FantasyElementSummaryFixture]
    let history: [FantasyElementSummaryHistory]

    enum CodingKeys: String, CodingKey {
        case fixtures
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixtures = (try? container.decode([FantasyElementSummaryFixture].self, forKey: .fixtures)) ?? []
        history = (try? container.decode([FantasyElementSummaryHistory].self, forKey: .history)) ?? []
    }
}

struct FantasyElementSummaryFixture: Codable, Hashable {
    let event: Int?
    let opponentTeam: Int?
    let teamH: Int?
    let teamA: Int?
    let isHome: Bool?
    let difficulty: Int?
    let kickoffTime: String?
    let finished: Bool?

    enum CodingKeys: String, CodingKey {
        case event
        case opponentTeam = "opponent_team"
        case teamH = "team_h"
        case teamA = "team_a"
        case isHome = "is_home"
        case difficulty
        case kickoffTime = "kickoff_time"
        case finished
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = Self.decodeFlexibleInt(container: container, key: .event)
        opponentTeam = Self.decodeFlexibleInt(container: container, key: .opponentTeam)
        teamH = Self.decodeFlexibleInt(container: container, key: .teamH)
        teamA = Self.decodeFlexibleInt(container: container, key: .teamA)
        difficulty = Self.decodeFlexibleInt(container: container, key: .difficulty)
        kickoffTime = try? container.decode(String.self, forKey: .kickoffTime)
        finished = try? container.decode(Bool.self, forKey: .finished)

        if let value = try? container.decode(Bool.self, forKey: .isHome) {
            isHome = value
        } else if let value = Self.decodeFlexibleInt(container: container, key: .isHome) {
            isHome = value != 0
        } else {
            isHome = nil
        }
    }

    private static func decodeFlexibleInt(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
            return nil
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct FantasyElementSummaryHistory: Codable, Hashable {
    let round: Int
    let opponentTeam: Int
    let wasHome: Bool
    let totalPoints: Int
    let starts: Int
    let minutes: Int
    let goalsScored: Int
    let assists: Int
    let cleanSheets: Int
    let goalsConceded: Int
    let ownGoals: Int
    let penaltiesSaved: Int
    let penaltiesMissed: Int
    let yellowCards: Int
    let redCards: Int
    let saves: Int
    let bonus: Int
    let defensiveContribution: Int
    let expectedGoals: String?
    let kickoffTime: String?

    enum CodingKeys: String, CodingKey {
        case round
        case opponentTeam = "opponent_team"
        case wasHome = "was_home"
        case totalPoints = "total_points"
        case starts
        case minutes
        case goalsScored = "goals_scored"
        case assists
        case cleanSheets = "clean_sheets"
        case goalsConceded = "goals_conceded"
        case ownGoals = "own_goals"
        case penaltiesSaved = "penalties_saved"
        case penaltiesMissed = "penalties_missed"
        case yellowCards = "yellow_cards"
        case redCards = "red_cards"
        case saves
        case bonus
        case defensiveContribution = "defensive_contribution"
        case expectedGoals = "expected_goals"
        case kickoffTime = "kickoff_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        round = Self.decodeFlexibleInt(container: container, key: .round) ?? 0
        opponentTeam = Self.decodeFlexibleInt(container: container, key: .opponentTeam) ?? 0
        totalPoints = Self.decodeFlexibleInt(container: container, key: .totalPoints) ?? 0
        starts = Self.decodeFlexibleInt(container: container, key: .starts) ?? 0
        minutes = Self.decodeFlexibleInt(container: container, key: .minutes) ?? 0
        goalsScored = Self.decodeFlexibleInt(container: container, key: .goalsScored) ?? 0
        assists = Self.decodeFlexibleInt(container: container, key: .assists) ?? 0
        cleanSheets = Self.decodeFlexibleInt(container: container, key: .cleanSheets) ?? 0
        goalsConceded = Self.decodeFlexibleInt(container: container, key: .goalsConceded) ?? 0
        ownGoals = Self.decodeFlexibleInt(container: container, key: .ownGoals) ?? 0
        penaltiesSaved = Self.decodeFlexibleInt(container: container, key: .penaltiesSaved) ?? 0
        penaltiesMissed = Self.decodeFlexibleInt(container: container, key: .penaltiesMissed) ?? 0
        yellowCards = Self.decodeFlexibleInt(container: container, key: .yellowCards) ?? 0
        redCards = Self.decodeFlexibleInt(container: container, key: .redCards) ?? 0
        saves = Self.decodeFlexibleInt(container: container, key: .saves) ?? 0
        bonus = Self.decodeFlexibleInt(container: container, key: .bonus) ?? 0
        defensiveContribution = Self.decodeFlexibleInt(container: container, key: .defensiveContribution) ?? 0
        kickoffTime = try? container.decode(String.self, forKey: .kickoffTime)

        if let value = try? container.decode(Bool.self, forKey: .wasHome) {
            wasHome = value
        } else if let value = Self.decodeFlexibleInt(container: container, key: .wasHome) {
            wasHome = value != 0
        } else {
            wasHome = false
        }

        if let value = try? container.decode(String.self, forKey: .expectedGoals) {
            expectedGoals = value
        } else if let value = try? container.decode(Double.self, forKey: .expectedGoals) {
            expectedGoals = String(format: "%.2f", value)
        } else if let value = try? container.decode(Int.self, forKey: .expectedGoals) {
            expectedGoals = String(format: "%.2f", Double(value))
        } else {
            expectedGoals = nil
        }
    }

    private static func decodeFlexibleInt(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
            return nil
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct FantasyLiveElement: Codable, Hashable {
    let id: Int
    let stats: FantasyLiveStats
}

struct FantasyLiveStats: Codable, Hashable {
    let totalPoints: Int
    let minutes: Int?
    let goalsScored: Int?
    let assists: Int?
    let yellowCards: Int?
    let redCards: Int?

    enum CodingKeys: String, CodingKey {
        case totalPoints = "total_points"
        case minutes
        case goalsScored = "goals_scored"
        case assists
        case yellowCards = "yellow_cards"
        case redCards = "red_cards"
    }
}

struct FantasyFixture: Codable, Hashable {
    let id: Int
    let event: Int?
    let teamH: Int
    let teamA: Int
    let kickoffTime: String?
    let started: Bool?
    let finished: Bool?
    let finishedProvisional: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case event
        case teamH = "team_h"
        case teamA = "team_a"
        case kickoffTime = "kickoff_time"
        case started
        case finished
        case finishedProvisional = "finished_provisional"
    }
}

struct FantasyEntryProfile: Codable, Hashable {
    let id: Int
    let name: String
    let playerFirstName: String
    let playerLastName: String
    let summaryOverallPoints: Int?
    let clubBadgeSrc: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case playerFirstName = "player_first_name"
        case playerLastName = "player_last_name"
        case summaryOverallPoints = "summary_overall_points"
        case clubBadgeSrc = "club_badge_src"
    }
}

struct FantasyLeagueStandingsResponse: Codable, Hashable {
    let newEntries: FantasyLeagueNewEntries?
    let lastUpdatedData: String?
    let league: FantasyClassicLeague
    let standings: FantasyClassicLeagueStandings

    enum CodingKeys: String, CodingKey {
        case newEntries = "new_entries"
        case lastUpdatedData = "last_updated_data"
        case league
        case standings
    }
}

struct FantasyLeagueNewEntries: Codable, Hashable {
    let hasNext: Bool?
    let page: Int?
    let results: [FantasyClassicLeagueStandingEntry]?

    enum CodingKeys: String, CodingKey {
        case hasNext = "has_next"
        case page
        case results
    }
}

struct FantasyClassicLeague: Codable, Hashable {
    let id: Int
    let name: String
}

struct FantasyClassicLeagueStandings: Codable, Hashable {
    let hasNext: Bool
    let page: Int
    let results: [FantasyClassicLeagueStandingEntry]

    enum CodingKeys: String, CodingKey {
        case hasNext = "has_next"
        case page
        case results
    }
}

struct FantasyClassicLeagueStandingEntry: Codable, Hashable, Identifiable {
    let id: Int
    let eventTotal: Int
    let playerName: String
    let rank: Int
    let lastRank: Int?
    let total: Int
    let entry: Int
    let entryName: String
    let clubBadgeSrc: String?

    enum CodingKeys: String, CodingKey {
        case id
        case eventTotal = "event_total"
        case playerName = "player_name"
        case rank
        case lastRank = "last_rank"
        case total
        case entry
        case entryName = "entry_name"
        case clubBadgeSrc = "club_badge_src"
    }
}

struct FantasyTeamShortNameMappingsResponse: Codable, Hashable {
    let updatedAt: String?
    let mappings: [String: String]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case mappings
    }
}

struct FantasyLoadingMessagesResponse: Codable, Hashable {
    let updatedAt: String?
    let messages: [String]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case messages
    }
}

struct FantasyAssistantManagerPhrasesResponse: Codable, Hashable {
    let updatedAt: String?
    let phrases: [String]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case phrases
    }
}

struct FantasyAssistantManagerResponse: Codable, Hashable {
    struct SyncStatus: Codable, Hashable {
        let state: String?
        let lastSeenAt: String?
        let lastRefreshStartedAt: String?
        let lastRefreshCompletedAt: String?
        let lastRefreshTrigger: String?
        let lastError: String?

        enum CodingKeys: String, CodingKey {
            case state
            case lastSeenAt = "last_seen_at"
            case lastRefreshStartedAt = "last_refresh_started_at"
            case lastRefreshCompletedAt = "last_refresh_completed_at"
            case lastRefreshTrigger = "last_refresh_trigger"
            case lastError = "last_error"
        }
    }

    struct SquadSummary: Codable, Hashable {
        let playersCount: Int
        let currentSquadValueMillions: Double
        let reportedTeamValueMillions: Double
        let bankMillions: Double
        let effectiveBudgetMillions: Double
        let teamValueCapMillions: Double
        let transferOptionsConsidered: Int

        enum CodingKeys: String, CodingKey {
            case playersCount = "players_count"
            case currentSquadValueMillions = "current_squad_value_millions"
            case reportedTeamValueMillions = "reported_team_value_millions"
            case bankMillions = "bank_millions"
            case effectiveBudgetMillions = "effective_budget_millions"
            case teamValueCapMillions = "team_value_cap_millions"
            case transferOptionsConsidered = "transfer_options_considered"
        }
    }

    struct TransferMove: Codable, Hashable, Identifiable {
        let outElementID: Int
        let outPlayerName: String
        let outTeamName: String?
        let outTeamShortName: String?
        let outPriceMillions: Double
        let inElementID: Int
        let inPlayerName: String
        let inTeamName: String?
        let inTeamShortName: String?
        let inPriceMillions: Double
        let priceChangeMillions: Double
        let projectedGainNextGameweek: Double
        let projectedGainNext3Gameweeks: Double
        let projectedScoreDelta: Double
        let reasons: [String]

        enum CodingKeys: String, CodingKey {
            case outElementID = "out_element_id"
            case outPlayerName = "out_player_name"
            case outTeamName = "out_team_name"
            case outTeamShortName = "out_team_short_name"
            case outPriceMillions = "out_price_millions"
            case inElementID = "in_element_id"
            case inPlayerName = "in_player_name"
            case inTeamName = "in_team_name"
            case inTeamShortName = "in_team_short_name"
            case inPriceMillions = "in_price_millions"
            case priceChangeMillions = "price_change_millions"
            case projectedGainNextGameweek = "projected_gain_next_gameweek"
            case projectedGainNext3Gameweeks = "projected_gain_next3_gameweeks"
            case projectedScoreDelta = "projected_score_delta"
            case reasons
        }

        var id: String {
            "\(outElementID)-\(inElementID)"
        }
    }

    struct TransferPlan: Codable, Hashable {
        let title: String?
        let summary: String?
        let projectedGainNextGameweek: Double
        let projectedGainNext3Gameweeks: Double
        let projectedScoreDelta: Double
        let reasons: [String]
        let transfers: [TransferMove]

        enum CodingKeys: String, CodingKey {
            case title
            case summary
            case projectedGainNextGameweek = "projected_gain_next_gameweek"
            case projectedGainNext3Gameweeks = "projected_gain_next3_gameweeks"
            case projectedScoreDelta = "projected_score_delta"
            case reasons
            case transfers
        }
    }

    struct CaptainRecommendation: Codable, Hashable, Identifiable {
        let elementID: Int
        let playerName: String
        let teamShortName: String?
        let opponentLabel: String
        let availability: String
        let expectedPointsNextGameweek: Double
        let expectedPointsNext3Gameweeks: Double
        let reasons: [String]

        enum CodingKeys: String, CodingKey {
            case elementID = "element_id"
            case playerName = "player_name"
            case teamShortName = "team_short_name"
            case opponentLabel = "opponent_label"
            case availability
            case expectedPointsNextGameweek = "expected_points_next_gameweek"
            case expectedPointsNext3Gameweeks = "expected_points_next3_gameweeks"
            case reasons
        }

        var id: Int {
            elementID
        }
    }

    struct CaptainRecommendations: Codable, Hashable {
        let summary: String?
        let captain: [CaptainRecommendation]
        let viceCaptain: [CaptainRecommendation]

        enum CodingKeys: String, CodingKey {
            case summary
            case captain
            case viceCaptain = "vice_captain"
        }
    }

    struct IdealSquadPlayer: Codable, Hashable, Identifiable {
        let elementID: Int
        let pickPosition: Int
        let playerName: String
        let teamID: Int
        let teamName: String
        let teamShortName: String?
        let positionID: Int
        let position: String
        let nowCostMillions: Double
        let expectedPointsNextGameweek: Double
        let expectedPointsNext3Gameweeks: Double
        let assistantRankScore: Double
        let rawPoints: Int
        let appliedPoints: Int
        let multiplier: Int
        let isCaptain: Bool
        let isViceCaptain: Bool
        let isPlayingNow: Bool
        let isUnavailable: Bool
        let isDefinitelyUnavailable: Bool
        let hasAnyFixtureThisGameweek: Bool
        let hasUpcomingFixtureThisGameweek: Bool
        let hasActiveFixtureThisGameweek: Bool
        let hasFutureAvailabilityIssue: Bool
        let futureAvailabilityIssueGameweek: Int?
        let minutesPlayed: Int
        let upcomingOpponentDisplay: String?
        let goalsScored: Int
        let assists: Int
        let yellowCards: Int
        let redCards: Int

        enum CodingKeys: String, CodingKey {
            case elementID = "element_id"
            case pickPosition = "pick_position"
            case playerName = "player_name"
            case teamID = "team_id"
            case teamName = "team_name"
            case teamShortName = "team_short_name"
            case positionID = "position_id"
            case position
            case nowCostMillions = "now_cost_millions"
            case expectedPointsNextGameweek = "expected_points_next_gameweek"
            case expectedPointsNext3Gameweeks = "expected_points_next3_gameweeks"
            case assistantRankScore = "assistant_rank_score"
            case rawPoints = "raw_points"
            case appliedPoints = "applied_points"
            case multiplier
            case isCaptain = "is_captain"
            case isViceCaptain = "is_vice_captain"
            case isPlayingNow = "is_playing_now"
            case isUnavailable = "is_unavailable"
            case isDefinitelyUnavailable = "is_definitely_unavailable"
            case hasAnyFixtureThisGameweek = "has_any_fixture_this_gameweek"
            case hasUpcomingFixtureThisGameweek = "has_upcoming_fixture_this_gameweek"
            case hasActiveFixtureThisGameweek = "has_active_fixture_this_gameweek"
            case hasFutureAvailabilityIssue = "has_future_availability_issue"
            case futureAvailabilityIssueGameweek = "future_availability_issue_gameweek"
            case minutesPlayed = "minutes_played"
            case upcomingOpponentDisplay = "upcoming_opponent_display"
            case goalsScored = "goals_scored"
            case assists
            case yellowCards = "yellow_cards"
            case redCards = "red_cards"
        }

        var id: Int { elementID }
    }

    struct IdealSquadStarters: Codable, Hashable {
        let goalkeepers: [IdealSquadPlayer]
        let defenders: [IdealSquadPlayer]
        let midfielders: [IdealSquadPlayer]
        let forwards: [IdealSquadPlayer]
    }

    struct IdealSquad: Codable, Hashable {
        let title: String?
        let summary: String?
        let formation: String?
        let totalValueMillions: Double
        let expectedPointsNextGameweek: Double
        let displayedTotalPoints: Int
        let displayedBenchPoints: Int
        let hasActiveFixtures: Bool
        let hasStartedFixturesInGameweek: Bool
        let hasFixturesPlayedToday: Bool
        let starters: IdealSquadStarters
        let bench: [IdealSquadPlayer]

        enum CodingKeys: String, CodingKey {
            case title
            case summary
            case formation
            case totalValueMillions = "total_value_millions"
            case expectedPointsNextGameweek = "expected_points_next_gameweek"
            case displayedTotalPoints = "displayed_total_points"
            case displayedBenchPoints = "displayed_bench_points"
            case hasActiveFixtures = "has_active_fixtures"
            case hasStartedFixturesInGameweek = "has_started_fixtures_in_gameweek"
            case hasFixturesPlayedToday = "has_fixtures_played_today"
            case starters
            case bench
        }
    }

    let entryID: Int
    let currentEventID: Int?
    let currentEventName: String?
    let ready: Bool
    let stale: Bool?
    let source: String?
    let generatedAt: String?
    let algorithmSummary: String?
    let squadSummary: SquadSummary?
    let topSingleTransfer: TransferPlan?
    let topDoubleTransfers: TransferPlan?
    let topTripleTransfers: TransferPlan?
    let moneyNoObjectTransfers: TransferPlan?
    let idealSquad: IdealSquad?
    let captainRecommendations: CaptainRecommendations?
    let syncStatus: SyncStatus?

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case currentEventID = "current_event_id"
        case currentEventName = "current_event_name"
        case ready
        case stale
        case source
        case generatedAt = "generated_at"
        case algorithmSummary = "algorithm_summary"
        case squadSummary = "squad_summary"
        case topSingleTransfer = "top_single_transfer"
        case topDoubleTransfers = "top_double_transfers"
        case topTripleTransfers = "top_triple_transfers"
        case moneyNoObjectTransfers = "money_no_object_transfers"
        case idealSquad = "ideal_squad"
        case captainRecommendations = "captain_recommendations"
        case syncStatus = "sync_status"
    }
}

struct FantasyTransferRecommendationsResponse: Codable, Hashable {
    struct Criteria: Codable, Hashable {
        let elementID: Int
        let playerName: String
        let positionID: Int
        let position: String
        let valueMillions: Double
        let valueWindowMillions: Double
        let budgetDiscountFraction: Double
        let budgetMaxValueMillions: Double
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case elementID = "element_id"
            case playerName = "player_name"
            case positionID = "position_id"
            case position
            case valueMillions = "value_millions"
            case valueWindowMillions = "value_window_millions"
            case budgetDiscountFraction = "budget_discount_fraction"
            case budgetMaxValueMillions = "budget_max_value_millions"
            case limit
        }
    }

    let source: String?
    let updatedAt: String?
    let ageSeconds: Int?
    let stale: Bool?
    let criteria: Criteria?
    let similarValue: [FantasyTransferRecommendation]
    let budget: [FantasyTransferRecommendation]

    enum CodingKeys: String, CodingKey {
        case source
        case updatedAt = "updated_at"
        case ageSeconds = "age_seconds"
        case stale
        case criteria
        case similarValue = "similar_value"
        case budget
    }
}

struct FantasyTransferRecommendation: Codable, Hashable, Identifiable {
    struct Fixture: Codable, Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int
        let opponentShortName: String
        let isHome: Bool
        let difficulty: Int?
        let label: String?
        let isBlank: Bool

        init(
            gameweek: Int,
            opponentTeamID: Int,
            opponentShortName: String,
            isHome: Bool,
            difficulty: Int?,
            label: String?,
            isBlank: Bool
        ) {
            self.gameweek = gameweek
            self.opponentTeamID = opponentTeamID
            self.opponentShortName = opponentShortName
            self.isHome = isHome
            self.difficulty = difficulty
            self.label = label
            self.isBlank = isBlank
        }

        enum CodingKeys: String, CodingKey {
            case gameweek
            case opponentTeamID = "opponent_team_id"
            case opponentShortName = "opponent_short_name"
            case isHome = "is_home"
            case difficulty
            case label
            case isBlank = "is_blank"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                gameweek: try container.decode(Int.self, forKey: .gameweek),
                opponentTeamID: try container.decode(Int.self, forKey: .opponentTeamID),
                opponentShortName: try container.decode(String.self, forKey: .opponentShortName),
                isHome: try container.decode(Bool.self, forKey: .isHome),
                difficulty: try container.decodeIfPresent(Int.self, forKey: .difficulty),
                label: try container.decodeIfPresent(String.self, forKey: .label),
                isBlank: try container.decodeIfPresent(Bool.self, forKey: .isBlank) ?? false
            )
        }

        static func blank(gameweek: Int) -> Self {
            .init(
                gameweek: gameweek,
                opponentTeamID: 0,
                opponentShortName: "No game",
                isHome: false,
                difficulty: nil,
                label: "No game",
                isBlank: true
            )
        }

        var id: String {
            "gw\(gameweek)-opp\(opponentTeamID)-\(isHome ? "h" : "a")-\(isBlank ? "blank" : "fixture")"
        }

        var displayLabel: String {
            if isBlank {
                return "No game"
            }
            if let label {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return "\(opponentShortName) (\(isHome ? "H" : "A"))"
        }
    }

    struct ScoreBreakdown: Codable, Hashable {
        let formScore: Double
        let fixtureScore: Double
        let pointsPerGameScore: Double
        let valueEfficiencyScore: Double
        let availabilityPenalty: Double

        enum CodingKeys: String, CodingKey {
            case formScore = "form_score"
            case fixtureScore = "fixture_score"
            case pointsPerGameScore = "points_per_game_score"
            case valueEfficiencyScore = "value_efficiency_score"
            case availabilityPenalty = "availability_penalty"
        }
    }

    let elementID: Int
    let webName: String
    let playerName: String
    let teamID: Int
    let teamName: String
    let teamShortName: String?
    let positionID: Int
    let position: String
    let nowCostMillions: Double
    let valueDeltaMillions: Double
    let form: Double
    let formLast5ProxyPoints: Double
    let pointsPerGame: Double
    let epNext: Double
    let totalPoints: Int
    let eventPoints: Int
    let status: String
    let chanceOfPlayingNextRound: Int
    let chanceOfPlayingThisRound: Int
    let news: String
    let availability: String
    let projectedNext5Difficulty: Int
    let projectedNext5Ease: Double
    let nextFixture: Fixture?
    let nextFiveFixtures: [Fixture]?
    let recommendationScore: Double
    let scoreBreakdown: ScoreBreakdown?

    enum CodingKeys: String, CodingKey {
        case elementID = "element_id"
        case webName = "web_name"
        case playerName = "player_name"
        case teamID = "team_id"
        case teamName = "team_name"
        case teamShortName = "team_short_name"
        case positionID = "position_id"
        case position
        case nowCostMillions = "now_cost_millions"
        case valueDeltaMillions = "value_delta_millions"
        case form
        case formLast5ProxyPoints = "form_last5_proxy_points"
        case pointsPerGame = "points_per_game"
        case epNext = "ep_next"
        case totalPoints = "total_points"
        case eventPoints = "event_points"
        case status
        case chanceOfPlayingNextRound = "chance_of_playing_next_round"
        case chanceOfPlayingThisRound = "chance_of_playing_this_round"
        case news
        case availability
        case projectedNext5Difficulty = "projected_next5_difficulty"
        case projectedNext5Ease = "projected_next5_ease"
        case nextFixture = "next_fixture"
        case nextFiveFixtures = "next_five_fixtures"
        case recommendationScore = "recommendation_score"
        case scoreBreakdown = "score_breakdown"
    }

    var id: Int { elementID }

    var upcomingFixtures: [Fixture] {
        if let nextFiveFixtures, !nextFiveFixtures.isEmpty {
            return nextFiveFixtures
        }
        if let nextFixture {
            return [nextFixture]
        }
        return []
    }
}

struct FantasyRivalManager: Codable, Hashable, Identifiable {
    let entryID: Int
    let teamName: String
    let managerFirstName: String
    let managerLastName: String
    let overallPoints: Int?
    let clubBadgeSrc: String?

    var id: Int {
        entryID
    }

    var managerDisplayName: String {
        let combined = [managerFirstName, managerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined.isEmpty ? "Manager \(entryID)" : combined
    }
}

struct FantasyTrackedLeague: Codable, Hashable, Identifiable {
    let leagueID: Int

    var id: Int {
        leagueID
    }
}

struct FantasyTrackedLeagueStanding: Hashable, Identifiable {
    let leagueID: Int
    let leagueName: String
    let myEntryID: Int
    let myRank: Int?
    let myLastRank: Int?
    let myEventTotal: Int?
    let myOverallTotal: Int?
    let myEntryName: String?
    let standings: [FantasyClassicLeagueStandingEntry]

    var id: Int {
        leagueID
    }
}

struct FantasyRivalSquad: Identifiable, Hashable {
    let entryID: Int
    let teamName: String
    let managerName: String
    let clubBadgeSrc: String?
    let squad: FantasySquadDisplayData
    let allGameweeksPoints: Int?

    var id: Int {
        entryID
    }

    var currentScore: Int {
        squad.resolvedCurrentScore
    }
}

enum FantasyPositionType: Int, CaseIterable, Hashable {
    case goalkeeper = 1
    case defender = 2
    case midfielder = 3
    case forward = 4

    var shortLabel: String {
        switch self {
        case .goalkeeper:
            return "GKP"
        case .defender:
            return "DEF"
        case .midfielder:
            return "MID"
        case .forward:
            return "FWD"
        }
    }
}

struct FantasyDisplayPlayer: Identifiable, Hashable {
    let elementID: Int
    let pickPosition: Int
    let positionType: FantasyPositionType
    let displayName: String
    let fullName: String
    let teamName: String
    let nowCostMillions: Double
    let rawPoints: Int
    let appliedPoints: Int
    let displayPoints: Int
    let multiplier: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let isPlayingNow: Bool
    let isUnavailable: Bool
    let isDefinitelyUnavailable: Bool
    let hasAnyFixtureThisGameweek: Bool
    let hasUpcomingFixtureThisGameweek: Bool
    let hasActiveFixtureThisGameweek: Bool
    let hasFutureAvailabilityIssue: Bool
    let futureAvailabilityIssueGameweek: Int?
    let minutesPlayed: Int
    let upcomingOpponentDisplay: String?
    let goalsScored: Int
    let assists: Int
    let yellowCards: Int
    let redCards: Int

    var id: Int {
        elementID
    }

    var isStarter: Bool {
        pickPosition <= 11
    }

    var didNotPlay: Bool {
        minutesPlayed == 0
    }

    var shouldAutoSubAsNonParticipant: Bool {
        guard minutesPlayed == 0 else { return false }
        if isDefinitelyUnavailable { return true }
        if !hasAnyFixtureThisGameweek { return true }
        return !hasUpcomingFixtureThisGameweek && !hasActiveFixtureThisGameweek
    }

    var isEligibleAutoSubReplacement: Bool {
        minutesPlayed > 0
    }
}

struct FantasyMatchTeamSquadSection: Identifiable, Hashable {
    let teamName: String
    let starters: [FantasyDisplayPlayer]
    let bench: [FantasyDisplayPlayer]

    var id: String {
        teamName
    }

    var hasPlayers: Bool {
        !starters.isEmpty || !bench.isEmpty
    }
}

struct FantasyEffectivePlayerContribution: Hashable {
    let elementID: Int
    let displayName: String
    let fullName: String
    let teamName: String
    let points: Int
}

struct FantasySquadDisplayData: Hashable {
    let gameweekID: Int
    let gameweekTitle: String
    let deadlineGameweekID: Int?
    let deadlineTime: String?
    let totalPoints: Int
    let hasActiveFixtures: Bool
    let hasStartedFixturesInGameweek: Bool
    let hasFixturesPlayedToday: Bool
    let isEstimatedScore: Bool
    let estimatedCurrentScore: Int
    let scoreCalculationRulesApplied: [String]
    let rank: Int?
    let overallRank: Int?
    let transfersCost: Int?
    let pointsOnBench: Int?
    let goalkeepers: [FantasyDisplayPlayer]
    let defenders: [FantasyDisplayPlayer]
    let midfielders: [FantasyDisplayPlayer]
    let forwards: [FantasyDisplayPlayer]
    let bench: [FantasyDisplayPlayer]

    var starters: [FantasyDisplayPlayer] {
        (goalkeepers + defenders + midfielders + forwards)
            .sorted { $0.pickPosition < $1.pickPosition }
    }

    var computedAppliedPointsTotal: Int {
        starters.reduce(0) { $0 + $1.appliedPoints }
    }

    var allPlayers: [FantasyDisplayPlayer] {
        (starters + bench).sorted { $0.pickPosition < $1.pickPosition }
    }

    var resolvedCurrentScore: Int {
        isEstimatedScore
            ? estimatedCurrentScore
            : totalPoints
    }

    var effectivePlayerContributions: [FantasyEffectivePlayerContribution] {
        var contributionsByElementID: [Int: Int] = [:]
        let playersByElementID = Dictionary(uniqueKeysWithValues: allPlayers.map { ($0.elementID, $0) })

        for starter in starters {
            contributionsByElementID[starter.elementID] = starter.appliedPoints
        }
        for benchPlayer in bench {
            contributionsByElementID[benchPlayer.elementID] = 0
        }

        if let unavailableStartingGoalkeeper = starters.first(where: { player in
            player.positionType == .goalkeeper && player.shouldAutoSubAsNonParticipant
        }),
           let benchGoalkeeper = bench.first(where: { $0.positionType == .goalkeeper && $0.isEligibleAutoSubReplacement }) {
            contributionsByElementID[unavailableStartingGoalkeeper.elementID] = 0
            contributionsByElementID[benchGoalkeeper.elementID] = benchGoalkeeper.rawPoints
        }

        let minimumFormation: [FantasyPositionType: Int] = [
            .defender: 3,
            .midfielder: 2,
            .forward: 1
        ]
        var activeOutfieldCounts: [FantasyPositionType: Int] = [.defender: 0, .midfielder: 0, .forward: 0]
        for player in starters where player.positionType != .goalkeeper {
            activeOutfieldCounts[player.positionType, default: 0] += 1
        }

        var nonPlayingOutfieldStarters = starters
            .filter { $0.positionType != .goalkeeper && $0.shouldAutoSubAsNonParticipant }
            .sorted { $0.pickPosition < $1.pickPosition }
        let playedOutfieldBench = bench
            .filter { $0.positionType != .goalkeeper && $0.isEligibleAutoSubReplacement }
            .sorted { $0.pickPosition < $1.pickPosition }

        for benchPlayer in playedOutfieldBench {
            guard !nonPlayingOutfieldStarters.isEmpty else { break }

            let replacementIndex = nonPlayingOutfieldStarters.firstIndex { starter in
                var simulatedCounts = activeOutfieldCounts
                simulatedCounts[starter.positionType, default: 0] -= 1
                simulatedCounts[benchPlayer.positionType, default: 0] += 1
                let defendersOK = (simulatedCounts[.defender] ?? 0) >= (minimumFormation[.defender] ?? 0)
                let midfieldersOK = (simulatedCounts[.midfielder] ?? 0) >= (minimumFormation[.midfielder] ?? 0)
                let forwardsOK = (simulatedCounts[.forward] ?? 0) >= (minimumFormation[.forward] ?? 0)
                return defendersOK && midfieldersOK && forwardsOK
            }

            guard let replacementIndex else { continue }
            let replacedStarter = nonPlayingOutfieldStarters.remove(at: replacementIndex)

            activeOutfieldCounts[replacedStarter.positionType, default: 0] -= 1
            activeOutfieldCounts[benchPlayer.positionType, default: 0] += 1

            contributionsByElementID[replacedStarter.elementID] = 0
            contributionsByElementID[benchPlayer.elementID] = benchPlayer.rawPoints
        }

        if let captain = starters.first(where: { $0.isCaptain && $0.shouldAutoSubAsNonParticipant }),
           let viceCaptain = allPlayers.first(where: { $0.isViceCaptain && $0.isEligibleAutoSubReplacement }) {
            contributionsByElementID[captain.elementID] = 0
            contributionsByElementID[viceCaptain.elementID, default: 0] += viceCaptain.rawPoints
        }

        return allPlayers.compactMap { player in
            guard let points = contributionsByElementID[player.elementID], points != 0 else { return nil }
            return FantasyEffectivePlayerContribution(
                elementID: player.elementID,
                displayName: player.displayName,
                fullName: player.fullName,
                teamName: player.teamName,
                points: points
            )
        }
    }

    func matchSquadSection(forTeamName teamName: String) -> FantasyMatchTeamSquadSection? {
        let normalizedTeamName = Self.normalizedMatchSquadTeamName(teamName)
        let matchedPlayers = allPlayers
            .filter { Self.normalizedMatchSquadTeamName($0.teamName) == normalizedTeamName }
            .sorted(by: Self.matchSquadPlayerSortOrder)

        guard !matchedPlayers.isEmpty else { return nil }

        return FantasyMatchTeamSquadSection(
            teamName: teamName,
            starters: matchedPlayers.filter(\.isStarter),
            bench: matchedPlayers.filter { !$0.isStarter }
        )
    }

    private static func normalizedMatchSquadTeamName(_ value: String) -> String {
        let resolved = FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: value)
        return resolved
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func matchSquadPlayerSortOrder(
        _ lhs: FantasyDisplayPlayer,
        _ rhs: FantasyDisplayPlayer
    ) -> Bool {
        if lhs.isStarter != rhs.isStarter {
            return lhs.isStarter && !rhs.isStarter
        }
        if lhs.pickPosition != rhs.pickPosition {
            return lhs.pickPosition < rhs.pickPosition
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

struct FantasyPlayerDetailsData: Hashable {
    enum StatusSeverity: String, Hashable {
        case warning
        case info
    }

    struct StatusUpdate: Hashable, Identifiable {
        let message: String
        let severity: StatusSeverity

        var id: String {
            "\(severity.rawValue)-\(message)"
        }
    }

    struct Metric: Hashable {
        let title: String
        let value: String
    }

    struct PointsBreakdownItem: Hashable, Identifiable {
        let title: String
        let points: Int

        var id: String {
            title
        }
    }

    struct FormItem: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int?
        let opponentTeamName: String
        let wasHome: Bool?
        let points: Int?
        let isBlank: Bool

        var id: String {
            "\(gameweek)-\(opponentTeamID ?? -1)-\(wasHome ?? false)-\(points ?? -1)-\(isBlank)"
        }
    }

    struct UpcomingFixture: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int?
        let opponentTeamName: String
        let isHome: Bool?
        let difficulty: Int?
        let isBlank: Bool

        var id: String {
            "\(gameweek)-\(opponentTeamID ?? -1)-\(isHome ?? false)-\(difficulty ?? -1)-\(isBlank)"
        }
    }

    struct HistoryRow: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int
        let opponentTeamName: String
        let wasHome: Bool
        let points: Int
        let starts: Int
        let minutes: Int
        let goalsScored: Int
        let assists: Int
        let expectedGoals: String

        var id: String {
            "\(gameweek)-\(opponentTeamID)-\(wasHome)-\(points)-\(minutes)"
        }
    }

    let elementID: Int
    let playerName: String
    let teamName: String
    let teamID: Int
    let position: String
    let statusUpdates: [StatusUpdate]
    let metrics: [Metric]
    let latestPointsBreakdown: [PointsBreakdownItem]
    let formItems: [FormItem]
    let upcomingFixtures: [UpcomingFixture]
    let historyRows: [HistoryRow]
}

enum FantasyPlayerDetailsBuilder {
    static func build(
        elementID: Int,
        gameweekID: Int,
        bootstrap: FantasyBootstrapLookup,
        summary: FantasyElementSummaryResponse
    ) throws -> FantasyPlayerDetailsData {
        guard let element = bootstrap.elements.first(where: { $0.id == elementID }) else {
            throw FantasyPublicAPIError.decodeFailed(
                operation: "fpl_element_summary",
                underlying: NSError(domain: "Fantasy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing bootstrap element for player \(elementID)."])
            )
        }

        let teamsByID = Dictionary(uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0) })
        let positionByID = Dictionary(uniqueKeysWithValues: bootstrap.elementTypes.map { ($0.id, $0.singularName) })
        let team = teamsByID[element.team]
        let teamName = team?.name ?? "Unknown Team"
        let position = positionByID[element.elementType] ?? "Player"

        let sortedHistory = summary.history.sorted { lhs, rhs in
            if lhs.round != rhs.round {
                return lhs.round > rhs.round
            }
            return (lhs.kickoffTime ?? "") > (rhs.kickoffTime ?? "")
        }
        let positionType = FantasyPositionType(rawValue: element.elementType)

        let latestGameweekPoints = sortedHistory
            .filter { $0.round == gameweekID }
            .reduce(0) { $0 + $1.totalPoints }
        let resolvedLatestPoints = latestGameweekPoints > 0 ? latestGameweekPoints : (element.eventPoints ?? 0)

        var statusUpdates: [FantasyPlayerDetailsData.StatusUpdate] = []
        var seenStatusMessages = Set<String>()

        func appendStatus(
            _ message: String,
            severity: FantasyPlayerDetailsData.StatusSeverity
        ) {
            let normalized = message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return }
            guard !seenStatusMessages.contains(normalized) else { return }
            seenStatusMessages.insert(normalized)
            statusUpdates.append(
                FantasyPlayerDetailsData.StatusUpdate(
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    severity: severity
                )
            )
        }

        if let chance = element.chanceOfPlayingNextRound, chance < 100 {
            if chance == 0 {
                appendStatus("Unavailable - 0% chance of playing", severity: .warning)
            } else {
                appendStatus("Knock - \(chance)% chance of playing", severity: .warning)
            }
        }
        let news = (element.news ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !news.isEmpty {
            appendStatus(news, severity: .warning)
        }

        let fixtureEventIDs = Set(summary.fixtures.compactMap(\.event))
        let currentGameweekFixtures = summary.fixtures.filter { $0.event == gameweekID }
        let hasUnfinishedCurrentGameweekFixture = currentGameweekFixtures.contains { $0.finished != true }
        let fixturesStartGameweek = hasUnfinishedCurrentGameweekFixture ? gameweekID : (gameweekID + 1)
        let upcomingGameweekRange = fixturesStartGameweek...(fixturesStartGameweek + 4)
        if let firstBlankGameweek = upcomingGameweekRange.first(where: { !fixtureEventIDs.contains($0) }) {
            appendStatus(
                "This player currently has no Premier League fixture in Gameweek \(firstBlankGameweek).",
                severity: .info
            )
        }

        let upcomingCandidates: [FantasyElementSummaryFixture] = summary.fixtures
            .filter { fixture in
                guard let event = fixture.event else { return false }
                if event < fixturesStartGameweek { return false }
                if fixture.finished == true { return false }
                return true
            }
            .sorted { lhs, rhs in
                let leftEvent = lhs.event ?? Int.max
                let rightEvent = rhs.event ?? Int.max
                if leftEvent != rightEvent {
                    return leftEvent < rightEvent
                }
                return (lhs.kickoffTime ?? "") < (rhs.kickoffTime ?? "")
            }

        let upcomingByGameweek: [Int: FantasyElementSummaryFixture] = Dictionary(
            upcomingCandidates.compactMap { fixture in
                guard let event = fixture.event else { return nil }
                return (event, fixture)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let upcoming: [FantasyPlayerDetailsData.UpcomingFixture] = upcomingGameweekRange.map { gw in
            guard
                let fixture = upcomingByGameweek[gw],
                let resolvedOpponentTeam = resolveOpponentTeamID(
                    fixture: fixture,
                    playerTeamID: element.team
                )
            else {
                return FantasyPlayerDetailsData.UpcomingFixture(
                    gameweek: gw,
                    opponentTeamID: nil,
                    opponentTeamName: "No game",
                    isHome: nil,
                    difficulty: nil,
                    isBlank: true
                )
            }

            return FantasyPlayerDetailsData.UpcomingFixture(
                gameweek: gw,
                opponentTeamID: resolvedOpponentTeam,
                opponentTeamName: teamsByID[resolvedOpponentTeam]?.name ?? "Unknown",
                isHome: fixture.isHome ?? true,
                difficulty: fixture.difficulty ?? 3,
                isBlank: false
            )
        }

        let metrics: [FantasyPlayerDetailsData.Metric] = [
            .init(title: "Price", value: formatPrice(element.nowCost)),
            .init(title: "Form", value: formatDecimalString(element.form)),
            .init(title: "Pts / Match", value: formatDecimalString(element.pointsPerGame)),
            .init(title: "Latest GW Pts", value: "\(resolvedLatestPoints)"),
            .init(title: "Total Pts", value: formatInt(element.totalPoints)),
            .init(title: "Total Bonus", value: formatInt(element.bonus)),
            .init(title: "ICT Index", value: formatDecimalString(element.ictIndex)),
            .init(title: "TSB %", value: formatPercent(element.selectedByPercent))
        ]

        let latestHistoryRows: [FantasyElementSummaryHistory] = {
            let rowsForSelectedGW = sortedHistory.filter { $0.round == gameweekID }
            if !rowsForSelectedGW.isEmpty {
                return rowsForSelectedGW
            }
            guard let latestRound = sortedHistory.first?.round else { return [] }
            return sortedHistory.filter { $0.round == latestRound }
        }()
        let currentGameweekRows = sortedHistory.filter { $0.round == gameweekID }
        let hasPlayedCurrentGameweek = currentGameweekRows.contains { $0.minutes > 0 }
        let shouldHideLatestBreakdown =
            resolvedLatestPoints == 0 &&
            hasUnfinishedCurrentGameweekFixture &&
            !hasPlayedCurrentGameweek

        let latestPointsBreakdownItems: [FantasyPlayerDetailsData.PointsBreakdownItem]
        if shouldHideLatestBreakdown {
            latestPointsBreakdownItems = []
        } else {
            latestPointsBreakdownItems = latestPointsBreakdown(
                rows: latestHistoryRows,
                positionType: positionType,
                fallbackTotal: resolvedLatestPoints
            )
        }

        let sortedHistoryForLookup = sortedHistory.sorted { lhs, rhs in
            if lhs.round != rhs.round {
                return lhs.round > rhs.round
            }
            return (lhs.kickoffTime ?? "") > (rhs.kickoffTime ?? "")
        }
        let recentGameweeks = stride(from: gameweekID, through: max(1, gameweekID - 2), by: -1)
        let formItems = recentGameweeks.map { gw in
            guard let row = sortedHistoryForLookup.first(where: { $0.round == gw }) else {
                return FantasyPlayerDetailsData.FormItem(
                    gameweek: gw,
                    opponentTeamID: nil,
                    opponentTeamName: "No game",
                    wasHome: nil,
                    points: nil,
                    isBlank: true
                )
            }

            return FantasyPlayerDetailsData.FormItem(
                gameweek: row.round,
                opponentTeamID: row.opponentTeam,
                opponentTeamName: teamsByID[row.opponentTeam]?.name ?? "Unknown",
                wasHome: row.wasHome,
                points: row.totalPoints,
                isBlank: false
            )
        }

        let historyRows = Array(sortedHistory.prefix(10)).map { row in
            FantasyPlayerDetailsData.HistoryRow(
                gameweek: row.round,
                opponentTeamID: row.opponentTeam,
                opponentTeamName: teamsByID[row.opponentTeam]?.name ?? "Unknown",
                wasHome: row.wasHome,
                points: row.totalPoints,
                starts: row.starts,
                minutes: row.minutes,
                goalsScored: row.goalsScored,
                assists: row.assists,
                expectedGoals: formatDecimalString(row.expectedGoals)
            )
        }

        let fullName = "\(element.firstName) \(element.secondName)".trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPlayerName = fullName.isEmpty ? element.webName : fullName

        return FantasyPlayerDetailsData(
            elementID: elementID,
            playerName: resolvedPlayerName,
            teamName: teamName,
            teamID: element.team,
            position: position,
            statusUpdates: statusUpdates,
            metrics: metrics,
            latestPointsBreakdown: latestPointsBreakdownItems,
            formItems: formItems,
            upcomingFixtures: Array(upcoming),
            historyRows: historyRows
        )
    }

    private static func formatPrice(_ raw: Int?) -> String {
        guard let raw else { return "-" }
        return String(format: "£%.1fm", Double(raw) / 10.0)
    }

    private static func formatInt(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }

    private static func formatDecimalString(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }

    private static func formatPercent(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return "\(trimmed)%"
    }

    private static func latestPointsBreakdown(
        rows: [FantasyElementSummaryHistory],
        positionType: FantasyPositionType?,
        fallbackTotal: Int
    ) -> [FantasyPlayerDetailsData.PointsBreakdownItem] {
        guard !rows.isEmpty else {
            return [
                FantasyPlayerDetailsData.PointsBreakdownItem(
                    title: "Total points",
                    points: fallbackTotal
                )
            ]
        }

        var totals: [String: Int] = [
            "Appearance": 0,
            "Goals": 0,
            "Assists": 0,
            "Clean sheets": 0,
            "Bonus": 0,
            "Saves": 0,
            "Pen saves": 0,
            "Conceded": 0,
            "Pen misses": 0,
            "Own goals": 0,
            "Yellow cards": 0,
            "Red cards": 0
        ]

        let goalPoints = goalPointsPerGoal(for: positionType)
        let cleanSheetPoints = cleanSheetPointsValue(for: positionType)
        let concededApplies = (positionType == .goalkeeper || positionType == .defender)
        let savePointsApplies = positionType == .goalkeeper

        for row in rows {
            totals["Appearance", default: 0] += appearancePoints(for: row.minutes)
            totals["Goals", default: 0] += row.goalsScored * goalPoints
            totals["Assists", default: 0] += row.assists * 3
            totals["Clean sheets", default: 0] += row.cleanSheets * cleanSheetPoints
            totals["Bonus", default: 0] += row.bonus

            if savePointsApplies {
                totals["Saves", default: 0] += row.saves / 3
                totals["Pen saves", default: 0] += row.penaltiesSaved * 5
            }
            if concededApplies {
                totals["Conceded", default: 0] -= row.goalsConceded / 2
            }

            totals["Pen misses", default: 0] -= row.penaltiesMissed * 2
            totals["Own goals", default: 0] -= row.ownGoals * 2
            totals["Yellow cards", default: 0] -= row.yellowCards
            totals["Red cards", default: 0] -= row.redCards * 3
        }

        let knownTotal = totals.values.reduce(0, +)
        let targetTotal = rows.reduce(0) { $0 + $1.totalPoints }
        let residual = targetTotal - knownTotal
        if residual != 0 {
            let hasDefensiveContribution = rows.contains { $0.defensiveContribution > 0 }
            let residualLabel: String
            if hasDefensiveContribution && residual > 0 {
                residualLabel = "Def. contribution"
            } else {
                residualLabel = "Other adjustments"
            }
            totals[residualLabel, default: 0] += residual
        }

        let orderedLabels: [String] = [
            "Appearance",
            "Goals",
            "Assists",
            "Clean sheets",
            "Bonus",
            "Def. contribution",
            "Saves",
            "Pen saves",
            "Conceded",
            "Pen misses",
            "Own goals",
            "Yellow cards",
            "Red cards",
            "Other adjustments"
        ]

        let detailedItems: [FantasyPlayerDetailsData.PointsBreakdownItem] = orderedLabels.compactMap { label -> FantasyPlayerDetailsData.PointsBreakdownItem? in
            guard let points = totals[label], points != 0 else { return nil }
            return FantasyPlayerDetailsData.PointsBreakdownItem(
                title: label,
                points: points
            )
        }

        if detailedItems.isEmpty {
            return [
                FantasyPlayerDetailsData.PointsBreakdownItem(
                    title: "Total points",
                    points: targetTotal
                )
            ]
        }
        return detailedItems
    }

    private static func appearancePoints(for minutes: Int) -> Int {
        if minutes <= 0 { return 0 }
        return minutes > 60 ? 2 : 1
    }

    private static func goalPointsPerGoal(for positionType: FantasyPositionType?) -> Int {
        switch positionType {
        case .goalkeeper:
            return 10
        case .defender:
            return 6
        case .midfielder:
            return 5
        case .forward:
            return 4
        case .none:
            return 4
        }
    }

    private static func cleanSheetPointsValue(for positionType: FantasyPositionType?) -> Int {
        switch positionType {
        case .goalkeeper, .defender:
            return 4
        case .midfielder:
            return 1
        case .forward, .none:
            return 0
        }
    }

    private static func resolveOpponentTeamID(
        fixture: FantasyElementSummaryFixture,
        playerTeamID: Int
    ) -> Int? {
        if let opponentTeam = fixture.opponentTeam {
            return opponentTeam
        }
        if let isHome = fixture.isHome {
            if isHome {
                return fixture.teamA
            }
            return fixture.teamH
        }
        if let teamH = fixture.teamH, let teamA = fixture.teamA {
            return teamH == playerTeamID ? teamA : (teamA == playerTeamID ? teamH : nil)
        }
        return nil
    }
}

enum FantasySquadBuilder {
    static func build(
        gameweek: FantasyGameweek,
        picksResponse: FantasyPicksResponse,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        seasonFixtures: [FantasyFixture],
        bootstrap: FantasyBootstrapLookup,
        now: Date = Date()
    ) -> FantasySquadDisplayData {
        let livePointsByElementID = Dictionary(
            uniqueKeysWithValues: liveResponse.elements.map { ($0.id, $0.stats.totalPoints) }
        )
        let liveStatsByElementID = Dictionary(
            uniqueKeysWithValues: liveResponse.elements.map { ($0.id, $0.stats) }
        )

        let elementByID = Dictionary(
            uniqueKeysWithValues: bootstrap.elements.map { ($0.id, $0) }
        )

        let teamNameByID = Dictionary(
            uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0.name) }
        )
        let teamShortNameByID = Dictionary(
            uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0.shortName) }
        )

        let activeTeamIDs = Set(
            fixtures.flatMap { fixture -> [Int] in
                let hasStarted = fixture.started == true
                let isFinished = fixture.finished == true || fixture.finishedProvisional == true
                guard hasStarted, !isFinished else { return [] }
                return [fixture.teamH, fixture.teamA]
            }
        )
        let upcomingTeamIDs = Set(
            fixtures.flatMap { fixture -> [Int] in
                let hasStarted = fixture.started == true
                let isFinished = fixture.finished == true || fixture.finishedProvisional == true
                guard !hasStarted, !isFinished else { return [] }
                return [fixture.teamH, fixture.teamA]
            }
        )
        let teamsWithAnyFixture = Set(
            fixtures.flatMap { fixture -> [Int] in
                [fixture.teamH, fixture.teamA]
            }
        )
        let hasActiveFixtures = !activeTeamIDs.isEmpty
        let hasStartedFixturesInGameweek = fixtures.contains { fixture in
            fixture.started == true ||
            fixture.finished == true ||
            fixture.finishedProvisional == true
        }
        let hasFixturesPlayedToday = {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
                return false
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            for fixture in fixtures {
                guard fixture.started == true else { continue }
                guard let kickoffRaw = fixture.kickoffTime?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !kickoffRaw.isEmpty else {
                    continue
                }
                let kickoffDate = formatter.date(from: kickoffRaw) ?? fallbackFormatter.date(from: kickoffRaw)
                guard let kickoffDate else { continue }
                if kickoffDate >= startOfToday && kickoffDate < startOfTomorrow {
                    return true
                }
            }
            return false
        }()

        let futureCandidateEvents = bootstrap.events
            .map(\.id)
            .filter { $0 > (gameweek.id + 1) }
            .sorted()
            .prefix(4)
        let teamFixtureEvents: [Int: Set<Int>] = {
            var map: [Int: Set<Int>] = [:]
            for fixture in seasonFixtures {
                guard let event = fixture.event else { continue }
                map[fixture.teamH, default: []].insert(event)
                map[fixture.teamA, default: []].insert(event)
            }
            return map
        }()

        func teamDisplayCode(teamID: Int) -> String {
            let shortName = (teamShortNameByID[teamID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortName.isEmpty {
                return shortName.uppercased()
            }

            let fallbackName = (teamNameByID[teamID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fallbackName.isEmpty {
                return "TBD"
            }

            let lettersOnly = fallbackName
                .uppercased()
                .filter { $0.isLetter }
            if lettersOnly.count >= 3 {
                return String(lettersOnly.prefix(3))
            }
            return lettersOnly.isEmpty ? "TBD" : lettersOnly
        }

        let mergedSeasonFixtures: [FantasyFixture] = {
            var fixturesByID = Dictionary(
                uniqueKeysWithValues: seasonFixtures.map { ($0.id, $0) }
            )
            for fixture in fixtures {
                fixturesByID[fixture.id] = fixture
            }
            return Array(fixturesByID.values)
        }()

        var upcomingOpponentByTeamID: [Int: String] = [:]
        mergedSeasonFixtures
            .sorted { lhs, rhs in
                let lhsEvent = lhs.event ?? Int.max
                let rhsEvent = rhs.event ?? Int.max
                if lhsEvent != rhsEvent {
                    return lhsEvent < rhsEvent
                }

                let lhsKickoff = lhs.kickoffTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rhsKickoff = rhs.kickoffTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if lhsKickoff != rhsKickoff {
                    if lhsKickoff.isEmpty { return false }
                    if rhsKickoff.isEmpty { return true }
                    return lhsKickoff < rhsKickoff
                }

                return lhs.id < rhs.id
            }
            .forEach { fixture in
                let hasStarted = fixture.started == true
                let isFinished = fixture.finished == true || fixture.finishedProvisional == true
                guard !hasStarted, !isFinished else { return }

                if upcomingOpponentByTeamID[fixture.teamH] == nil {
                    upcomingOpponentByTeamID[fixture.teamH] = "\(teamDisplayCode(teamID: fixture.teamA)) (H)"
                }
                if upcomingOpponentByTeamID[fixture.teamA] == nil {
                    upcomingOpponentByTeamID[fixture.teamA] = "\(teamDisplayCode(teamID: fixture.teamH)) (A)"
                }
            }

        let fallbackGameweekTitle = "Gameweek \(picksResponse.entryHistory.event)"
        let resolvedGameweekTitle = {
            let trimmed = gameweek.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return fallbackGameweekTitle
            }
            if trimmed.localizedCaseInsensitiveContains("gameweek") {
                return trimmed
            }
            return "Gameweek \(gameweek.id)"
        }()
        let resolvedDeadline = resolveDisplayedDeadline(
            currentGameweek: gameweek,
            events: bootstrap.events,
            now: now
        )

        let players = picksResponse.picks.compactMap { pick -> FantasyDisplayPlayer? in
            let element = elementByID[pick.element]
            let teamName = teamNameByID[element?.team ?? -1] ?? "Unknown Team"
            let displayName = {
                let fromWebName = element?.webName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !fromWebName.isEmpty { return fromWebName }

                let first = element?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let second = element?.secondName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combined = [first, second].filter { !$0.isEmpty }.joined(separator: " ")
                if !combined.isEmpty { return combined }

                return "Player #\(pick.element)"
            }()

            let resolvedPositionTypeRaw = pick.elementType ?? element?.elementType ?? 0
            let positionType = FantasyPositionType(rawValue: resolvedPositionTypeRaw) ?? .midfielder

            let rawPoints = livePointsByElementID[pick.element] ?? 0
            let appliedPoints = rawPoints * pick.multiplier
            let displayPoints = pick.position <= 11 ? appliedPoints : rawPoints
            let liveStats = liveStatsByElementID[pick.element]
            let minutesPlayed = liveStats?.minutes ?? 0
            let goalsScored = liveStats?.goalsScored ?? 0
            let assists = liveStats?.assists ?? 0
            let yellowCards = liveStats?.yellowCards ?? 0
            let redCards = liveStats?.redCards ?? 0
            let isPlayingNow = {
                guard let teamID = element?.team else { return false }
                return activeTeamIDs.contains(teamID)
            }()
            let availabilityStatus = (element?.status ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isUnavailable = {
                availabilityStatus == "i" || availabilityStatus == "d" || availabilityStatus == "s" || availabilityStatus == "u"
            }()
            let chanceOfPlaying = element?.chanceOfPlayingNextRound ?? element?.chanceOfPlayingThisRound
            let isDefinitelyUnavailable = {
                if availabilityStatus == "i" || availabilityStatus == "s" || availabilityStatus == "u" {
                    return true
                }
                if availabilityStatus == "d", chanceOfPlaying == 0 {
                    return true
                }
                return false
            }()
            let hasAnyFixtureThisGameweek = {
                guard let teamID = element?.team else { return false }
                return teamsWithAnyFixture.contains(teamID)
            }()
            let hasUpcomingFixtureThisGameweek = {
                guard let teamID = element?.team else { return false }
                return upcomingTeamIDs.contains(teamID)
            }()
            let hasActiveFixtureThisGameweek = {
                guard let teamID = element?.team else { return false }
                return activeTeamIDs.contains(teamID)
            }()
            let futureAvailabilityIssueGameweek: Int? = {
                guard let teamID = element?.team else { return nil }
                let teamEvents = teamFixtureEvents[teamID] ?? []
                return futureCandidateEvents.first(where: { !teamEvents.contains($0) })
            }()
            let upcomingOpponentDisplay: String? = {
                guard let teamID = element?.team else { return nil }
                return upcomingOpponentByTeamID[teamID]
            }()

            return FantasyDisplayPlayer(
                elementID: pick.element,
                pickPosition: pick.position,
                positionType: positionType,
                displayName: displayName,
                fullName: {
                    let first = element?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let second = element?.secondName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let combined = [first, second].filter { !$0.isEmpty }.joined(separator: " ")
                    if !combined.isEmpty { return combined }
                    return displayName
                }(),
                teamName: teamName,
                nowCostMillions: Double(element?.nowCost ?? 0) / 10.0,
                rawPoints: rawPoints,
                appliedPoints: appliedPoints,
                displayPoints: displayPoints,
                multiplier: pick.multiplier,
                isCaptain: pick.isCaptain,
                isViceCaptain: pick.isViceCaptain,
                isPlayingNow: isPlayingNow,
                isUnavailable: isUnavailable,
                isDefinitelyUnavailable: isDefinitelyUnavailable,
                hasAnyFixtureThisGameweek: hasAnyFixtureThisGameweek,
                hasUpcomingFixtureThisGameweek: hasUpcomingFixtureThisGameweek,
                hasActiveFixtureThisGameweek: hasActiveFixtureThisGameweek,
                hasFutureAvailabilityIssue: futureAvailabilityIssueGameweek != nil,
                futureAvailabilityIssueGameweek: futureAvailabilityIssueGameweek,
                minutesPlayed: minutesPlayed,
                upcomingOpponentDisplay: upcomingOpponentDisplay,
                goalsScored: goalsScored,
                assists: assists,
                yellowCards: yellowCards,
                redCards: redCards
            )
        }
        .sorted { $0.pickPosition < $1.pickPosition }

        let starters = players.filter { $0.isStarter }
        let bench = players
            .filter { !$0.isStarter }
            .sorted { $0.pickPosition < $1.pickPosition }

        let isEstimatedScore = hasActiveFixtures || hasFixturesPlayedToday
        let computedAppliedPointsTotal = starters.reduce(0) { $0 + $1.appliedPoints }
        var estimatedCurrentScore = picksResponse.entryHistory.points
        var scoreCalculationRulesApplied: [String] = []

        if isEstimatedScore {
            var runningEstimatedTotal = computedAppliedPointsTotal

            if let unavailableStartingGoalkeeper = starters.first(where: { player in
                player.positionType == .goalkeeper && player.shouldAutoSubAsNonParticipant
            }),
               let benchGoalkeeper = bench.first(where: { $0.positionType == .goalkeeper && $0.isEligibleAutoSubReplacement }) {
                runningEstimatedTotal -= unavailableStartingGoalkeeper.appliedPoints
                runningEstimatedTotal += benchGoalkeeper.rawPoints
                scoreCalculationRulesApplied.append(
                    "Goalkeeper auto-sub applied: \(unavailableStartingGoalkeeper.displayName) did not play, so \(benchGoalkeeper.displayName) contributed \(benchGoalkeeper.rawPoints) pts."
                )
            }

            let minimumFormation: [FantasyPositionType: Int] = [
                .defender: 3,
                .midfielder: 2,
                .forward: 1
            ]
            var activeOutfieldCounts: [FantasyPositionType: Int] = [.defender: 0, .midfielder: 0, .forward: 0]
            for player in starters where player.positionType != .goalkeeper {
                activeOutfieldCounts[player.positionType, default: 0] += 1
            }

            var nonPlayingOutfieldStarters = starters
                .filter { $0.positionType != .goalkeeper && $0.shouldAutoSubAsNonParticipant }
                .sorted { $0.pickPosition < $1.pickPosition }
            let playedOutfieldBench = bench
                .filter { $0.positionType != .goalkeeper && $0.isEligibleAutoSubReplacement }
                .sorted { $0.pickPosition < $1.pickPosition }
            var outfieldReplacementNotes: [String] = []

            for benchPlayer in playedOutfieldBench {
                guard !nonPlayingOutfieldStarters.isEmpty else { break }

                let replacementIndex = nonPlayingOutfieldStarters.firstIndex { starter in
                    var simulatedCounts = activeOutfieldCounts
                    simulatedCounts[starter.positionType, default: 0] -= 1
                    simulatedCounts[benchPlayer.positionType, default: 0] += 1
                    let defendersOK = (simulatedCounts[.defender] ?? 0) >= (minimumFormation[.defender] ?? 0)
                    let midfieldersOK = (simulatedCounts[.midfielder] ?? 0) >= (minimumFormation[.midfielder] ?? 0)
                    let forwardsOK = (simulatedCounts[.forward] ?? 0) >= (minimumFormation[.forward] ?? 0)
                    return defendersOK && midfieldersOK && forwardsOK
                }

                guard let replacementIndex else { continue }
                let replacedStarter = nonPlayingOutfieldStarters.remove(at: replacementIndex)

                activeOutfieldCounts[replacedStarter.positionType, default: 0] -= 1
                activeOutfieldCounts[benchPlayer.positionType, default: 0] += 1

                runningEstimatedTotal -= replacedStarter.appliedPoints
                runningEstimatedTotal += benchPlayer.rawPoints
                outfieldReplacementNotes.append(
                    "\(benchPlayer.displayName) (\(benchPlayer.rawPoints)) for \(replacedStarter.displayName)"
                )
            }

            if !outfieldReplacementNotes.isEmpty {
                scoreCalculationRulesApplied.append(
                    "Outfield auto-subs applied: \(outfieldReplacementNotes.joined(separator: ", "))."
                )
            }

            if let captain = starters.first(where: { $0.isCaptain && $0.shouldAutoSubAsNonParticipant }),
               let viceCaptain = players.first(where: { $0.isViceCaptain && $0.isEligibleAutoSubReplacement }) {
                runningEstimatedTotal += viceCaptain.rawPoints
                scoreCalculationRulesApplied.append(
                    "Vice-captain boost applied: \(captain.displayName) did not play, so \(viceCaptain.displayName) was doubled (+\(viceCaptain.rawPoints) pts)."
                )
            }

            if isEstimatedScore,
               let transferCost = picksResponse.entryHistory.eventTransfersCost,
               transferCost > 0 {
                runningEstimatedTotal -= transferCost
                scoreCalculationRulesApplied.append("\(transferCost) points deducted for transfers.")
            }

            estimatedCurrentScore = runningEstimatedTotal
        }

        var goalkeepers: [FantasyDisplayPlayer] = []
        var defenders: [FantasyDisplayPlayer] = []
        var midfielders: [FantasyDisplayPlayer] = []
        var forwards: [FantasyDisplayPlayer] = []

        for starter in starters {
            switch starter.positionType {
            case .goalkeeper:
                goalkeepers.append(starter)
            case .defender:
                defenders.append(starter)
            case .midfielder:
                midfielders.append(starter)
            case .forward:
                forwards.append(starter)
            }
        }

        goalkeepers.sort { $0.pickPosition < $1.pickPosition }
        defenders.sort { $0.pickPosition < $1.pickPosition }
        midfielders.sort { $0.pickPosition < $1.pickPosition }
        forwards.sort { $0.pickPosition < $1.pickPosition }

        return FantasySquadDisplayData(
            gameweekID: gameweek.id,
            gameweekTitle: resolvedGameweekTitle,
            deadlineGameweekID: resolvedDeadline?.id,
            deadlineTime: resolvedDeadline?.deadlineTime,
            totalPoints: picksResponse.entryHistory.points,
            hasActiveFixtures: hasActiveFixtures,
            hasStartedFixturesInGameweek: hasStartedFixturesInGameweek,
            hasFixturesPlayedToday: hasFixturesPlayedToday,
            isEstimatedScore: isEstimatedScore,
            estimatedCurrentScore: estimatedCurrentScore,
            scoreCalculationRulesApplied: scoreCalculationRulesApplied,
            rank: picksResponse.entryHistory.rank,
            overallRank: picksResponse.entryHistory.overallRank,
            transfersCost: picksResponse.entryHistory.eventTransfersCost,
            pointsOnBench: picksResponse.entryHistory.pointsOnBench,
            goalkeepers: goalkeepers,
            defenders: defenders,
            midfielders: midfielders,
            forwards: forwards,
            bench: bench
        )
    }

    private static func resolveDisplayedDeadline(
        currentGameweek: FantasyGameweek,
        events: [FantasyGameweek],
        now: Date
    ) -> FantasyGameweek? {
        if let currentDeadline = parseDeadline(currentGameweek.deadlineTime),
           currentDeadline > now {
            return currentGameweek
        }

        let sortedEvents = events.sorted { lhs, rhs in
            if lhs.id != rhs.id {
                return lhs.id < rhs.id
            }
            return (lhs.deadlineTime ?? "") < (rhs.deadlineTime ?? "")
        }

        for event in sortedEvents {
            guard let deadline = parseDeadline(event.deadlineTime), deadline > now else {
                continue
            }
            return event
        }

        return currentGameweek
    }

    private static func parseDeadline(_ rawValue: String?) -> Date? {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = deadlineFormatterWithFractionalSeconds.date(from: trimmed) {
            return date
        }
        return deadlineFormatter.date(from: trimmed)
    }

    private static let deadlineFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let deadlineFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
