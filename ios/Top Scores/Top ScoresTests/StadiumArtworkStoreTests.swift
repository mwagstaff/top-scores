import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct StadiumArtworkStoreTests {
    @Test @MainActor func assetURLPreservesConfiguredDeploymentPrefix() throws {
        let asset = try #require(makeCatalog().assets.first)

        let url = asset.remoteURL(
            apiBaseURL: "https://api.skynolimit.dev/top-scores/api/v1"
        )

        #expect(
            url?.absoluteString ==
                "https://api.skynolimit.dev/top-scores/api/v1/stadium-artwork/assets/\("b".repeated(64)).webp"
        )
    }

    @Test @MainActor func refreshesAtMostEveryFifteenMinutesAndUsesETag() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = temporaryDirectory.appendingPathComponent("catalog.json")
        defer {
            StadiumArtworkTestURLProtocol.responseHandler = nil
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StadiumArtworkTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let catalogData = try JSONEncoder().encode(makeCatalog())
        var requests: [URLRequest] = []
        StadiumArtworkTestURLProtocol.responseHandler = { request in
            requests.append(request)
            let isConditional = request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: isConditional ? 304 : 200,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"v1\""]
                )!,
                isConditional ? Data() : catalogData
            )
        }

        let store = StadiumArtworkStore(cacheURL: cacheURL, session: session)
        let start = Date()
        await store.ensureFresh(apiBaseURL: "https://example.com/api/v1", now: start)
        #expect(store.catalog?.catalogVersion == "a".repeated(64))
        #expect(requests.count == 1)

        await store.ensureFresh(
            apiBaseURL: "https://example.com/api/v1",
            now: start.addingTimeInterval(899)
        )
        #expect(requests.count == 1)

        await store.ensureFresh(
            apiBaseURL: "https://example.com/api/v1",
            now: start.addingTimeInterval(901)
        )
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(store.catalog?.catalogVersion == "a".repeated(64))

        await store.ensureFresh(
            apiBaseURL: "https://example.com/api/v1",
            force: true,
            now: start.addingTimeInterval(901)
        )
        #expect(requests.count == 3)

        let restored = StadiumArtworkStore(cacheURL: cacheURL, session: session)
        #expect(restored.catalog?.assets.first?.id == "generic-day")
    }

    private func makeCatalog() -> StadiumArtworkCatalog {
        StadiumArtworkCatalog(
            schemaVersion: 1,
            catalogVersion: "a".repeated(64),
            generatedAt: "2026-08-27T00:00:00Z",
            teams: [:],
            assets: [
                StadiumArtworkAsset(
                    id: "generic-day",
                    role: .genericMatch,
                    lightContext: .day,
                    teamIDs: [],
                    stadium: nil,
                    sha256: "b".repeated(64),
                    assetPath: "assets/\("b".repeated(64)).webp",
                    assetURL: "/api/v1/stadium-artwork/assets/\("b".repeated(64)).webp",
                    contentType: "image/webp",
                    byteSize: 100,
                    width: 640,
                    height: 360,
                    credit: StadiumArtworkCredit(
                        author: "Top Scores",
                        authorURL: nil,
                        source: "Top Scores",
                        sourcePage: nil,
                        license: "Top Scores artwork",
                        licenseURL: nil,
                        attribution: "Top Scores artwork"
                    )
                )
            ]
        )
    }
}

private final class StadiumArtworkTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.responseHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
