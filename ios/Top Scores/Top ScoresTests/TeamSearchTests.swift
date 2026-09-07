import Testing
@testable import Top_Scores

struct TeamSearchTests {
    @Test func destinationUsesNumericSourceTeamIDAndPrimaryCompetition() {
        let team = TeamCatalogEntry(
            id: "sevilla",
            name: "Sevilla",
            aliases: ["Sevilla FC"],
            competitionIDs: ["564", "13"],
            competitionNames: ["La Liga", "Copa del Rey"],
            sourceTeamIDs: ["legacy-sevilla", "282"]
        )

        let context = TeamSearchDestinationResolver.context(for: team)

        #expect(context.teamID == "282")
        #expect(context.teamName == "Sevilla")
        #expect(context.displayName == "Sevilla")
        #expect(context.alternateNames == ["Sevilla FC"])
        #expect(context.originatingLeagueID == "564")
        #expect(context.originatingLeagueName == "La Liga")
        #expect(context.originatingMatch == nil)
    }

    @Test func destinationLeavesTeamIDEmptyWhenCatalogHasNoNumericSourceID() {
        let team = TeamCatalogEntry(
            id: "world-cup-placeholder",
            name: "Winner Match 101",
            aliases: [],
            competitionIDs: ["27"],
            competitionNames: ["FIFA World Cup"],
            sourceTeamIDs: ["W101"]
        )

        let context = TeamSearchDestinationResolver.context(for: team)

        #expect(context.teamID == nil)
    }
}
