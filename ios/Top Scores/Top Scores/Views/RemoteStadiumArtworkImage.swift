import CryptoKit
import Foundation
import SwiftUI
import UIKit

actor StadiumArtworkImageCache {
    static let shared = StadiumArtworkImageCache()

    private static let maximumDownloadBytes = 12 * 1_024 * 1_024
    private static let diskCapacity = 150 * 1_024 * 1_024

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
        session: URLSession? = nil
    ) {
        self.cacheDirectory = cacheDirectory
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

    func image(for asset: StadiumArtworkAsset, apiBaseURL: String) async -> UIImage? {
        let key = asset.sha256
        if let cached = images.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> { [cacheDirectory, session] in
            await Self.loadImage(
                asset: asset,
                apiBaseURL: apiBaseURL,
                cacheDirectory: cacheDirectory,
                session: session
            )
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
            let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
            images.setObject(
                image,
                forKey: key as NSString,
                cost: max(pixelWidth * pixelHeight * 4, 1)
            )
        }
        return image
    }

    func prune(keeping hashes: Set<String>) {
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
        guard totalSize > Self.diskCapacity else { return }

        for file in values.filter({ !hashes.contains($0.hash) }).sorted(by: { $0.date < $1.date }) {
            guard totalSize > Self.diskCapacity else { break }
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
        session: URLSession
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

        guard let remoteURL = asset.remoteURL(apiBaseURL: apiBaseURL) else { return nil }
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
        return width > 1 && height > 1 ? image : nil
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
                Image(fallbackAssetName)
                    .resizable()
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
