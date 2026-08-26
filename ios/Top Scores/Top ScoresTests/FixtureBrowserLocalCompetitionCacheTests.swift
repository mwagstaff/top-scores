import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct FixtureBrowserLocalCompetitionCacheTests {
    @MainActor
    @Test func competitionSwitchReusesUnfilteredDeviceCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCompetitionCacheURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = FixtureBrowserRequestLog()
        defer {
            LocalCompetitionCacheURLProtocol.responseHandler = nil
            session.invalidateAndCancel()
        }

        LocalCompetitionCacheURLProtocol.responseHandler = { request in
            let url = try #require(request.url)
            requestLog.record(url)

            if url.path.hasSuffix("/competitions/catalog") {
                return Data(#"""
                {
                    "competitions": [
                        {"id":"premier-league","name":"Premier League","aliases":[],"weight":100,"region":"england"},
                        {"id":"la-liga","name":"La Liga","aliases":[],"weight":90,"region":"spain"},
                        {"id":"uefa-nations-league","name":"UEFA Nations League","aliases":[],"weight":80,"region":"europe"}
                    ]
                }
                """#.utf8)
            }

            if url.path.hasSuffix("/matches/calendar") {
                return Data(#"""
                {
                    "days": [
                        {
                            "date":"2026-08-26",
                            "match_count":2,
                            "top_match_count":2,
                            "has_unfinished":true,
                            "top_matches_have_unfinished":true,
                            "competitions":[
                                {"id":"premier-league","match_count":1,"has_unfinished":true},
                                {"id":"la-liga","match_count":1,"has_unfinished":true}
                            ]
                        },
                        {
                            "date":"2026-09-24",
                            "match_count":1,
                            "top_match_count":1,
                            "has_unfinished":true,
                            "top_matches_have_unfinished":true,
                            "competitions":[
                                {"id":"uefa-nations-league","match_count":1,"has_unfinished":true}
                            ]
                        }
                    ],
                    "selection_applied":false
                }
                """#.utf8)
            }

            if url.path.hasSuffix("/matches") {
                return Data(#"""
                {
                    "matches": [
                        {
                            "date":"2026-08-26",
                            "time":"19:00",
                            "home_team":"Arsenal",
                            "away_team":"Chelsea",
                            "league":"Premier League"
                        },
                        {
                            "date":"2026-08-26",
                            "time":"20:00",
                            "home_team":"Barcelona",
                            "away_team":"Valencia",
                            "league":"La Liga"
                        },
                        {
                            "date":"2026-09-24",
                            "time":"19:45",
                            "home_team":"England",
                            "away_team":"Spain",
                            "league":"UEFA Nations League"
                        }
                    ]
                }
                """#.utf8)
            }

            throw URLError(.badServerResponse)
        }

        let baseURL = "https://fixture-local-cache-\(UUID().uuidString).test/api/v1"
        let store = FixtureBrowserStore(apiSession: session)
        store.configure(preferences: Self.preferences(
            baseURL: baseURL,
            competitionID: "premier-league"
        ))

        for _ in 0..<100 where store.visibleMatches.map(\.homeTeam) != ["Arsenal"] {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.visibleMatches.map(\.homeTeam) == ["Arsenal"])
        await store.warmAllUpcomingFixtures()
        #expect(requestLog.matchRequestCount == 2)
        let requestCountBeforeSwitch = requestLog.urls.count

        store.configure(
            preferences: Self.preferences(
                baseURL: baseURL,
                competitionID: "uefa-nations-league"
            ),
            resetSelectedDate: true
        )

        #expect(store.selectedDateKey == "2026-09-24")
        #expect(store.visibleMatches.map(\.homeTeam) == ["England"])

        store.configure(
            preferences: Self.preferences(
                baseURL: baseURL,
                competitionID: "la-liga"
            ),
            resetSelectedDate: true
        )

        #expect(store.visibleMatches.map(\.homeTeam) == ["Barcelona"])
        #expect(requestLog.urls.count == requestCountBeforeSwitch)
        #expect(requestLog.urls.allSatisfy { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "view_option" }) != true
        })
    }

    private static func preferences(
        baseURL: String,
        competitionID: String
    ) -> PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: [],
            selectedFixtureViewOptionIDs: [FixtureViewOptionID.competition(competitionID)],
            selectedChannels: [],
            fixtureAllMajorMatchesEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            apiBaseURL: baseURL,
            refreshIntervalMinutes: 10
        )
    }
}

private final class FixtureBrowserRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.withLock { storage }
    }

    var matchRequestCount: Int {
        lock.withLock {
            storage.filter { $0.path.hasSuffix("/matches") }.count
        }
    }

    func record(_ url: URL) {
        lock.withLock {
            storage.append(url)
        }
    }
}

private final class LocalCompetitionCacheURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let data = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
