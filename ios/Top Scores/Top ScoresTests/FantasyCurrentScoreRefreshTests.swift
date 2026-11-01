import Foundation
import Testing
@testable import Top_Scores

@MainActor
struct FantasyCurrentScoreRefreshTests {
    @Test func refreshAdvancesFixtureStatusAlongsideCaptainPoints() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CurrentScoreURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = FantasyViewModel(fantasyPublicClient: FantasyPublicAPIClient(session: session))
        let gameweek = FantasyGameweek(
            id: 9, name: "Gameweek 9", isCurrent: true, isNext: false,
            finished: false, dataChecked: false, deadlineTime: nil
        )
        let picks = try JSONDecoder().decode(FantasyPicksResponse.self, from: Data(#"{"picks":[{"element":411,"position":11,"multiplier":2,"is_captain":true,"is_vice_captain":false,"element_type":4}],"entry_history":{"event":9,"points":0}}"#.utf8))
        let bootstrap = try JSONDecoder().decode(FantasyBootstrapLookup.self, from: Data(#"{"elements":[{"id":411,"web_name":"Haaland","first_name":"Erling","second_name":"Haaland","team":15,"element_type":4}],"teams":[{"id":15,"name":"Man City","short_name":"MCI"},{"id":5,"name":"Brighton","short_name":"BHA"}],"element_types":[],"events":[]}"#.utf8))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T22:00:00Z"))
        let staleFixture = FantasyFixture(
            id: 88, event: 9, teamH: 15, teamA: 5,
            kickoffTime: "2026-10-31T15:00:00Z", started: false,
            finished: false, finishedProvisional: false
        )

        let refreshed = try await model.fetchCurrentScoreSnapshot(gameweek: gameweek, picksResponse: picks)
        let staleSquad = FantasySquadBuilder.build(
            gameweek: gameweek, picksResponse: picks, liveResponse: refreshed.liveResponse,
            fixtures: [staleFixture], seasonFixtures: [staleFixture], bootstrap: bootstrap, now: now
        )
        // Reproduce the old state: four captain points existed but the card hid them.
        #expect(staleSquad.forwards.first?.displayPoints == 4)
        #expect(staleSquad.forwards.first?.hasStartedFixtureThisGameweek == false)

        let squad = FantasySquadBuilder.build(
            gameweek: refreshed.gameweek, picksResponse: refreshed.picksResponse,
            liveResponse: refreshed.liveResponse, fixtures: refreshed.fixtures,
            seasonFixtures: refreshed.fixtures, bootstrap: bootstrap, now: now
        )
        let haaland = try #require(squad.forwards.first)
        #expect(haaland.displayPoints == 4)
        #expect(haaland.hasStartedFixtureThisGameweek)
        #expect(!haaland.hasActiveFixtureThisGameweek)
        #expect(!haaland.hasUpcomingFixtureThisGameweek)
        #expect(haaland.gameweekScoreState == .completed)
        #expect(squad.scorePhase == .provisional)
    }

    @Test func fixtureFailureDoesNotPublishPartialScoreSnapshot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedCurrentScoreURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = FantasyViewModel(fantasyPublicClient: FantasyPublicAPIClient(session: session))
        let gameweek = FantasyGameweek(
            id: 9, name: "Gameweek 9", isCurrent: true, isNext: false,
            finished: false, deadlineTime: nil
        )
        let picks = try JSONDecoder().decode(FantasyPicksResponse.self, from: Data(#"{"picks":[],"entry_history":{"event":9,"points":0}}"#.utf8))
        await #expect(throws: FantasyPublicAPIError.self) {
            _ = try await model.fetchCurrentScoreSnapshot(gameweek: gameweek, picksResponse: picks)
        }
    }
}

private nonisolated class CurrentScoreURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isFixtures = url.path.contains("fixtures")
        let payload = isFixtures
            ? #"[{"id":88,"event":9,"team_h":15,"team_a":5,"kickoff_time":"2026-10-31T15:00:00Z","started":true,"finished":false,"finished_provisional":true}]"#
            : #"{"elements":[{"id":411,"stats":{"total_points":2,"minutes":90}}]}"#
        let status = isFixtures && self is FailedCurrentScoreURLProtocol ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private nonisolated final class FailedCurrentScoreURLProtocol: CurrentScoreURLProtocol, @unchecked Sendable {}
