import Foundation
import Testing
@testable import Top_Scores

struct FantasyTabBadgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func liveMatchShowsScore() {
        let match = makeMatch(status: "73", updatedAt: nil)

        #expect(fantasyTabMatchIsLiveOrRecentlyFinished(match, now: now))
    }

    @Test func recentlyFinishedMatchShowsScoreForLessThanThirtyMinutes() {
        let match = makeMatch(
            status: "FT",
            updatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-29 * 60))
        )

        #expect(fantasyTabMatchIsLiveOrRecentlyFinished(match, now: now))
    }

    @Test func finishedMatchStopsShowingScoreAtThirtyMinutes() {
        let match = makeMatch(
            status: "FT",
            updatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 60))
        )

        #expect(!fantasyTabMatchIsLiveOrRecentlyFinished(match, now: now))
    }

    @Test func upcomingMatchDoesNotShowScore() {
        let match = makeMatch(status: nil, updatedAt: nil)

        #expect(!fantasyTabMatchIsLiveOrRecentlyFinished(match, now: now))
    }

    private func makeMatch(status: String?, updatedAt: String?) -> Match {
        Match(
            date: "15-01-2027",
            time: "07:00",
            homeTeam: "Arsenal",
            awayTeam: "Chelsea",
            league: "Premier League",
            tvChannels: [],
            homeScore: status == nil ? nil : 1,
            awayScore: status == nil ? nil : 0,
            scoreStatus: status,
            updatedAt: updatedAt
        )
    }
}
