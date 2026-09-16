import Foundation
import Testing
@testable import Top_Scores

struct WatchFantasyLeagueFilterTests {
    @Test @MainActor func watchUsesThePhonesPlayerCreatedLeagueFilter() throws {
        let data = Data(#"{"id":123,"name":"Team","player_first_name":"Test","player_last_name":"Manager","leagues":{"classic":[{"id":1,"name":"Adobe Express","league_type":"s","active_phases":[]},{"id":2,"name":"Shirley Super League","league_type":"x","active_phases":[]},{"id":3,"name":"Overall","league_type":"s","active_phases":[]},{"id":4,"name":"Primark 4.0","league_type":"x","active_phases":[]}]}}"#.utf8)
        let profile = try JSONDecoder().decode(FantasyEntryProfile.self, from: data)
        let leagues = WatchFantasyTablesStore.playerLeagues(from: profile)
        #expect(leagues.map(\.name) == ["Primark 4.0", "Shirley Super League"])
        #expect(leagues.map(\.id) == [4, 2])
    }
}
