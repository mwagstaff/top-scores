import Testing
@testable import Top_Scores

#if DEBUG
struct MatchDetailLoadDiagnosticsTests {
    @Test func pendingMainPingProducesThrottledHeartbeatsWithoutMoreCallbacks() throws {
        var state = MatchDetailResponsivenessState(startedAt: 0)
        let initialSample = state.sample(at: 0)
        #expect(try #require(initialSample).enqueuePing)

        for tick in 1 ... 12 {
            let elapsed = UInt64(tick) * 100_000_000
            let result = state.sample(at: elapsed)
            let sample = try #require(result)
            #expect(!sample.enqueuePing)
            #expect(sample.backgroundTimerGap == nil)
            #expect(sample.mainStillBlocked == (tick % 5 == 0 ? elapsed : nil))
        }
    }

    @Test func delayedBackgroundTimerReportsGapAlongsidePendingMainPing() throws {
        var state = MatchDetailResponsivenessState(startedAt: 0)
        _ = state.sample(at: 0)
        _ = state.sample(at: 100_000_000)

        let resumedResult = state.sample(at: 4_760_000_000)
        let resumed = try #require(resumedResult)
        #expect(resumed.backgroundTimerGap == 4_660_000_000)
        #expect(resumed.mainStillBlocked == 4_760_000_000)
        #expect(!resumed.enqueuePing)

        let followingResult = state.sample(at: 4_860_000_000)
        let following = try #require(followingResult)
        #expect(following.backgroundTimerGap == nil)
        #expect(following.mainStillBlocked == nil)
        #expect(!following.enqueuePing)
    }

    @Test func acknowledgementAllowsOneNewPingAndResetsHeartbeatClock() throws {
        var state = MatchDetailResponsivenessState(startedAt: 0)
        _ = state.sample(at: 0)
        let acknowledged = state.acknowledgePing()
        let duplicateAcknowledgement = state.acknowledgePing()
        let nextPing = state.sample(at: 100_000_000)
        let beforeHeartbeat = state.sample(at: 500_000_000)
        let heartbeat = state.sample(at: 600_000_000)
        #expect(acknowledged)
        #expect(!duplicateAcknowledgement)
        #expect(try #require(nextPing).enqueuePing)
        #expect(try #require(beforeHeartbeat).mainStillBlocked == nil)
        #expect(try #require(heartbeat).mainStillBlocked == 500_000_000)
    }

    @Test func stoppingSuppressesTimerWorkAndOutstandingAcknowledgement() {
        var state = MatchDetailResponsivenessState(startedAt: 0)
        _ = state.sample(at: 0)
        let stopped = state.stop()
        let sampleAfterStop = state.sample(at: 600_000_000)
        let acknowledgedAfterStop = state.acknowledgePing()
        let stoppedAgain = state.stop()
        #expect(stopped)
        #expect(sampleAfterStop == nil)
        #expect(!acknowledgedAfterStop)
        #expect(!stoppedAgain)
    }

    @Test func samplingExpiresAfterFifteenSecondsButAllowsFinalAcknowledgement() throws {
        var state = MatchDetailResponsivenessState(startedAt: 0)
        _ = state.sample(at: 0)

        let lastResult = state.sample(at: 15_000_000_000)
        let last = try #require(lastResult)
        #expect(last.samplingComplete)
        #expect(!last.enqueuePing)
        #expect(last.backgroundTimerGap == 15_000_000_000)
        #expect(last.mainStillBlocked == 15_000_000_000)
        let sampleAfterExpiry = state.sample(at: 15_100_000_000)
        let acknowledged = state.acknowledgePing()
        let sampleAfterAcknowledgement = state.sample(at: 15_200_000_000)
        #expect(sampleAfterExpiry == nil)
        #expect(acknowledged)
        #expect(sampleAfterAcknowledgement == nil)
    }
}
#endif
