import Foundation
import Testing
@testable import Top_Scores

struct TableCompetitionOrderingTests {
    @Test func ordersTablesForAUKAudienceWithoutPromotingLiveInternationalCompetitions() {
        let weights: [String: Double] = [
            "premier-league": 100,
            "fa-cup": 65,
            "english-league-cup": 60,
            "championship": 40,
            "league-one": 14,
            "league-two": 12,
            "national-league": 11,
            "scottish-premiership": 30,
            "scottish-championship": 25,
            "scottish-league-one": 20,
            "scottish-league-two": 15,
            "la-liga": 50,
            "copa-del-rey": 49,
            "bundesliga": 48,
            "43": 47.5,
            "german-super-cup": 47,
            "serie-a": 45,
            "42": 44.5,
            "ligue-1": 44,
            "44": 43,
            "10": 40,
            "uefa-champions-league": 90,
            "uefa-europa-league": 80,
            "uefa-conference-league": 70,
            "uefa-super-cup": 68,
            "fifa-world-cup-2026": 85,
            "uefa-nations-league": 69,
            "international-friendly": 10
        ]
        let competitions = [
            table("fifa-world-cup-2026", "FIFA World Cup 2026", hasLiveRows: true),
            table("uefa-champions-league", "UEFA Champions League"),
            table("bundesliga", "Bundesliga"),
            table("scottish-league-two", "Scottish League Two"),
            table("league-two", "EFL League Two"),
            table("national-league", "National League"),
            table("international-friendly", "International Friendly"),
            table("premier-league", "Premier League"),
            table("copa-del-rey", "Copa del Rey"),
            table("uefa-nations-league", "UEFA Nations League"),
            table("scottish-premiership", "Scottish Premiership"),
            table("uefa-europa-league", "UEFA Europa League"),
            table("ligue-1", "Ligue 1"),
            table("english-league-cup", "EFL Cup"),
            table("scottish-championship", "Scottish Championship"),
            table("serie-a", "Serie A"),
            table("fa-cup", "FA Cup"),
            table("43", "DFB-Pokal"),
            table("german-super-cup", "DFL-Supercup"),
            table("league-one", "EFL League One"),
            table("42", "Coppa Italia"),
            table("uefa-conference-league", "UEFA Conference League"),
            table("championship", "Championship"),
            table("la-liga", "La Liga"),
            table("44", "Coupe de France"),
            table("10", "Dutch Eredivisie"),
            table("scottish-league-one", "Scottish League One"),
            table("uefa-super-cup", "UEFA Super Cup")
        ]

        let orderedIDs = TableCompetitionOrdering.sorted(competitions) {
            weights[$0.leagueID] ?? 0
        }
        .map(\.leagueID)

        #expect(orderedIDs == [
            "premier-league",
            "fa-cup",
            "english-league-cup",
            "championship",
            "league-one",
            "league-two",
            "national-league",
            "scottish-premiership",
            "scottish-championship",
            "scottish-league-one",
            "scottish-league-two",
            "la-liga",
            "bundesliga",
            "serie-a",
            "ligue-1",
            "10",
            "copa-del-rey",
            "43",
            "german-super-cup",
            "42",
            "44",
            "uefa-champions-league",
            "uefa-europa-league",
            "uefa-conference-league",
            "uefa-super-cup",
            "uefa-nations-league",
            "international-friendly",
            "fifa-world-cup-2026"
        ])
    }

    @Test func decodesServerTableEligibility() throws {
        let data = Data(#"{"name":"FA Cup","weight":65,"supports_table":false}"#.utf8)
        let entry = try JSONDecoder().decode(CompetitionCatalogEntry.self, from: data)
        #expect(entry.supportsTable == false)
    }

    @Test func keepsWorldCupAndRegionalQualifiersTogetherRegardlessOfWeights() {
        let competitions = [
            table("63", "World Cup Qualifying OFC"),
            table("60", "World Cup Qualification CAF"),
            table("62", "World Cup Qualifying CONCACAF"),
            table("59", "World Cup Qualifying CONMEBOL"),
            table("64", "UEFA Nations League"),
            table("27", "FIFA World Cup 2026"),
            table("58", "World Cup Qualifying UEFA")
        ]
        let ordered = TableCompetitionOrdering.sorted(competitions) { Double($0.leagueID) ?? 0 }
        #expect(ordered.map(\.leagueID) == ["64", "27", "58", "59", "62", "60", "63"])
        #expect(TableCompetitionOrdering.qualifierRegion(for: table("legacy", "World Cup Qualification CONCACAF")) == "CONCACAF")
        #expect(TableCompetitionOrdering.qualifierRegion(for: table("legacy", "World Cup Qualifying CAF")) == "CAF")
        #expect(TableCompetitionOrdering.qualifierRegion(for: table("legacy", "World Cup Qualifying AFC")) == "AFC")
    }

    private func table(
        _ leagueID: String,
        _ leagueName: String,
        hasLiveRows: Bool = false
    ) -> LeagueTable {
        LeagueTable(
            leagueID: leagueID,
            leagueName: leagueName,
            stageName: nil,
            sourceURL: nil,
            updatedAt: nil,
            rows: hasLiveRows ? [liveRow] : []
        )
    }

    private var liveRow: LeagueTableRow {
        LeagueTableRow(
            position: 1,
            team: "England",
            played: 1,
            won: 1,
            drawn: 0,
            lost: 0,
            goalsFor: 1,
            goalsAgainst: 0,
            goalDifference: 1,
            points: 3,
            form: ["W"],
            rankStatus: nil,
            live: true
        )
    }
}
