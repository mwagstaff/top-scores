import Testing
@testable import Top_Scores

struct PreferencesSyncOrderingTests {
    @Test func scoresOrderingSettingsAreUploaded() {
        for premierLeagueMatchesFirst in [true, false] {
            let snapshot = PreferencesSnapshot(
                selectedLeagues: [],
                selectedChannels: [],
                englishPremierLeagueTeamsOnly: false,
                apiBaseURL: PreferencesStore.defaultApiBaseURL,
                refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes,
                matchGroupSortOrder: .kickoffThenTeamScore,
                premierLeagueMatchesFirst: premierLeagueMatchesFirst
            )
            let payload = PreferencesSyncService.shared.preferencesPayload(snapshot)
            #expect(payload["matchGroupSortOrder"] as? String == "kickoffThenTeamScore")
            #expect(payload["premierLeagueMatchesFirst"] as? Bool == premierLeagueMatchesFirst)
        }
    }
}
