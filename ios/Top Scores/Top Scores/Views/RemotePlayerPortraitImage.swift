import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UIKit
import Vision

func playerPortraitPixelSizeIsRenderable(width: Int, height: Int) -> Bool {
    width > 1 && height > 1
}

func portraitURLNeedsBackgroundRemoval(_ url: URL) -> Bool {
    guard url.host?.lowercased() == "sports.bzzoiro.com" else { return false }
    return url.path.hasPrefix("/img/player/") || url.path.hasPrefix("/img/manager/")
}

func portraitURLForLocalBackgroundRemoval(_ url: URL) -> URL {
    guard url.host?.lowercased() == "sports.bzzoiro.com",
          url.path.hasPrefix("/img/manager/"),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return url
    }

    components.queryItems = components.queryItems?.filter {
        $0.name.caseInsensitiveCompare("bg") != .orderedSame
    }
    if components.queryItems?.isEmpty == true {
        components.queryItems = nil
    }
    return components.url ?? url
}

private func isRenderablePlayerPortrait(_ image: UIImage) -> Bool {
    if let cgImage = image.cgImage {
        return playerPortraitPixelSizeIsRenderable(
            width: cgImage.width,
            height: cgImage.height
        )
    }

    return playerPortraitPixelSizeIsRenderable(
        width: Int(image.size.width * image.scale),
        height: Int(image.size.height * image.scale)
    )
}

@MainActor
private final class PlayerPortraitImageCache {
    static let shared = PlayerPortraitImageCache()

    private let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        images.setObject(
            image,
            forKey: url as NSURL,
            cost: max(pixelWidth * pixelHeight * 4, 1)
        )
    }
}

private actor PlayerPortraitProcessingLimiter {
    static let shared = PlayerPortraitProcessingLimiter(maxConcurrentJobs: 2)

    private let maxConcurrentJobs: Int
    private var activeJobs = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentJobs: Int) {
        self.maxConcurrentJobs = max(maxConcurrentJobs, 1)
    }

    func acquire() async {
        if activeJobs < maxConcurrentJobs {
            activeJobs += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            activeJobs = max(activeJobs - 1, 0)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private enum PlayerPortraitBackgroundRemover {
    nonisolated static func transparentPNGData(from imageData: Data) async -> Data? {
        await PlayerPortraitProcessingLimiter.shared.acquire()
        let output = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                makeTransparentPNGData(from: imageData)
            }
        }.value
        await PlayerPortraitProcessingLimiter.shared.release()
        return output
    }

    nonisolated private static func makeTransparentPNGData(from imageData: Data) -> Data? {
        guard let inputImage = CIImage(
            data: imageData,
            options: [.applyOrientationProperty: true]
        ) else {
            return nil
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        do {
            let handler = VNImageRequestHandler(ciImage: inputImage)
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let maskBuffer = request.results?.first?.pixelBuffer else {
            return nil
        }
        guard hasUsefulForeground(in: maskBuffer) else {
            return nil
        }

        var maskImage = CIImage(cvPixelBuffer: maskBuffer)
        maskImage = maskImage.transformed(
            by: CGAffineTransform(
                scaleX: inputImage.extent.width / maskImage.extent.width,
                y: inputImage.extent.height / maskImage.extent.height
            )
        )
        // A fractional blur softens stair-stepping around hair without creating
        // the bright fringe produced by colour-keying the white background.
        maskImage = maskImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.55])
            .cropped(to: inputImage.extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = inputImage
        blend.backgroundImage = CIImage(color: .clear).cropped(to: inputImage.extent)
        blend.maskImage = maskImage

        guard let outputImage = blend.outputImage?.cropped(to: inputImage.extent) else {
            return nil
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).pngData()
    }

    nonisolated private static func hasUsefulForeground(in pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return false }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleStep = max(min(width, height) / 64, 1)
        var total = 0
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: sampleStep) {
                total += Int(row[x])
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return false }
        let averageOpacity = total / sampleCount
        return averageOpacity > 6 && averageOpacity < 249
    }
}

struct RemotePlayerPortraitImage<Content: View, Placeholder: View>: View {
    let urls: [URL]
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?

    init(
        urls: [URL],
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            await loadFirstRenderableImage()
        }
    }

    @MainActor
    private func loadFirstRenderableImage() async {
        loadedImage = nil

        for url in urls {
            guard !Task.isCancelled else { return }

            if let cached = PlayerPortraitImageCache.shared.image(for: url) {
                loadedImage = cached
                return
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continue
                }
                guard let originalImage = UIImage(data: data),
                      isRenderablePlayerPortrait(originalImage)
                else {
                    continue
                }

                let image: UIImage
                if portraitURLNeedsBackgroundRemoval(url),
                   let transparentData = await PlayerPortraitBackgroundRemover.transparentPNGData(
                       from: data
                   ),
                   !Task.isCancelled,
                   let transparentImage = UIImage(data: transparentData),
                   isRenderablePlayerPortrait(transparentImage) {
                    image = transparentImage
                } else {
                    guard !Task.isCancelled else { return }
                    image = originalImage
                }

                PlayerPortraitImageCache.shared.insert(image, for: url)
                loadedImage = image
                return
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                continue
            }
        }
    }
}
