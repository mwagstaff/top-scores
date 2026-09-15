import Testing
@testable import Top_Scores

struct TeamShortNamePresentationTests {
    @Test func prefersShortestReadableAliasOverAcronym() {
        #expect(
            TeamIdentityStore.preferredShortName(
                fullName: "Manchester United",
                candidates: ["Manchester United", "Man United", "MUN", "Man Utd", "Man U"]
            ) == "Man Utd"
        )
        #expect(
            TeamIdentityStore.preferredShortName(
                fullName: "Coventry City",
                candidates: ["Coventry City", "CCFC", "Coventry"]
            ) == "Coventry"
        )
    }

    @Test func rejectsMachineAbbreviations() {
        #expect(
            TeamIdentityStore.preferredShortName(
                fullName: "Paris Saint-Germain",
                candidates: ["Paris Saint-Germain", "Paris Saint Germain", "PSG"]
            ) == nil
        )
        #expect(TeamIdentityStore.displayShortName("BOU", for: "Bournemouth") == nil)
        #expect(TeamIdentityStore.displayShortName("BRE", for: "Brentford") == nil)
    }

    @Test func acceptsAcronymThatIsPartOfTheTeamName() {
        #expect(TeamIdentityStore.displayShortName("AEK", for: "AEK Athens") == "AEK")
    }

    @Test func normalizesUnitedSuffixForDisplay() {
        #expect(TeamIdentityStore.displayShortName("Man U", for: "Manchester United") == "Man Utd")
        #expect(TeamIdentityStore.displayShortName("Man Utd", for: "Manchester United") == "Man Utd")
        #expect(
            TeamIdentityStore.shared.preferredDisplayShortName(
                for: "Manchester United",
                providerShortName: "Man U"
            ) == "Man Utd"
        )
    }

    @Test func returnsNilWithoutAShorterAlias() {
        #expect(
            TeamIdentityStore.preferredShortName(
                fullName: "Arsenal",
                candidates: ["Arsenal"]
            ) == nil
        )
    }
}
