import Foundation
import Testing
import UIKit
@testable import Top_Scores

@Suite(.serialized)
struct StadiumPhotoCacheTests {
    @Test @MainActor func storesPhotoOnDiskAndRestoresItsMatchLookup() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            StadiumPhotoTestURLProtocol.responseHandler = nil
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StadiumPhotoTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var requestCount = 0
        StadiumPhotoTestURLProtocol.responseHandler = { request in
            requestCount += 1
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                imageData
            )
        }

        let photoURL = try #require(URL(string: "https://example.com/stadium.png"))
        let firstCache = StadiumPhotoCache(
            cacheDirectory: temporaryDirectory,
            session: session
        )
        await firstCache.recordPhotoURL(
            photoURL,
            matchID: "match-1",
            venueID: "venue-1",
            teamID: "42",
            teamName: "Test United"
        )
        #expect(await firstCache.image(for: photoURL) != nil)
        #expect(requestCount == 1)

        let restoredCache = StadiumPhotoCache(
            cacheDirectory: temporaryDirectory,
            session: session
        )
        #expect(
            await restoredCache.knownPhotoURL(matchID: "match-1", venueID: nil) == photoURL
        )
        #expect(
            await restoredCache.knownTeamPhotoURL(teamID: "42", teamName: "Test United") == photoURL
        )
        #expect(await restoredCache.image(for: photoURL) != nil)
        #expect(requestCount == 1)
    }

    @Test func prewarmWindowIncludesYesterdayTodayAndTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))
        )

        let range = try #require(
            StadiumPhotoPrewarmPlanner.dateRange(around: date, calendar: calendar)
        )

        #expect(range.lowerBound == "2026-09-03")
        #expect(range.upperBound == "2026-09-05")
    }
}

private final class StadiumPhotoTestURLProtocol: URLProtocol, @unchecked Sendable {
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
