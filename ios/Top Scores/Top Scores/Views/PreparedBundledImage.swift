import Foundation
import SwiftUI
import UIKit

/// Serializes asset lookup and decompression away from navigation's main actor.
actor BundledDisplayImageCache {
    static let shared = BundledDisplayImageCache()

    private let imageLoader: @Sendable (String) -> UIImage?
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    init(imageLoader: @escaping @Sendable (String) -> UIImage? = {
        BundledDisplayImageCache.loadImage(named: $0)
    }) {
        self.imageLoader = imageLoader
    }

    func image(named assetName: String) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = images.object(forKey: assetName as NSString) {
            return image
        }
        guard let image = imageLoader(assetName), !Task.isCancelled else { return nil }
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        images.setObject(image, forKey: assetName as NSString, cost: max(1, width * height * 4))
        return image
    }

    private nonisolated static func loadImage(named assetName: String) -> UIImage? {
        let started = ProcessInfo.processInfo.systemUptime
        diagnosticLogAsync("[BundledImage] load_started asset=\(assetName) uptime_ms=\(Int(started * 1_000)) main_thread=\(Thread.isMainThread)")
        return autoreleasepool {
            let source = UIImage(named: assetName, in: .main, compatibleWith: nil)
            let loadedAt = ProcessInfo.processInfo.systemUptime
            let image = source?.preparingForDisplay()
            let finishedAt = ProcessInfo.processInfo.systemUptime
            diagnosticLogAsync(
                "[BundledImage] load_finished asset=\(assetName) uptime_ms=\(Int(finishedAt * 1_000)) lookup_ms=\(Int((loadedAt - started) * 1_000)) prepare_ms=\(Int((finishedAt - loadedAt) * 1_000)) size=\(image?.cgImage?.width ?? 0)x\(image?.cgImage?.height ?? 0) success=\(image != nil) main_thread=\(Thread.isMainThread)"
            )
            return image
        }
    }
}

/// A resizable bundled image whose placeholder uses the same proposed bounds.
struct PreparedBundledImage: View {
    let assetName: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: assetName) {
            image = nil
            let loaded = await BundledDisplayImageCache.shared.image(named: assetName)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
