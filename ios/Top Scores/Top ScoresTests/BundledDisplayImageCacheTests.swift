import Foundation
import Testing
import UIKit
@testable import Top_Scores

@MainActor
struct BundledDisplayImageCacheTests {
    @Test func coldMatchArtworkLoadsAtItsOriginalSizeAndIsReused() async throws {
        let cache = BundledDisplayImageCache()
        for (name, width, height) in [
            ("MatchStadium01Day", 1536, 510),
            ("MatchLineupPitchTexture", 1024, 1536)
        ] {
            let image = try #require(await cache.image(named: name))
            #expect(image.cgImage?.width == width)
            #expect(image.cgImage?.height == height)
            #expect(await cache.image(named: name) === image)
        }
    }

    @Test func slowAssetLoadingLeavesMainActorResponsive() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let started = AsyncStream<Void>.makeStream()
        let mayFinish = DispatchSemaphore(value: 0)
        let cache = BundledDisplayImageCache { _ in
            #expect(!Thread.isMainThread)
            started.continuation.yield(())
            started.continuation.finish()
            // The main actor must remain free to release this simulated slow
            // decoder. A timeout turns a regression into a failure, not a hang.
            #expect(mayFinish.wait(timeout: .now() + 2) == .success)
            return image
        }
        let loading = Task { await cache.image(named: "slow-test-image") }
        for await _ in started.stream { break }
        mayFinish.signal()
        #expect(await loading.value === image)
    }

    @Test func missingAndCanceledAssetsDoNotPopulateTheCache() async {
        let cache = BundledDisplayImageCache()
        #expect(await cache.image(named: "missing-match-artwork-test") == nil)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(named: "MatchStadium01Day")
        }
        #expect(await canceled.value == nil)
        #expect(await cache.image(named: "MatchStadium01Day") != nil)
    }
}
