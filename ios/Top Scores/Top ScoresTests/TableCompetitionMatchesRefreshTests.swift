import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct TableCompetitionMatchesRefreshTests {
    @Test @MainActor func staleLiveSeasonMatchIsHydratedToFullTime() async throws {
        defer { TableCompetitionMatchesURLProtocol.responseHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TableCompetitionMatchesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let staleMatch = Match(
            date: "2026-08-30",
            time: "16:30",
            homeTeam: "Manchester United",
            awayTeam: "Ipswich Town",
            league: "Premier League",
            leagueId: "premier-league",
            seasonID: 1,
            roundNumber: 2,
            matchDetailsID: "123",
            tvChannels: [],
            homeScore: 5,
            awayScore: 2,
            scoreStatus: "96'"
        )
        let seasonData = try JSONEncoder().encode([staleMatch])
        let stateData = try #require(
            """
            [{
                "id": "123",
                "date": "2026-08-30",
                "time": "16:30",
                "league": "Premier League",
                "home_team": "Manchester United",
                "away_team": "Ipswich Town",
                "home_score": 5,
                "away_score": 2,
                "score_status": "FT",
                "in_progress": false
            }]
            """.data(using: .utf8)
        )
        var requestedPaths: [String] = []

        TableCompetitionMatchesURLProtocol.responseHandler = { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            let isStateRequest = url.path.hasSuffix("/matches/states")
            if isStateRequest {
                #expect(request.httpMethod == "POST")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(URLQueryItem(name: "summary_only", value: "true")) == true)
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                isStateRequest ? stateData : seasonData
            )
        }

        let matches = try await APIClient(
            baseURL: URL(string: "https://example.com/api/v1")!,
            session: session
        ).fetchCompetitionSeasonMatches(leagueName: "Premier League")

        let match = try #require(matches.first)
        #expect(match.scoreStatus == "FT")
        #expect(match.isFinished)
        #expect(!match.isInProgress)
        #expect(requestedPaths == ["/api/v1/matches", "/api/v1/matches/states"])
    }
}

private final class TableCompetitionMatchesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.responseHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
