import Foundation

struct PredictionsEnvelope: Codable, Hashable, Sendable {
    let updatedAt: String?
    let count: Int?
    let leagues: [PredictionLeague]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case count
        case leagues
    }

    nonisolated init(updatedAt: String?, count: Int?, leagues: [PredictionLeague]) {
        self.updatedAt = updatedAt
        self.count = count
        self.leagues = leagues
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        leagues = try container.decodeIfPresent([PredictionLeague].self, forKey: .leagues) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encode(leagues, forKey: .leagues)
    }
}

struct PredictionLeague: Identifiable, Codable, Hashable, Sendable {
    let leagueID: String
    let leagueName: String
    let updatedAt: String?
    let fixtures: [PredictionFixture]

    nonisolated var id: String {
        leagueID
    }

    enum CodingKeys: String, CodingKey {
        case leagueID = "league_id"
        case leagueName = "league_name"
        case updatedAt = "updated_at"
        case fixtures
    }

    nonisolated init(leagueID: String, leagueName: String, updatedAt: String?, fixtures: [PredictionFixture]) {
        self.leagueID = leagueID
        self.leagueName = leagueName
        self.updatedAt = updatedAt
        self.fixtures = fixtures
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leagueID = try container.decode(String.self, forKey: .leagueID)
        leagueName = try container.decode(String.self, forKey: .leagueName)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        fixtures = try container.decodeIfPresent([PredictionFixture].self, forKey: .fixtures) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leagueID, forKey: .leagueID)
        try container.encode(leagueName, forKey: .leagueName)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(fixtures, forKey: .fixtures)
    }
}

struct PredictionFixture: Identifiable, Codable, Hashable, Sendable {
    let eventID: String
    let homeTeam: String
    let awayTeam: String
    let date: String?
    let time: String?
    let markets: PredictionMarkets?

    nonisolated var id: String {
        eventID
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case date
        case time
        case markets
    }

    nonisolated init(
        eventID: String,
        homeTeam: String,
        awayTeam: String,
        date: String?,
        time: String?,
        markets: PredictionMarkets?
    ) {
        self.eventID = eventID
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.date = date
        self.time = time
        self.markets = markets
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        markets = try container.decodeIfPresent(PredictionMarkets.self, forKey: .markets)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(homeTeam, forKey: .homeTeam)
        try container.encode(awayTeam, forKey: .awayTeam)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(time, forKey: .time)
        try container.encodeIfPresent(markets, forKey: .markets)
    }
}

struct PredictionMarkets: Codable, Hashable, Sendable {
    let matchResult: MatchResultMarket?
    let expectedGoals: ExpectedGoalsMarket?
    let overUnder: OverUnderMarket?
    let btts: BothTeamsToScoreMarket?
    let score: MostLikelyScoreMarket?

    enum CodingKeys: String, CodingKey {
        case matchResult = "match_result"
        case expectedGoals = "expected_goals"
        case overUnder = "over_under"
        case btts
        case score
    }

    nonisolated init(
        matchResult: MatchResultMarket?,
        expectedGoals: ExpectedGoalsMarket?,
        overUnder: OverUnderMarket?,
        btts: BothTeamsToScoreMarket?,
        score: MostLikelyScoreMarket?
    ) {
        self.matchResult = matchResult
        self.expectedGoals = expectedGoals
        self.overUnder = overUnder
        self.btts = btts
        self.score = score
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchResult = try container.decodeIfPresent(MatchResultMarket.self, forKey: .matchResult)
        expectedGoals = try container.decodeIfPresent(ExpectedGoalsMarket.self, forKey: .expectedGoals)
        overUnder = try container.decodeIfPresent(OverUnderMarket.self, forKey: .overUnder)
        btts = try container.decodeIfPresent(BothTeamsToScoreMarket.self, forKey: .btts)
        score = try container.decodeIfPresent(MostLikelyScoreMarket.self, forKey: .score)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(matchResult, forKey: .matchResult)
        try container.encodeIfPresent(expectedGoals, forKey: .expectedGoals)
        try container.encodeIfPresent(overUnder, forKey: .overUnder)
        try container.encodeIfPresent(btts, forKey: .btts)
        try container.encodeIfPresent(score, forKey: .score)
    }
}

struct MatchResultMarket: Codable, Hashable, Sendable {
    let probHome: Double
    let probDraw: Double
    let probAway: Double
    let predicted: String?

    enum CodingKeys: String, CodingKey {
        case probHome = "prob_home"
        case probDraw = "prob_draw"
        case probAway = "prob_away"
        case predicted
    }

    nonisolated init(probHome: Double, probDraw: Double, probAway: Double, predicted: String?) {
        self.probHome = probHome
        self.probDraw = probDraw
        self.probAway = probAway
        self.predicted = predicted
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        probHome = try container.decodeIfPresent(Double.self, forKey: .probHome) ?? 0
        probDraw = try container.decodeIfPresent(Double.self, forKey: .probDraw) ?? 0
        probAway = try container.decodeIfPresent(Double.self, forKey: .probAway) ?? 0
        predicted = try container.decodeIfPresent(String.self, forKey: .predicted)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(probHome, forKey: .probHome)
        try container.encode(probDraw, forKey: .probDraw)
        try container.encode(probAway, forKey: .probAway)
        try container.encodeIfPresent(predicted, forKey: .predicted)
    }
}

struct ExpectedGoalsMarket: Codable, Hashable, Sendable {
    let home: Double
    let away: Double

    enum CodingKeys: String, CodingKey {
        case home
        case away
    }

    nonisolated init(home: Double, away: Double) {
        self.home = home
        self.away = away
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = try container.decodeIfPresent(Double.self, forKey: .home) ?? 0
        away = try container.decodeIfPresent(Double.self, forKey: .away) ?? 0
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(home, forKey: .home)
        try container.encode(away, forKey: .away)
    }
}

struct OverUnderMarket: Codable, Hashable, Sendable {
    let probOver15: Double?
    let probOver25: Double?
    let probOver35: Double?

    enum CodingKeys: String, CodingKey {
        case probOver15 = "prob_over_15"
        case probOver25 = "prob_over_25"
        case probOver35 = "prob_over_35"
    }

    nonisolated init(probOver15: Double?, probOver25: Double?, probOver35: Double?) {
        self.probOver15 = probOver15
        self.probOver25 = probOver25
        self.probOver35 = probOver35
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        probOver15 = try container.decodeIfPresent(Double.self, forKey: .probOver15)
        probOver25 = try container.decodeIfPresent(Double.self, forKey: .probOver25)
        probOver35 = try container.decodeIfPresent(Double.self, forKey: .probOver35)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(probOver15, forKey: .probOver15)
        try container.encodeIfPresent(probOver25, forKey: .probOver25)
        try container.encodeIfPresent(probOver35, forKey: .probOver35)
    }
}

struct BothTeamsToScoreMarket: Codable, Hashable, Sendable {
    let probYes: Double?

    enum CodingKeys: String, CodingKey {
        case probYes = "prob_yes"
    }

    nonisolated init(probYes: Double?) {
        self.probYes = probYes
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        probYes = try container.decodeIfPresent(Double.self, forKey: .probYes)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(probYes, forKey: .probYes)
    }
}

struct MostLikelyScoreMarket: Codable, Hashable, Sendable {
    let mostLikely: String?

    enum CodingKeys: String, CodingKey {
        case mostLikely = "most_likely"
    }

    nonisolated init(mostLikely: String?) {
        self.mostLikely = mostLikely
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mostLikely = try container.decodeIfPresent(String.self, forKey: .mostLikely)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mostLikely, forKey: .mostLikely)
    }
}
