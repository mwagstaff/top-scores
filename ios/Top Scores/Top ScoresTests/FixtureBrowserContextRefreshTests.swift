import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct FixtureBrowserContextRefreshTests {
    @MainActor
    @Test func changingCompetitionKeepsInFlightUnfilteredCalendarRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureBrowserTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = FixtureBrowserContextRequestLog()
        defer {
            FixtureBrowserTestURLProtocol.responseHandler = nil
            session.invalidateAndCancel()
        }

        FixtureBrowserTestURLProtocol.responseHandler = { request in
            let url = try #require(request.url)
            let path = url.path
            requestLog.record(url)

            if path.hasSuffix("/competitions/catalog") {
                return .success(Data(#"""
                {
                    "competitions": [
                        {"id":"premier-league","name":"Premier League","aliases":[],"weight":100,"region":"england"},
                        {"id":"la-liga","name":"La Liga","aliases":[],"weight":90,"region":"spain"}
                    ]
                }
                """#.utf8))
            }

            if path.hasSuffix("/matches/calendar") {
                return .success(Data(Self.calendarJSON.utf8), delay: 0.4)
            }

            if path.hasSuffix("/matches") {
                return .success(Data(#"""
                {
                    "matches": [
                        {
                            "date":"2026-08-26",
                            "time":"18:00",
                            "home_team":"Arsenal",
                            "away_team":"Chelsea",
                            "league":"Premier League"
                        },
                        {
                            "date":"2026-08-26",
                            "time":"19:00",
                            "home_team":"Barcelona",
                            "away_team":"Valencia",
                            "league":"La Liga"
                        }
                    ]
                }
                """#.utf8))
            }

            return .failure(statusCode: 404, data: Data(#"{"error":"not found"}"#.utf8))
        }

        let baseURL = "https://fixture-browser-\(UUID().uuidString).test/api/v1"
        let store = FixtureBrowserStore(apiSession: session)
        store.configure(preferences: Self.preferences(
            baseURL: baseURL,
            competitionID: "premier-league"
        ))

        try await Task.sleep(for: .milliseconds(50))

        store.configure(preferences: Self.preferences(
            baseURL: baseURL,
            competitionID: "la-liga"
        ))

        for _ in 0..<100 where store.visibleMatches.map(\.homeTeam) != ["Barcelona"] {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.availableDays.map(\.date) == ["2026-08-26"])
        #expect(store.visibleMatches.map(\.homeTeam) == ["Barcelona"])
        #expect(store.competitions.map(\.stableID).contains("la-liga"))
        #expect(requestLog.calendarRequestCount == 1)
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

    private static let calendarJSON = #"""
    {
        "days": [{
            "date":"2026-08-26",
            "match_count":2,
            "top_match_count":2,
            "has_unfinished":true,
            "top_matches_have_unfinished":true,
            "competitions":[
                {"id":"premier-league","match_count":1,"has_unfinished":true},
                {"id":"la-liga","match_count":1,"has_unfinished":true}
            ]
        }],
        "selection_applied":false
    }
    """#
}

private final class FixtureBrowserContextRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var calendarRequestCount: Int {
        lock.withLock {
            storage.filter { $0.path.hasSuffix("/matches/calendar") }.count
        }
    }

    func record(_ url: URL) {
        lock.withLock {
            storage.append(url)
        }
    }
}

private final class FixtureBrowserTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let data: Data
        let delay: TimeInterval

        static func success(_ data: Data, delay: TimeInterval = 0) -> Response {
            Response(statusCode: 200, data: data, delay: delay)
        }

        static func failure(statusCode: Int, data: Data) -> Response {
            Response(statusCode: statusCode, data: data, delay: 0)
        }
    }

    nonisolated(unsafe) static var responseHandler: ((URLRequest) throws -> Response)?

    private let lock = NSLock()
    private var stopped = false

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
            let response = try handler(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
                self?.complete(with: response)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        lock.withLock {
            stopped = true
        }
    }

    private func complete(with response: Response) {
        let shouldStop = lock.withLock { stopped }
        guard !shouldStop, let url = request.url else { return }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
