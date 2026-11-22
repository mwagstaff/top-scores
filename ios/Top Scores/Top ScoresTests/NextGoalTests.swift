import Foundation
import Testing
@testable import Top_Scores

struct NextGoalTests {
    func details(_ block: String) throws -> MatchDetailsPayload {
        try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("{\"id\":\"42\",\"next_goal\":\(block)}".utf8))
    }

    @Test func labelsAndTwoWayShares() throws {
        let three = try #require(details(#"{"status":"available","probabilities":{"home":0.35,"no_goal":0.40,"away":0.25}}"#).nextGoal)
        let shares = three.shares(home: "City", away: "Fulham")
        #expect(shares.map(\.label) == ["City", "No further goal", "Fulham"])
        #expect(shares.map(\.percent) == ["35%", "40%", "25%"])
        let two = try #require(details(#"{"status":"updating","minute":66,"probabilities":{"home":0.3,"no_goal":null,"away":0.2}}"#).nextGoal)
        #expect(two.shares(home: "City", away: "Fulham").map(\.percent) == ["60%", "40%"])
        #expect(two.note(updating: true) == "Last estimate · 66′")
    }

    @Test func unknownStateDoesNotBreakDetails() throws {
        #expect(try details(#"{"status":"unknown"}"#).nextGoal == nil)
    }
    @Test func settledCallDecodesWithoutForecast() throws {
        let goal = try #require(details(#"{"status":"settled","calls":[{"summary":"No further goal"}],"refresh_after_seconds":60}"#).nextGoal)
        #expect(goal.calls?.first?.summary == "No further goal")
        #expect(goal.refreshAfterSeconds == 60)
        #expect(goal.shares(home: "City", away: "Fulham").isEmpty)
    }
}
