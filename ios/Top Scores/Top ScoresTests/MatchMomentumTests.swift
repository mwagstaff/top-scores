import Foundation
import Testing
@testable import Top_Scores

struct MatchMomentumTests {
    private func decode(_ body: String) throws -> MatchMomentum {
        try JSONDecoder().decode(MatchMomentum.self, from: Data(body.utf8))
    }

    @Test func fractionalMinutesAndExtraTimeDecodeWithoutLosingPrecision() throws {
        let momentum = try decode("""
        {"status":"available","end_minute":120.5,"scale":100,
         "segments":[{"id":"1","side":"home","points":[{"minute":120,"value":20},{"minute":120.5,"value":0}]}],
         "annotations":[{"id":"goal","minute":120.5,"time":"120+3′","side":"home","kind":"goal","label":"Goal · Player"}],
         "ticks":[{"minute":120.5,"label":"FT"}],"updated_at":null,"refresh_after_seconds":null}
        """)
        #expect(momentum.isRenderable)
        #expect(momentum.segments[0].points[1].minute == 120.5)
        #expect(momentum.annotations[0].time == "120+3′")
        #expect(momentum.refreshAfterSeconds == nil)
    }

    @Test func lateAvailabilityAndMissingCoverageAreDistinct() throws {
        let pending = try decode("""
        {"status":"pending","end_minute":90.5,"scale":100,"segments":[],"annotations":[],"ticks":[],"refresh_after_seconds":60}
        """)
        #expect(!pending.isRenderable)
        #expect(pending.refreshAfterSeconds == 60)
        let legacy = try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("{\"id\":\"42\"}".utf8))
        #expect(legacy.momentum == nil)
    }

    @Test func overlappingAnnotationsHaveSeparateTargets() throws {
        let momentum = try decode("""
        {"status":"available","end_minute":90.5,"scale":100,"segments":[],"ticks":[],
         "annotations":[
          {"id":"1","minute":90.5,"time":"90+3′","side":"home","kind":"goal","label":"Goal"},
          {"id":"2","minute":90.5,"time":"90+5′","side":"home","kind":"goal","label":"Goal"},
          {"id":"3","minute":90.5,"time":"90+6′","side":"away","kind":"red_card","label":"Red card"}]}
        """)
        let home = momentum.markers(side: "home", width: 240)
        #expect(home.map(\.lane) == [0, 1])
        #expect(home.map(\.x) == [240, 240])
        #expect(momentum.markers(side: "away", width: 240).first?.lane == 0)
    }
}
