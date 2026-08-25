import Foundation
import Testing
@testable import Top_Scores

struct FantasyPreviousTeamTests {
    @Test func pickerTitleOmitsUnavailableScore() {
        #expect(fantasyPreviousTeamPickerTitle(finalScore: nil) == "Previous team")
    }

    @Test func pickerTitleIncludesFinalScore() {
        #expect(fantasyPreviousTeamPickerTitle(finalScore: 51) == "Previous team (51)")
    }

    @Test func entryHistoryDecodesHistoricalTeamValue() throws {
        let data = Data(
            #"{"event":4,"points":51,"rank":123,"overall_rank":456,"event_transfers_cost":0,"points_on_bench":8,"value":1013}"#.utf8
        )

        let history = try JSONDecoder().decode(FantasyEntryHistory.self, from: data)

        #expect(history.teamValue == 1013)
    }
}
