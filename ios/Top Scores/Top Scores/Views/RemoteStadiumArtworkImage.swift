import CryptoKit
import Combine
import Foundation
import SwiftUI
import UIKit

actor StadiumArtworkImageCache {
    static let shared = StadiumArtworkImageCache()

    private static let maximumDownloadBytes = 12 * 1_024 * 1_024
    private let diskCapacity: Int
    private var retainedHashes: Set<String>?

    private let cacheDirectory: URL
    private let session: URLSession
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(
        cacheDirectory: URL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("stadium-artwork", isDirectory: true),
        session: URLSession? = nil,
        diskCapacity: Int = 150 * 1_024 * 1_024
    ) {
        self.cacheDirectory = cacheDirectory
        self.diskCapacity = diskCapacity
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    func image(for asset: StadiumArtworkAsset, apiBaseURL: String, allowDownload: Bool = true) async -> UIImage? {
        let key = asset.sha256
        guard retainedHashes?.contains(key) != false else { return nil }
        if let cached = images.object(forKey: key as NSString) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: cacheDirectory.appendingPathComponent("\(key).webp").path
            )
            return cached
        }
        if let task = inFlight[key] {
            guard allowDownload else { return nil }
            return await task.value
        }

        let task = Task.detached(priority: .userInitiated) { [cacheDirectory, session] in
            await Self.loadImage(
                asset: asset,
                apiBaseURL: apiBaseURL,
                cacheDirectory: cacheDirectory,
                session: session,
                allowDownload: allowDownload
            )
        }
        if allowDownload { inFlight[key] = task }
        let image = await task.value
        if allowDownload { inFlight[key] = nil }
        guard retainedHashes?.contains(key) != false else { return nil }
        if let image {
            let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
            let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
            images.setObject(
                image,
                forKey: key as NSString,
                cost: max(pixelWidth * pixelHeight * 4, 1)
            )
        }
        trimDiskCache()
        return image
    }

    func prune(keeping hashes: Set<String>) {
        retainedHashes = hashes
        for (hash, task) in inFlight where !hashes.contains(hash) {
            task.cancel()
        }
        images.removeAllObjects()
        trimDiskCache()
    }

    private func trimDiskCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let values = files.compactMap { url -> (url: URL, hash: String, size: Int, date: Date)? in
            guard url.pathExtension == "webp",
                  let resource = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                  ) else { return nil }
            return (
                url,
                url.deletingPathExtension().lastPathComponent,
                resource.fileSize ?? 0,
                resource.contentModificationDate ?? .distantPast
            )
        }
        var totalSize = values.reduce(0) { $0 + $1.size }
        for file in values.sorted(by: { $0.date < $1.date }) {
            guard retainedHashes?.contains(file.hash) == false || totalSize > diskCapacity else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalSize -= file.size
                images.removeObject(forKey: file.hash as NSString)
            } catch {
                continue
            }
        }
    }

    #if DEBUG
    func prefetch(
        assets: [StadiumArtworkAsset],
        apiBaseURL: String,
        maximumConcurrentDownloads: Int = 4
    ) async -> Int {
        guard !assets.isEmpty else { return 0 }

        let concurrency = min(max(maximumConcurrentDownloads, 1), assets.count)
        return await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            var iterator = assets.makeIterator()
            for _ in 0..<concurrency {
                guard let asset = iterator.next() else { break }
                group.addTask {
                    await self.image(for: asset, apiBaseURL: apiBaseURL) != nil
                }
            }

            var loadedCount = 0
            while let loaded = await group.next() {
                if loaded {
                    loadedCount += 1
                }
                if let asset = iterator.next() {
                    group.addTask {
                        await self.image(for: asset, apiBaseURL: apiBaseURL) != nil
                    }
                }
            }
            return loadedCount
        }
    }
    #endif

    private nonisolated static func loadImage(
        asset: StadiumArtworkAsset,
        apiBaseURL: String,
        cacheDirectory: URL,
        session: URLSession,
        allowDownload: Bool
    ) async -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(asset.sha256).webp")
        if let data = try? Data(contentsOf: fileURL),
           data.count == asset.byteSize,
           sha256(data) == asset.sha256,
           let image = renderableImage(from: data) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )
            return image
        }

        guard allowDownload, let remoteURL = asset.remoteURL(apiBaseURL: apiBaseURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: remoteURL)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased() == "image/webp",
                  !data.isEmpty,
                  data.count <= Self.maximumDownloadBytes,
                  data.count == asset.byteSize,
                  sha256(data) == asset.sha256,
                  let image = renderableImage(from: data) else {
                return nil
            }
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return image
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            diagnosticLog("[StadiumArtwork] Image download failed: \(error)")
            return nil
        }
    }

    private nonisolated static func renderableImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        return width > 1 && height > 1 ? image.preparingForDisplay() : nil
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RemoteStadiumArtworkImage: View {
    let asset: StadiumArtworkAsset?
    let apiBaseURL: String
    let fallbackAssetName: String

    @State private var remoteImage: UIImage?

    var body: some View {
        Group {
            if let remoteImage {
                Image(uiImage: remoteImage)
                    .resizable()
            } else {
                PreparedBundledImage(assetName: fallbackAssetName)
            }
        }
        .task(id: loadID) {
            remoteImage = nil
            guard let asset else { return }
            let image = await StadiumArtworkImageCache.shared.image(
                for: asset,
                apiBaseURL: apiBaseURL
            )
            guard !Task.isCancelled else { return }
            remoteImage = image
        }
    }

    private var loadID: String {
        "\(apiBaseURL)|\(asset?.sha256 ?? "fallback")"
    }
}

/// Owns loading and timing so score updates never restart a gallery cycle.
@MainActor
final class StadiumArtworkGalleryPlayer: ObservableObject {
    struct Frame {
        let hash: String
        let image: UIImage
    }

    @Published private(set) var current: Frame?
    @Published private(set) var previous: Frame?
    @Published private(set) var opacity = 1.0
    private var generation = UUID()
    private var server: String?
    private let cache: StadiumArtworkImageCache
    private let rotationInterval: Duration

    init(cache: StadiumArtworkImageCache = .shared, rotationInterval: Duration = .seconds(20)) {
        self.cache = cache
        self.rotationInterval = rotationInterval
    }

    func run(assets: [StadiumArtworkAsset], apiBaseURL: String, rotates: Bool) async {
        let runID = UUID()
        generation = runID
        previous = nil
        opacity = 1
        var seen = Set<String>()
        let gallery = assets.filter { seen.insert($0.sha256).inserted }.shuffled()
        if server != apiBaseURL || !gallery.contains(where: { $0.sha256 == current?.hash }) {
            current = nil
        }
        server = apiBaseURL
        guard !gallery.isEmpty else { return }

        do {
            if current == nil {
                // Prefer any existing local photograph before attempting a network request.
                for allowDownload in [false, true] {
                    for asset in gallery {
                        let image = await cache.image(for: asset, apiBaseURL: apiBaseURL, allowDownload: allowDownload)
                        try Task.checkCancellation()
                        guard generation == runID else { return }
                        if let image {
                            withAnimation(rotates ? .easeInOut(duration: 1.5) : nil) {
                                current = Frame(hash: asset.sha256, image: image)
                            }
                            break
                        }
                    }
                    if current != nil { break }
                }
            }
            guard rotates, gallery.count > 1, current != nil else { return }
            var index = gallery.firstIndex { $0.sha256 == current?.hash } ?? 0
            var deadline = ContinuousClock.now.advanced(by: rotationInterval)
            while !Task.isCancelled {
                index = (index + 1) % gallery.count
                let asset = gallery[index]
                // Prefetch while the current image remains visible.
                let image = await cache.image(for: asset, apiBaseURL: apiBaseURL)
                try await Task.sleep(until: deadline, clock: .continuous)
                try Task.checkCancellation()
                guard generation == runID else { return }
                deadline = ContinuousClock.now.advanced(by: rotationInterval)
                guard let image, asset.sha256 != current?.hash else { continue }
                previous = current
                current = Frame(hash: asset.sha256, image: image)
                opacity = 0
                // Let SwiftUI install the next layer before fading it in.
                try await Task.sleep(for: .milliseconds(16))
                withAnimation(.easeInOut(duration: 1.5)) { opacity = 1 }
                try await Task.sleep(for: .milliseconds(1500))
                previous = nil
            }
        } catch {
            // View disappearance, gallery changes and backgrounding cancel this task.
            if generation == runID {
                previous = nil
                opacity = 1
            }
        }
    }
}

struct RotatingStadiumArtworkImage: View {
    let assets: [StadiumArtworkAsset]
    let apiBaseURL: String
    let fallbackAssetName: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var artworkStore: StadiumArtworkStore
    @StateObject private var player = StadiumArtworkGalleryPlayer()
    #if DEBUG
    @Environment(\.stadiumArtworkReviewAsset) private var reviewAsset
    #endif

    private func focalPoint(for hash: String) -> StadiumArtworkFocalPoint {
        assets.first { $0.sha256 == hash }?.focalPoint ?? .center
    }

    var body: some View {
        #if DEBUG
        if let reviewAsset {
            FixedStadiumArtworkReviewImage(asset: reviewAsset, apiBaseURL: apiBaseURL)
        } else {
            rotatingImage
        }
        #else
        rotatingImage
        #endif
    }

    private var rotatingImage: some View {
        GeometryReader { proxy in
            ZStack {
                PreparedBundledImage(assetName: fallbackAssetName).scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                if let previous = player.previous {
                    StadiumArtworkCroppedImage(image: previous.image, focalPoint: focalPoint(for: previous.hash))
                }
                if let current = player.current {
                    StadiumArtworkCroppedImage(image: current.image, focalPoint: focalPoint(for: current.hash))
                        .opacity(player.opacity)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: playbackID) {
            guard scenePhase == .active else { return }
            await player.run(assets: assets, apiBaseURL: apiBaseURL, rotates: !reduceMotion)
        }
        .task(id: "\(apiBaseURL)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            await artworkStore.refreshWhileVisible(apiBaseURL: apiBaseURL)
        }
    }

    private var playbackID: String {
        "\(apiBaseURL)|\(scenePhase)|\(reduceMotion)|\(assets.map(\.sha256).joined(separator: ","))"
    }
}

/// A focal point identifies the part of the original photograph to keep centred.
/// Clamp the crop at the image edges so no empty bands can appear.
nonisolated enum StadiumArtworkCrop {
    static func frame(imageSize: CGSize, viewport: CGSize, focalPoint: StadiumArtworkFocalPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let x = focalPoint.x.isFinite ? min(1, max(0, focalPoint.x)) : 0.5
        let y = focalPoint.y.isFinite ? min(1, max(0, focalPoint.y)) : 0.5
        return CGRect(x: min(0, max(viewport.width - size.width, viewport.width / 2 - size.width * x)),
                      y: min(0, max(viewport.height - size.height, viewport.height / 2 - size.height * y)),
                      width: size.width, height: size.height)
    }
}

private struct StadiumArtworkCroppedImage: View {
    let image: UIImage
    let focalPoint: StadiumArtworkFocalPoint

    var body: some View {
        GeometryReader { proxy in
            let frame = StadiumArtworkCrop.frame(imageSize: image.size, viewport: proxy.size, focalPoint: focalPoint)
            Image(uiImage: image).resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
        .clipped()
    }
}

/// Reserve just enough image around the edges for a subtle tilt and scroll effect.
struct StadiumHeroMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = StadiumParallaxMotionModel.shared
    var scrollOffset: CGFloat? = nil

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let horizontal = StadiumParallaxFilter.maximumHorizontalTranslation * 0.35
            let vertical = StadiumParallaxFilter.maximumVerticalTranslation * 0.35 + (scrollOffset == nil ? 0 : 6)
            let scale = reduceMotion ? 1 : 1 + max(2 * horizontal / max(1, proxy.size.width),
                                                  2 * vertical / max(1, proxy.size.height))
            content
                .scaleEffect(scale)
                .offset(x: reduceMotion ? 0 : motion.translation.width * 0.35,
                        y: reduceMotion ? 0 : motion.translation.height * 0.35 + min(6, max(-6, scrollOffset ?? 0)))
        }
        .clipped()
        .stadiumParallaxMotionLifecycle()
    }
}

#if DEBUG
/// Review has no slideshow, fallback photograph or entrance crossfade.
@MainActor
final class StadiumArtworkReviewLoader: ObservableObject {
    struct Request: Equatable, Hashable {
        let hash: String
        let apiBaseURL: String
    }
    @Published private(set) var image: UIImage?
    @Published private(set) var request: Request?
    @Published private(set) var isLoading = false
    private var generation = UUID()
    private let cache: StadiumArtworkImageCache

    init(cache: StadiumArtworkImageCache = .shared) { self.cache = cache }

    func load(asset: StadiumArtworkAsset, apiBaseURL: String) async {
        let requested = Request(hash: asset.sha256, apiBaseURL: apiBaseURL)
        if request == requested, image != nil { return }
        let runID = UUID()
        generation = runID
        request = requested
        image = nil
        isLoading = true
        let loaded = await cache.image(for: asset, apiBaseURL: apiBaseURL)
        guard generation == runID else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

private struct FixedStadiumArtworkReviewImage: View {
    let asset: StadiumArtworkAsset
    let apiBaseURL: String
    @StateObject private var loader = StadiumArtworkReviewLoader()

    private var request: StadiumArtworkReviewLoader.Request {
        .init(hash: asset.sha256, apiBaseURL: apiBaseURL)
    }

    var body: some View {
        ZStack {
            Color.black
            if loader.request == request, let image = loader.image {
                StadiumArtworkCroppedImage(image: image, focalPoint: asset.focalPoint ?? .center)
            } else if loader.request == request, !loader.isLoading {
                Label("Image unavailable", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .task(id: request) {
            await loader.load(asset: asset, apiBaseURL: apiBaseURL)
        }
        .accessibilityHidden(true)
    }
}
#endif

#if DEBUG
private struct StadiumArtworkReviewAssetKey: EnvironmentKey {
    static let defaultValue: StadiumArtworkAsset? = nil
}

extension EnvironmentValues {
    var stadiumArtworkReviewAsset: StadiumArtworkAsset? {
        get { self[StadiumArtworkReviewAssetKey.self] }
        set { self[StadiumArtworkReviewAssetKey.self] = newValue }
    }
}
#endif
