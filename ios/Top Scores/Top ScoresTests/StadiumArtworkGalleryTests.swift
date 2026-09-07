import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Top_Scores

@Suite(.serialized)
@MainActor
struct StadiumArtworkGalleryTests {
    #if DEBUG
    @Test func adminDeletionUpdatesAndPersistsCatalogueOnlyAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let asset = fixture.asset("selected-image", color: .red)
        let original = StadiumArtworkCatalog(schemaVersion: 1, catalogVersion: String(repeating: "a", count: 64),
                                            generatedAt: "2026-09-06", teams: [:], assets: [asset])
        let removed = StadiumArtworkCatalog(schemaVersion: 1, catalogVersion: String(repeating: "b", count: 64),
                                           generatedAt: "2026-09-06", teams: [:], assets: [])
        let originalData = try JSONEncoder().encode(original)
        let removedData = try JSONEncoder().encode(removed)
        ArtworkImageURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                #expect(request.url?.path == "/api/v1/stadium-artwork/admin/assets/selected-image")
                #expect(request.value(forHTTPHeaderField: "If-Match") == "\"\(asset.sha256)\"")
                if request.value(forHTTPHeaderField: "Authorization") != "Bearer test-key" {
                    return (403, Data("{\"error\":\"Invalid artwork admin key.\"}".utf8))
                }
                return (200, removedData)
            }
            return (200, originalData)
        }
        let cacheURL = fixture.directory.appendingPathComponent("catalog.json")
        let store = StadiumArtworkStore(cacheURL: cacheURL, session: fixture.session)
        await store.ensureFresh(apiBaseURL: fixture.baseURL, force: true)
        #expect(store.catalog?.assets.count == 1)
        do {
            try await store.deleteArtwork(asset, apiBaseURL: fixture.baseURL, adminToken: "wrong")
            Issue.record("Invalid credentials must fail")
        } catch {
            #expect(error.localizedDescription == "Invalid artwork admin key.")
        }
        #expect(store.catalog?.assets.count == 1)
        try await store.deleteArtwork(asset, apiBaseURL: fixture.baseURL, adminToken: "test-key")
        #expect(store.catalog?.assets.isEmpty == true)
        #expect(store.catalog?.catalogVersion == removed.catalogVersion)
        #expect(StadiumArtworkStore(cacheURL: cacheURL).catalog?.assets.isEmpty == true)
    }

    @Test func reviewLoadsOnlySelectedImageAndKeepsItForFramingChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = fixture.asset("other", color: .red)
        var selected = fixture.asset("selected", color: .blue)
        let cache = fixture.cache()
        _ = await cache.image(for: other, apiBaseURL: fixture.baseURL)
        let loader = StadiumArtworkReviewLoader(cache: cache)
        #expect(loader.image == nil)
        await loader.load(asset: selected, apiBaseURL: fixture.baseURL)
        #expect(loader.request?.hash == selected.sha256)
        let displayed = loader.image
        #expect(displayed != nil)
        #expect(displayed === (await cache.image(for: selected, apiBaseURL: fixture.baseURL)))
        selected.focalPoint = .init(x: 0.2, y: 0.7)
        await loader.load(asset: selected, apiBaseURL: fixture.baseURL)
        #expect(loader.image === displayed)
        #expect(ArtworkImageURLProtocol.requests == 2)
    }

    @Test func unavailableReviewImageNeverFallsBackToPreviousSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.asset("first", color: .red)
        let missing = fixture.asset("missing", color: .blue)
        ArtworkImageURLProtocol.dataByHash[missing.sha256] = nil
        let loader = StadiumArtworkReviewLoader(cache: fixture.cache())
        await loader.load(asset: first, apiBaseURL: fixture.baseURL)
        #expect(loader.image != nil)
        await loader.load(asset: missing, apiBaseURL: fixture.baseURL)
        #expect(loader.request?.hash == missing.sha256)
        #expect(loader.image == nil)
        #expect(!loader.isLoading)
        await loader.load(asset: first, apiBaseURL: fixture.baseURL)
        #expect(loader.request?.hash == first.sha256)
        #expect(loader.image != nil)
    }
    #endif

    @Test func focalPointMovesCropWithoutExposingImageEdges() {
        let viewport = CGSize(width: 400, height: 330)
        let image = CGSize(width: 1600, height: 900)
        let left = StadiumArtworkCrop.frame(imageSize: image, viewport: viewport,
                                            focalPoint: .init(x: 0, y: 0))
        let right = StadiumArtworkCrop.frame(imageSize: image, viewport: viewport,
                                             focalPoint: .init(x: 1, y: 1))
        #expect(left.minX == 0)
        #expect(abs(right.maxX - viewport.width) < 0.001)
        #expect(left.height == viewport.height)
        for frame in [left, right] {
            #expect(frame.minX <= 0 && frame.minY <= 0)
            #expect(frame.maxX >= viewport.width && frame.maxY >= viewport.height)
        }
        let portrait = StadiumArtworkCrop.frame(imageSize: CGSize(width: 900, height: 1600),
                                                viewport: viewport, focalPoint: .init(x: 0.5, y: 1))
        #expect(abs(portrait.maxY - viewport.height) < 0.001)
    }

    @Test func framingMetadataIsOptionalAndDoesNotRedownloadImage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var asset = fixture.asset("framing", color: .red)
        let original = try JSONEncoder().encode(asset)
        #expect(try JSONDecoder().decode(StadiumArtworkAsset.self, from: original).focalPoint == nil)
        let cache = fixture.cache()
        _ = await cache.image(for: asset, apiBaseURL: fixture.baseURL)
        asset.focalPoint = .init(x: 0.2, y: 0.8)
        let roundTrip = try JSONDecoder().decode(StadiumArtworkAsset.self, from: JSONEncoder().encode(asset))
        #expect(roundTrip.focalPoint == asset.focalPoint)
        _ = await cache.image(for: roundTrip, apiBaseURL: fixture.baseURL)
        #expect(ArtworkImageURLProtocol.requests == 1)
    }

    @Test func downloadedImagesAreReusedAfterCacheRecreation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let asset = fixture.asset("first", color: .red)
        let cache = fixture.cache()
        #expect(await cache.image(for: asset, apiBaseURL: fixture.baseURL) != nil)
        #expect(await cache.image(for: asset, apiBaseURL: fixture.baseURL) != nil)
        #expect(ArtworkImageURLProtocol.requests == 1)
        #expect(await fixture.cache().image(for: asset, apiBaseURL: fixture.baseURL) != nil)
        #expect(ArtworkImageURLProtocol.requests == 1)
    }

    @Test func removedImagesArePurgedEvenBelowCapacity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let asset = fixture.asset("removed", color: .red)
        let cache = fixture.cache()
        _ = await cache.image(for: asset, apiBaseURL: fixture.baseURL)
        await cache.prune(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: fixture.file(asset).path))
        #expect(await cache.image(for: asset, apiBaseURL: fixture.baseURL) == nil)
        #expect(ArtworkImageURLProtocol.requests == 1)
    }

    @Test func diskLimitEvictsOldestStillActiveImage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.asset("first", color: .red)
        let second = fixture.asset("second", color: .blue)
        let cache = fixture.cache(capacity: max(first.byteSize, second.byteSize))
        await cache.prune(keeping: [first.sha256, second.sha256])
        _ = await cache.image(for: first, apiBaseURL: fixture.baseURL)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: fixture.file(first).path)
        _ = await cache.image(for: second, apiBaseURL: fixture.baseURL)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(first).path))
        #expect(FileManager.default.fileExists(atPath: fixture.file(second).path))
    }

    @Test func cachedOnlyLookupDoesNotCallServerAndCorruptBytesAreReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let asset = fixture.asset("first", color: .red)
        let cache = fixture.cache()
        #expect(await cache.image(for: asset, apiBaseURL: fixture.baseURL, allowDownload: false) == nil)
        #expect(ArtworkImageURLProtocol.requests == 0)
        try Data("corrupt".utf8).write(to: fixture.file(asset))
        #expect(await cache.image(for: asset, apiBaseURL: fixture.baseURL) != nil)
        #expect(ArtworkImageURLProtocol.requests == 1)
    }

    @Test func reducedMotionLoadsOneImageAndCatalogueRemovalReplacesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.asset("first", color: .red)
        let second = fixture.asset("second", color: .blue)
        let player = StadiumArtworkGalleryPlayer(cache: fixture.cache())
        await player.run(assets: [first], apiBaseURL: fixture.baseURL, rotates: false)
        #expect(player.current?.hash == first.sha256)
        await player.run(assets: [second], apiBaseURL: fixture.baseURL, rotates: false)
        #expect(player.current?.hash == second.sha256)
        await player.run(assets: [], apiBaseURL: fixture.baseURL, rotates: true)
        #expect(player.current == nil)
    }

    @Test func rotationPreloadsCrossfadeAndCancelsCleanly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let assets = [fixture.asset("first", color: .red), fixture.asset("second", color: .blue)]
        let player = StadiumArtworkGalleryPlayer(cache: fixture.cache(), rotationInterval: .milliseconds(60))
        let task = Task { await player.run(assets: assets, apiBaseURL: fixture.baseURL, rotates: true) }
        defer { task.cancel() }
        for _ in 0..<100 where player.previous == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.previous != nil)
        #expect(player.previous?.hash != player.current?.hash)
        #expect(ArtworkImageURLProtocol.requests == 2)
        task.cancel()
        await task.value
        #expect(player.previous == nil)
        #expect(player.opacity == 1)
    }

    private struct Fixture {
        let directory: URL
        let session: URLSession
        let baseURL = "https://artwork.example/api/v1"

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ArtworkImageURLProtocol.dataByHash = [:]
            ArtworkImageURLProtocol.requests = 0
            ArtworkImageURLProtocol.handler = nil
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ArtworkImageURLProtocol.self]
            session = URLSession(configuration: config)
        }

        func cleanup() {
            ArtworkImageURLProtocol.handler = nil
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }

        func cache(capacity: Int = 1_000_000) -> StadiumArtworkImageCache {
            StadiumArtworkImageCache(cacheDirectory: directory, session: session, diskCapacity: capacity)
        }

        func file(_ asset: StadiumArtworkAsset) -> URL {
            directory.appendingPathComponent("\(asset.sha256).webp")
        }

        func asset(_ id: String, color: UIColor) -> StadiumArtworkAsset {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ArtworkImageURLProtocol.dataByHash[hash] = data
            return StadiumArtworkAsset(
                id: id, role: .team, lightContext: .any, teamIDs: ["example"], stadium: nil,
                sha256: hash, assetPath: "assets/\(hash).webp",
                assetURL: "/api/v1/stadium-artwork/assets/\(hash).webp", contentType: "image/webp",
                byteSize: data.count, width: 20, height: 10,
                credit: StadiumArtworkCredit(author: "Test", authorURL: nil, source: "Test", sourcePage: nil,
                                             license: "CC0", licenseURL: nil, attribution: "Test")
            )
        }
    }
}

private final class ArtworkImageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var dataByHash: [String: Data] = [:]
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if let handler = Self.handler {
            let (status, data) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let hash = request.url!.deletingPathExtension().lastPathComponent
        let data = Self.dataByHash[hash]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "image/webp"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
