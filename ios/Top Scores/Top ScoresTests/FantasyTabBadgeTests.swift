import Foundation
import Testing
@testable import Top_Scores

struct FantasyTabBadgeTests {
    @Test func backgroundRefreshRunsWhileScoresTabIsSelected() {
        #expect(fantasyShouldRefreshInBackground(selectedTab: 0, managerEntryID: "123456"))
    }

    @Test func backgroundRefreshRequiresALinkedManager() {
        #expect(!fantasyShouldRefreshInBackground(selectedTab: 0, managerEntryID: "  \n "))
    }

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

    @Test func livePlayerShowsNotificationDot() {
        #expect(fantasyShouldShowLivePlayerIndicator(
            isSeasonActive: true,
            hasManagerEntryID: true,
            hasPlayerInPlay: true
        ))
    }

    @Test func notificationDotIsRemovedWhenNoPlayerIsLive() {
        #expect(!fantasyShouldShowLivePlayerIndicator(
            isSeasonActive: true,
            hasManagerEntryID: true,
            hasPlayerInPlay: false
        ))
    }

    @Test func livePlayerDoesNotShowNotificationDotWithoutConfiguredTeam() {
        #expect(!fantasyShouldShowLivePlayerIndicator(
            isSeasonActive: true,
            hasManagerEntryID: false,
            hasPlayerInPlay: true
        ))
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

struct LiveStandingsRowHighlightTests {
    @Test func inactiveRowIsTransparent() {
        #expect(liveStandingsRowHighlightOpacity(isActive: false) == 0)
    }

    @Test func liveRowUsesStaticHighlight() {
        #expect(liveStandingsRowHighlightOpacity(isActive: true) == 0.14)
    }
}
