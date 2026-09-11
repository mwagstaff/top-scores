import Testing
import UIKit
@testable import Top_Scores

@MainActor
struct PredictionScoreDialTests {
    @Test func blankIsASeparateNotchBeforeZero() {
        let values = PredictionScoreDialValues(allowsEmpty: true)
        #expect(values.score(at: 0) == nil)
        #expect(values.score(at: 1) == 0)
        #expect(values.index(for: nil) == 0)
        #expect(values.index(for: 0) == 1)
        for score in 0...20 { #expect(values.score(at: values.index(for: score)) == score) }
    }

    @Test func singleMatchDialStartsAtZeroAndNeitherDialWraps() {
        let values = PredictionScoreDialValues(allowsEmpty: false)
        #expect(values.score(at: -1) == 0)
        #expect(values.score(at: 0) == 0)
        #expect(values.score(at: 21) == 20)
        let optional = PredictionScoreDialValues(allowsEmpty: true)
        #expect(optional.score(at: -1) == nil)
        #expect(optional.score(at: 22) == 20)
    }

    @Test func dragSnapsToNearestNotchAndClampsFlicks() {
        let values = PredictionScoreDialValues(allowsEmpty: true)
        #expect(values.nearestIndex(offset: 15, spacing: 32) == 0)
        #expect(values.nearestIndex(offset: 17, spacing: 32) == 1)
        #expect(values.nearestIndex(offset: 65, spacing: 32) == 2)
        #expect(values.nearestIndex(offset: -100, spacing: 32) == 0)
        #expect(values.nearestIndex(offset: 10_000, spacing: 32) == 21)
    }

    @Test func loadingSavedScoresDoesNotPublishAnEditAndVoiceOverCanClearToBlank() {
        let drum = makeDrum(score: nil)
        var changes: [Int?] = []
        drum.onSelection = { changes.append($0) }
        drum.configure(score: 2, team: "Arsenal", enabled: true, reduceMotion: true, fontSize: 23)
        #expect(changes.isEmpty)
        #expect(drum.accessibilityValue == "2")
        drum.accessibilityDecrement()
        drum.accessibilityDecrement()
        #expect(changes.count == 2)
        #expect(changes.last! == 0)
        drum.accessibilityDecrement()
        #expect(changes.count == 3)
        #expect(changes.last! == nil)
        #expect(drum.accessibilityValue == "Not entered")
        drum.accessibilityDecrement()
        #expect(changes.count == 3)
        drum.accessibilityIncrement()
        #expect(changes.last! == 0)
    }

    @Test func lockDuringDragStopsFurtherChangesIncludingAccessibility() {
        let drum = makeDrum(score: 2)
        var changes: [Int?] = []
        drum.onSelection = { changes.append($0) }
        drum.scrollViewWillBeginDragging(drum)
        drum.configure(score: 2, team: "Arsenal", enabled: false, reduceMotion: false, fontSize: 23)
        drum.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        drum.accessibilityIncrement()
        #expect(changes.isEmpty)
        #expect(!drum.isScrollEnabled)
        #expect(drum.accessibilityTraits.contains(.notEnabled))
        #expect(drum.accessibilityValue == "2")
    }

    @Test func physicalTurningPublishesOnlyOnNotchChanges() {
        let drum = makeDrum(score: nil)
        var changes: [Int?] = []
        drum.onSelection = { changes.append($0) }
        drum.scrollViewWillBeginDragging(drum)
        drum.setContentOffset(CGPoint(x: 0, y: 10), animated: false)
        #expect(changes.isEmpty)
        drum.setContentOffset(CGPoint(x: 0, y: 25), animated: false)
        #expect(changes.count == 1)
        #expect(changes.last! == 0)
        drum.setContentOffset(CGPoint(x: 0, y: 28), animated: false)
        #expect(changes.count == 1)
        drum.setContentOffset(CGPoint(x: 0, y: 49), animated: false)
        #expect(changes.count == 2)
        #expect(changes.last! == 1)
    }

    private func makeDrum(score: Int?) -> PredictionScoreDrumView {
        let drum = PredictionScoreDrumView(allowsEmpty: true)
        drum.frame = CGRect(x: 0, y: 0, width: 44, height: 68)
        drum.configure(score: score, team: "Arsenal", enabled: true, reduceMotion: true, fontSize: 23)
        drum.layoutIfNeeded()
        return drum
    }
}
