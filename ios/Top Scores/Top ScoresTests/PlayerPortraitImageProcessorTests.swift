import Foundation
import Testing
import UIKit
@testable import Top_Scores

@MainActor
struct PlayerPortraitImageProcessorTests {
    @Test func rejectsMissingPortraitPlaceholderAndMalformedData() async {
        let placeholder = pngData(size: CGSize(width: 1, height: 1))
        #expect(await PlayerPortraitImageProcessor.displayImage(
            from: placeholder, removingBackground: false
        ) == nil)
        #expect(await PlayerPortraitImageProcessor.displayImage(
            from: Data("invalid image".utf8), removingBackground: false
        ) == nil)
    }

    @Test func preparesConcurrentPortraitsWithoutLosingTransparency() async throws {
        let data = pngData(size: CGSize(width: 16, height: 20))
        let images = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await PlayerPortraitImageProcessor.displayImage(from: data, removingBackground: false)
                }
            }
            var output: [UIImage] = []
            for await image in group {
                if let image { output.append(image) }
            }
            return output
        }
        #expect(images.count == 8)
        for image in images {
            let cgImage = try #require(image.cgImage)
            #expect(cgImage.width == 16)
            #expect(cgImage.height == 20)
            #expect([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo))
        }
    }

    @Test func canceledProcessingDoesNotPublishOrPreventFollowingLoads() async {
        let data = pngData(size: CGSize(width: 4, height: 4))
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PlayerPortraitImageProcessor.displayImage(from: data, removingBackground: true)
        }
        #expect(await canceled.value == nil)
        #expect(await PlayerPortraitImageProcessor.displayImage(
            from: data, removingBackground: false
        ) != nil)
    }

    private func pngData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.blue.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
