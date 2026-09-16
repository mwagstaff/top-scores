import Foundation
import ImageIO
import Testing
import UIKit
@testable import Top_Scores_Watch_Watch_App

@Suite(.serialized) @MainActor
struct WatchFantasyImageTests {
    @Test func temporaryImageFailureRetriesAndCachesDecodedThumbnail() async throws {
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                             bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let sourceImage = try #require(context.makeImage())
        let png = try #require(UIImage(cgImage: sourceImage).pngData())
        #expect(CGImageSourceCreateWithData(png as CFData, nil) != nil)
        let url = "https://images.example.com/\(UUID().uuidString).png"
        let network = ImageResponses([(503, Data()), (200, png)])
        let loader = WatchFantasyImageLoader(fetch: { try await network.fetch($0) })
        await loader.load(urlString: url)
        #expect(await network.requestCount == 2)
        let image = try #require(loader.image)
        #expect(image.size.width <= 80)
        #expect(await network.requestCount == 2)

        let secondRow = WatchFantasyImageLoader(fetch: { try await network.fetch($0) })
        await secondRow.load(urlString: url)
        #expect(secondRow.image != nil)
        #expect(await network.requestCount == 2)
    }

    @Test func missingImageDoesNotKeepRetryingAndCancelledLoadsDoNotPublish() async {
        let url = "https://images.example.com/\(UUID().uuidString).png"
        let network = ImageResponses([(404, Data())])
        let loader = WatchFantasyImageLoader(fetch: { try await network.fetch($0) })
        await loader.load(urlString: url)
        #expect(loader.image == nil)
        #expect(await network.requestCount == 1)
        let task = Task { await loader.load(urlString: "https://images.example.com/cancelled.png") }
        task.cancel()
        await task.value
        #expect(loader.image == nil)
        #expect(await network.requestCount == 1)
    }

    @Test func badgeURLsNormalizeAndRefreshPreservesKnownLogo() {
        #expect(WatchFantasyImageLoader.normalizedURL(" //example.com/badge.png ")?.absoluteString == "https://example.com/badge.png")
        #expect(WatchFantasyImageLoader.normalizedURL("/gcs/badge.png")?.absoluteString == "https://fantasy.premierleague.com/gcs/badge.png")
        #expect(WatchFantasyImageLoader.normalizedURL(" ") == nil)
        let cached = WatchFantasyStanding(entry: 1, rank: 2, lastRank: 3, entryName: "Team", playerName: "Manager", total: 100, clubBadgeSrc: "https://example.com/badge.png")
        let refreshed = WatchFantasyStanding(entry: 1, rank: 1, lastRank: 2, entryName: "Team", playerName: "Manager", total: 120, clubBadgeSrc: nil).preservingBadge(from: cached)
        #expect(refreshed.clubBadgeSrc == cached.clubBadgeSrc)
        #expect(refreshed.rank == 1)
        #expect(refreshed.total == 120)
    }

}

private actor ImageResponses {
    private let responses: [(Int, Data)]
    private(set) var requestCount = 0

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        let (status, data) = responses[min(requestCount, responses.count - 1)]
        requestCount += 1
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
