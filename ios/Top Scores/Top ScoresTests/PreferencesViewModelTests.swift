import XCTest
@testable import Top_Scores

@MainActor
final class PreferencesViewModelTests: XCTestCase {
    private enum TestError: Error {
        case unavailable
    }

    func testCompetitionReloadDoesNotWaitForOrRequestChannels() async {
        let competition = CompetitionCatalogEntry(
            id: "premier-league",
            name: "Premier League",
            aliases: [],
            weight: 1,
            region: "England",
            logoURL: nil
        )
        let viewModel = PreferencesViewModel(
            competitionLoader: { _ in
                CompetitionCatalogResponse(
                    competitions: [competition],
                    updatedAt: nil,
                    source: "test"
                )
            },
            channelLoader: { _ in ["Should not load"] }
        )

        await viewModel.reload(
            baseURL: "https://preferences-competition-test.invalid/api/",
            loadCompetitions: true,
            loadChannels: false
        )

        XCTAssertEqual(viewModel.availableLeagues, ["Premier League"])
        XCTAssertTrue(viewModel.availableChannels.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testChannelFailureDoesNotDiscardLoadedCompetitions() async {
        let competition = CompetitionCatalogEntry(
            id: "champions-league",
            name: "Champions League",
            aliases: [],
            weight: 1,
            region: "Europe",
            logoURL: nil
        )
        let viewModel = PreferencesViewModel(
            competitionLoader: { _ in
                CompetitionCatalogResponse(
                    competitions: [competition],
                    updatedAt: nil,
                    source: "test"
                )
            },
            channelLoader: { _ in throw TestError.unavailable }
        )

        await viewModel.reload(
            baseURL: "https://preferences-partial-failure-test.invalid/api/"
        )

        XCTAssertEqual(viewModel.availableLeagues, ["Champions League"])
        XCTAssertTrue(viewModel.availableChannels.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "Unable to load channels from the API.")
    }

    func testNotificationCompetitionSelectionUsesStableIDAcrossCatalogAliases() {
        let eflCup = CompetitionCatalogEntry(
            id: "english-league-cup",
            name: "EFL Cup",
            aliases: ["Carabao Cup", "English League Cup"],
            weight: 1,
            region: "England",
            logoURL: nil
        )
        let optionIDs = ["competition:english-league-cup", "competition:premier-league"]

        XCTAssertTrue(
            NotificationCompetitionSelection.isSelected(
                leagueName: "EFL Cup",
                optionIDs: optionIDs,
                catalog: [eflCup]
            )
        )
        XCTAssertEqual(
            NotificationCompetitionSelection.canonicalLeagueNames(
                optionIDs: optionIDs,
                existingLeagueNames: ["English League Cup", "Spanish La Liga"],
                catalog: [eflCup]
            ),
            ["EFL Cup"]
        )
        XCTAssertFalse(
            NotificationCompetitionSelection.toggling(
                leagueName: "EFL Cup",
                optionIDs: optionIDs,
                catalog: [eflCup]
            ).contains("competition:english-league-cup")
        )

        let internationalFriendly = CompetitionCatalogEntry(
            id: "international-friendly",
            name: "International Friendly",
            aliases: ["International Friendlies"],
            weight: 1,
            region: "International",
            logoURL: nil
        )
        XCTAssertEqual(
            NotificationCompetitionSelection.canonicalOptionIDs(
                optionIDs: ["competition:international-friendlies", "team:arsenal"],
                existingLeagueNames: ["International Friendlies"],
                catalog: [internationalFriendly]
            ),
            ["competition:international-friendly", "team:arsenal"]
        )
        XCTAssertEqual(
            NotificationCompetitionSelection.canonicalOptionIDs(
                optionIDs: ["competition:no-longer-in-catalog", "team:arsenal"],
                existingLeagueNames: [],
                catalog: [internationalFriendly]
            ),
            ["team:arsenal"]
        )
    }
}
