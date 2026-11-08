import Foundation
import Testing
@testable import Top_Scores

@MainActor
struct FantasyLeagueOrderTests {
    @Test func nativeListInsertionOffsetsMoveDownUpAndToEnd() {
        var order = FantasyLeagueOrder(json: "{}")
        order.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, availableIDs: [1, 2, 3], managerID: 10)
        #expect(order.orderedIDs([1, 2, 3], managerID: 10) == [2, 3, 1])
        order.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, availableIDs: [1, 2, 3], managerID: 10)
        #expect(FantasyLeagueOrder(json: order.json).orderedIDs([1, 2, 3], managerID: 10) == [1, 2, 3])
        order.move(fromOffsets: IndexSet(integer: 0), toOffset: 1, availableIDs: [1, 2, 3], managerID: 10)
        #expect(order.orderedIDs([1, 2, 3], managerID: 10) == [1, 2, 3])
    }

    @Test func movesBothDirectionsAndSurvivesReloadAndRefresh() {
        var order = FantasyLeagueOrder(json: "{}")
        let moveResult1 = order.move(1, to: 3, availableIDs: [1, 2, 3], managerID: 10)
        #expect(moveResult1)
        let reloaded = FantasyLeagueOrder(json: order.json)
        #expect(reloaded.orderedIDs([3, 1, 2], managerID: 10) == [2, 3, 1])
        let moveResult2 = order.move(1, to: 2, availableIDs: [1, 2, 3], managerID: 10)
        #expect(moveResult2)
        #expect(order.orderedIDs([3, 2, 1], managerID: 10) == [1, 2, 3])
    }

    @Test func appendsNewLeaguesRemovesMissingAndSeparatesManagers() {
        var order = FantasyLeagueOrder(json: "{}")
        let moveResult3 = order.move(3, to: 1, availableIDs: [1, 2, 3], managerID: 10)
        #expect(moveResult3)
        #expect(order.orderedIDs([1, 3, 4], managerID: 10) == [3, 1, 4])
        #expect(order.orderedIDs([1, 2, 3], managerID: 20) == [1, 2, 3])
        let moveResult4 = order.move(2, to: 1, availableIDs: [1, 2], managerID: 20)
        #expect(moveResult4)
        #expect(FantasyLeagueOrder(json: order.json).orderedIDs([1, 2, 3], managerID: 10) == [3, 1, 2])
    }

    @Test func rejectsInvalidMovesAndRecoversMalformedPreferences() {
        var order = FantasyLeagueOrder(json: "invalid")
        #expect(order.orderedIDs([3, 1, 2], managerID: 10) == [3, 1, 2])
        let moveResult5 = !order.move(9, to: 1, availableIDs: [1, 2], managerID: 10)
        #expect(moveResult5)
        let moveResult6 = !order.move(1, to: 9, availableIDs: [1, 2], managerID: 10)
        #expect(moveResult6)
        let moveResult7 = !order.move(1, to: 1, availableIDs: [1, 2], managerID: 10)
        #expect(moveResult7)
        let moveResult8 = !order.move(1, to: 2, availableIDs: [1, 2], managerID: 0)
        #expect(moveResult8)
        #expect(order.orderedIDs([1, 2], managerID: 10) == [1, 2])
    }
}
