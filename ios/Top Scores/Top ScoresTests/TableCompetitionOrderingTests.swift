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
            "fifa-world-cup-2026",
            "uefa-nations-league",
            "international-friendly"
        ])
    }

    @Test func excludesKnockoutOnlyCompetitionsByBSDIDAndLegacyName() {
        let excluded = [
            ("39", "FA Cup"), ("40", "EFL Cup"), ("41", "Copa del Rey"),
            ("43", "DFB-Pokal"), ("42", "Coppa Italia"),
            ("44", "Coupe de France"), ("90", "UEFA Super Cup")
        ]
        for (id, name) in excluded {
            #expect(!TableCompetitionAvailability.supportsTable(competitionID: id, competitionName: ""))
            #expect(!TableCompetitionAvailability.supportsTable(competitionID: nil, competitionName: name))
        }
        #expect(!TableCompetitionAvailability.supportsTable(
            competitionID: "english-league-cup", competitionName: "Carabao Cup"
        ))
        #expect(!TableCompetitionAvailability.supportsTable(
            competitionID: "fa-cup", competitionName: "English FA Cup"
        ))

        let retained = [
            table("1", "Premier League"),
            table("7", "UEFA Champions League"),
            table("8", "UEFA Europa League"),
            table("83", "UEFA Conference League"),
            table("27", "FIFA World Cup 2026"),
            table("64", "UEFA Nations League"),
            table("91", "National League")
        ]
        let all = excluded.map { table($0.0, $0.1) } + retained
        #expect(TableCompetitionAvailability.eligibleLeagues(all) == retained)
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
