import Foundation
import Testing
@testable import Top_Scores

struct PlayerSquadTests {
    @Test func playerDetailsDecodesBSDProfileFields() throws {
        let json = Data(#"""
        {
          "id":"2173",
          "name":"Pascal Groß",
          "team":"Brighton & Hove Albion",
          "born":"1991-06-15",
          "position":"MID",
          "jersey_number":13,
          "date_of_birth":"1991-06-15",
          "preferred_foot":"R",
          "nationality":"Germany",
          "market_value_eur":2300000,
          "market_value_gbp":1972500,
          "availability":"available",
          "fpl_total_points":155,
          "fpl_selected_by_count":1260000,
          "fpl_selected_by_percent":10.5,
          "fpl_profile_url":"https://example.com/pascal.png",
          "attributes":{"attacking":14,"technical":16,"tactical":15,"defending":9,"creativity":16,"position":"Midfielder"},
          "strengths":["Passing"],
          "weaknesses":[]
        }
        """#.utf8)

        let player = try JSONDecoder().decode(PlayerDetails.self, from: json)
        #expect(player.dateOfBirth == "1991-06-15")
        #expect(player.jerseyNumber == 13)
        #expect(player.nationality == "Germany")
        #expect(player.marketValueGBP == 1_972_500)
        #expect(player.attributes?.technical == 16)
        #expect(player.strengths == ["Passing"])
        #expect(player.availabilityDisplayName == "Available")
        #expect(player.fplTotalPoints == 155)
        #expect(player.fplSelectedByCount == 1_260_000)
        #expect(player.fplSelectedByPercent == 10.5)
        #expect(player.fplProfileURL == "https://example.com/pascal.png")
    }

    @Test func ageUsesDateOfBirthRatherThanReturningUnknown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))!

        #expect(PlayerDatePresentation.age(from: "1991-06-15", now: now, calendar: calendar) == 35)
        #expect(PlayerDatePresentation.displayDate("1991-06-15") == "15 Jun 1991")
    }

    @Test func nationalityProducesCountryAndHomeNationFlags() {
        #expect(PlayerNationalityPresentation.flag(for: "Germany") == "🇩🇪")
        #expect(PlayerNationalityPresentation.flag(for: "England")?.isEmpty == false)
        #expect(PlayerNationalityPresentation.flag(for: nil) == nil)
    }

    @Test func squadDefaultsCanSortByValueNumberNameAndAvailability() {
        let available = PlayerDetails(
            id: "1",
            name: "Zed Alpha",
            jerseyNumber: 20,
            marketValueEUR: 20_000_000,
            availability: "available",
            fplTotalPoints: 120,
            fplSelectedByCount: 1_000_000,
            fplSelectedByPercent: 8.5
        )
        let injured = PlayerDetails(
            id: "2",
            name: "Alex Zulu",
            jerseyNumber: 2,
            marketValueEUR: 10_000_000,
            availability: "injured",
            fplTotalPoints: 180,
            fplSelectedByCount: 2_000_000,
            fplSelectedByPercent: 12.5
        )
        let players = [injured, available]

        #expect(TeamSquadSortOrder.value.sorted(players).map(\.id) == ["1", "2"])
        #expect(TeamSquadSortOrder.firstName.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.lastName.sorted(players).map(\.id) == ["1", "2"])
        #expect(TeamSquadSortOrder.squadNumber.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.availability.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.fplTotalPoints.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.fplSelectedByCount.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.fplSelectedByPercent.sorted(players).map(\.id) == ["2", "1"])
        #expect(TeamSquadSortOrder.availableCases(for: players).contains(.fplTotalPoints))
    }

    @Test func squadTeamIDUsesCatalogWhenNavigationContextHasNoNumericID() {
        let context = TeamDetailsContext(
            teamID: nil,
            teamName: "Brighton & Hove Albion",
            displayName: "Brighton",
            alternateNames: [],
            originatingLeagueID: "47",
            originatingLeagueName: "Premier League",
            originatingMatch: nil
        )
        let catalog = TeamCatalogResponse(
            teams: [TeamCatalogEntry(
                id: "brighton-hove-albion",
                name: "Brighton & Hove Albion",
                aliases: ["Brighton"],
                competitionIDs: ["47"],
                competitionNames: ["Premier League"],
                sourceTeamIDs: ["5"]
            )],
            count: 1,
            totalCount: 1,
            offset: 0,
            limit: 20,
            hasMore: false,
            updatedAt: nil,
            source: nil
        )

        #expect(TeamDetailsSquadTeamIDResolver.resolve(context: context, catalog: catalog) == "5")
    }

    @Test func fantasyAvailabilityWarningsCoverInjuryDoubtAndSuspension() {
        #expect(FantasyAvailabilityPresentation.hasIssue(status: "i"))
        #expect(FantasyAvailabilityPresentation.hasIssue(availability: "doubtful"))
        #expect(FantasyAvailabilityPresentation.hasIssue(availability: "suspended"))
        #expect(FantasyAvailabilityPresentation.hasIssue(chanceOfPlaying: 75))
        #expect(!FantasyAvailabilityPresentation.hasIssue(status: "a", availability: "available", chanceOfPlaying: 100))
    }
}
