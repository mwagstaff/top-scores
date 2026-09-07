import ActivityKit
import Foundation
import Testing
@testable import Top_Scores

struct LiveActivityLifecycleTests {
    @Test func legacyActivityAttributesRemainDecodable() throws {
        let data = Data(#"{"appScope":"top-scores"}"#.utf8)
        let attributes = try JSONDecoder().decode(TopScoresLiveActivityAttributes.self, from: data)
        #expect(attributes.startedAtEpochSeconds == nil)
    }

    @Test func renewalCreationTimeSurvivesDecoding() throws {
        let data = Data(#"{"appScope":"top-scores","startedAtEpochSeconds":1788618600}"#.utf8)
        let attributes = try JSONDecoder().decode(TopScoresLiveActivityAttributes.self, from: data)
        #expect(attributes.startedAtEpochSeconds == 1788618600)
    }

    @Test func expiredLockScreenActivityDoesNotBlockReplacement() {
        // ActivityKit retains an ended activity on the Lock Screen after its
        // eight-hour lifetime. It must not count as an update/retry target.
        let states: [ActivityState] = [.ended, .dismissed]
        #expect(states.filter { LiveActivitySyncService.canUpdateActivity(in: $0) }.isEmpty)
    }

    @Test func staleActivityRemainsEligibleForRecovery() {
        // A missed push makes content stale without ending the activity.
        let states: [ActivityState] = [.ended, .stale, .active, .dismissed]
        let updatable = states.filter { LiveActivitySyncService.canUpdateActivity(in: $0) }
        #expect(updatable == [.stale, .active])
    }
}
