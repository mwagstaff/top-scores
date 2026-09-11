import Combine
import CoreGraphics
import CoreMotion
import Foundation
import Testing
import UIKit
@testable import Top_Scores

struct StadiumParallaxMotionTests {
    @MainActor
    @Test func driverInitializesOnceAndSerializesLifecycleAwayFromMainThread() async {
        let queue = DispatchQueue(label: "StadiumParallaxMotionTests.driver")
        let backend = RecordingParallaxMotionBackend()
        let driver = StadiumParallaxMotionDriver(queue: queue) {
            #expect(!Thread.isMainThread)
            backend.record("initialize")
            return backend
        }

        driver.stop()
        await drain(queue)
        #expect(backend.events.isEmpty)

        driver.start(orientation: .portrait, initialTranslation: CGSize(width: 4, height: 0)) { _ in }
        driver.stop()
        driver.start(orientation: .landscapeLeft, initialTranslation: CGSize(width: 7, height: 0)) { _ in }
        driver.stop()
        await drain(queue)

        #expect(backend.events == ["initialize", "start:portrait:4", "stop", "start:landscapeLeft:7", "stop"])
    }

    @MainActor
    @Test func reactivationRejectsCallbacksFromPreviousMotionGeneration() async {
        let queue = DispatchQueue(label: "StadiumParallaxMotionTests.generations")
        let backend = RecordingParallaxMotionBackend()
        let driver = StadiumParallaxMotionDriver(queue: queue) { backend }
        let model = StadiumParallaxMotionModel(driver: driver)
        let viewID = UUID()
        model.activate(viewID: viewID, orientation: .portrait)
        await drain(queue)
        model.deactivate(viewID: viewID)
        model.activate(viewID: viewID, orientation: .landscapeRight)
        await drain(queue)

        let callbacks = backend.callbacks
        #expect(callbacks.count == 2)
        guard callbacks.count == 2 else { return }
        let expected = CGSize(width: 3, height: 2)
        var observation: AnyCancellable?
        let published: CGSize = await withCheckedContinuation { continuation in
            observation = model.$translation.dropFirst().first().sink {
                continuation.resume(returning: $0)
            }
            callbacks[0](CGSize(width: 99, height: 99))
            callbacks[1](expected)
        }
        observation?.cancel()

        #expect(published == expected)
        #expect(model.translation == expected)
        model.deactivate(viewID: viewID)
        await drain(queue)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    @Test func filteringEasesTowardClampedTranslation() {
        var filter = StadiumParallaxFilter()

        let first = filter.update(horizontalAngle: 1, verticalAngle: -1, timestamp: 0)
        var settled = first
        for frame in 1 ... 240 {
            settled = filter.update(
                horizontalAngle: 1,
                verticalAngle: -1,
                timestamp: Double(frame) / 60
            )
        }

        #expect(abs(first.width) < StadiumParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(first.height) < StadiumParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) <= StadiumParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(settled.height) <= StadiumParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) > abs(first.width))
        #expect(abs(settled.height) > abs(first.height))
    }

    @Test func filteringSmoothlyReturnsToCentre() {
        var filter = StadiumParallaxFilter()
        for frame in 0 ... 120 {
            _ = filter.update(
                horizontalAngle: 0.18,
                verticalAngle: -0.18,
                timestamp: Double(frame) / 60
            )
        }
        let displaced = filter.translation
        var returned = displaced
        for frame in 121 ... 360 {
            returned = filter.update(
                horizontalAngle: 0,
                verticalAngle: 0,
                timestamp: Double(frame) / 60
            )
        }

        #expect(abs(returned.width) < abs(displaced.width))
        #expect(abs(returned.height) < abs(displaced.height))
        #expect(abs(returned.width) < 0.01)
        #expect(abs(returned.height) < 0.01)
    }

    @Test func filteringIgnoresTinyAttitudeNoise() {
        var filter = StadiumParallaxFilter()
        let translation = filter.update(
            horizontalAngle: 0.003,
            verticalAngle: -0.003,
            timestamp: 0
        )

        #expect(translation == .zero)
    }

    @Test func projectionProvidesIndependentPortraitAxes() {
        let angle = 0.12
        let horizontal = StadiumParallaxAttitudeProjection.screenAngles(
            quaternion: CMQuaternion(x: 0, y: sin(angle / 2), z: 0, w: cos(angle / 2)),
            orientation: .portrait
        )
        let vertical = StadiumParallaxAttitudeProjection.screenAngles(
            quaternion: CMQuaternion(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2)),
            orientation: .portrait
        )

        #expect(abs(horizontal.horizontal - angle) < 0.0001)
        #expect(abs(horizontal.vertical) < 0.0001)
        #expect(abs(vertical.horizontal) < 0.0001)
        #expect(abs(vertical.vertical - angle) < 0.0001)
    }
}

private final class RecordingParallaxMotionBackend: StadiumParallaxMotionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedCallbacks: [@Sendable (CGSize) -> Void] = []

    var events: [String] { lock.withLock { recordedEvents } }
    var callbacks: [@Sendable (CGSize) -> Void] { lock.withLock { recordedCallbacks } }

    func record(_ event: String) {
        #expect(!Thread.isMainThread)
        lock.withLock { recordedEvents.append(event) }
    }

    func start(
        orientation: StadiumParallaxScreenOrientation,
        initialTranslation: CGSize,
        onTranslation: @escaping @Sendable (CGSize) -> Void
    ) {
        record("start:\(orientation):\(Int(initialTranslation.width))")
        lock.withLock { recordedCallbacks.append(onTranslation) }
    }

    func stop() { record("stop") }
}
