import Combine
import CoreMotion
import SwiftUI
import UIKit

nonisolated struct StadiumParallaxFilter {
    static let maximumHorizontalTranslation: CGFloat = 24
    static let maximumVerticalTranslation: CGFloat = 20

    private static let maximumAngle = 0.24
    private static let deadZone = 0.006
    private static let dampingTimeConstant = 0.18

    private(set) var translation = CGSize.zero
    private var lastTimestamp: TimeInterval?

    init(translation: CGSize = .zero) {
        self.translation = translation
    }

    mutating func update(
        horizontalAngle: Double,
        verticalAngle: Double,
        timestamp: TimeInterval
    ) -> CGSize {
        let target = CGSize(
            width: -normalized(horizontalAngle) * Self.maximumHorizontalTranslation,
            height: -normalized(verticalAngle) * Self.maximumVerticalTranslation
        )
        let elapsed = lastTimestamp.map { min(max(timestamp - $0, 1.0 / 240.0), 0.1) } ?? 1.0 / 60.0
        let response = 1 - exp(-elapsed / Self.dampingTimeConstant)
        translation.width += (target.width - translation.width) * response
        translation.height += (target.height - translation.height) * response
        lastTimestamp = timestamp
        return translation
    }

    private func normalized(_ angle: Double) -> CGFloat {
        let magnitude = abs(angle)
        guard magnitude > Self.deadZone else { return 0 }
        let adjusted = min((magnitude - Self.deadZone) / (Self.maximumAngle - Self.deadZone), 1)
        return CGFloat(angle.sign == .minus ? -adjusted : adjusted)
    }
}

nonisolated enum StadiumParallaxScreenOrientation: Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }
}

nonisolated struct StadiumParallaxAttitudeProjection {
    static func screenAngles(
        quaternion: CMQuaternion,
        orientation: StadiumParallaxScreenOrientation
    ) -> (horizontal: Double, vertical: Double) {
        let sign = quaternion.w < 0 ? -1.0 : 1.0
        let x = quaternion.x * sign
        let y = quaternion.y * sign
        let z = quaternion.z * sign
        let w = quaternion.w * sign
        let vectorMagnitude = sqrt((x * x) + (y * y) + (z * z))
        let angleScale = vectorMagnitude > 1e-8
            ? 2 * atan2(vectorMagnitude, w) / vectorMagnitude
            : 2
        let rotationX = x * angleScale
        let rotationY = y * angleScale

        switch orientation {
        case .portrait:
            return (rotationY, rotationX)
        case .portraitUpsideDown:
            return (-rotationY, -rotationX)
        case .landscapeLeft:
            return (-rotationX, rotationY)
        case .landscapeRight:
            return (rotationX, -rotationY)
        }
    }
}

private nonisolated final class StadiumParallaxMotionProcessor: @unchecked Sendable {
    private let orientation: StadiumParallaxScreenOrientation
    private var referenceAttitude: CMAttitude?
    private var filter: StadiumParallaxFilter

    init(orientation: StadiumParallaxScreenOrientation, initialTranslation: CGSize) {
        self.orientation = orientation
        filter = StadiumParallaxFilter(translation: initialTranslation)
    }

    func translation(for motion: CMDeviceMotion) -> CGSize? {
        guard let relativeAttitude = motion.attitude.copy() as? CMAttitude else { return nil }
        if referenceAttitude == nil {
            referenceAttitude = motion.attitude.copy() as? CMAttitude
        }
        guard let referenceAttitude else { return nil }
        relativeAttitude.multiply(byInverseOf: referenceAttitude)

        let angles = StadiumParallaxAttitudeProjection.screenAngles(
            quaternion: relativeAttitude.quaternion,
            orientation: orientation
        )
        return filter.update(
            horizontalAngle: angles.horizontal,
            verticalAngle: angles.vertical,
            timestamp: motion.timestamp
        )
    }
}

nonisolated protocol StadiumParallaxMotionBackend: AnyObject, Sendable {
    func start(
        orientation: StadiumParallaxScreenOrientation,
        initialTranslation: CGSize,
        onTranslation: @escaping @Sendable (CGSize) -> Void
    )
    func stop()
}

/// The serial queue owns the backend, including its first initialization and shutdown.
nonisolated final class StadiumParallaxMotionDriver: @unchecked Sendable {
    private let queue: DispatchQueue
    private let makeBackend: @Sendable () -> any StadiumParallaxMotionBackend
    private var backend: (any StadiumParallaxMotionBackend)?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "dev.skynolimit.top-scores.stadium-parallax-control",
            qos: .userInitiated
        ),
        makeBackend: @escaping @Sendable () -> any StadiumParallaxMotionBackend = {
            CoreMotionStadiumParallaxBackend()
        }
    ) {
        self.queue = queue
        self.makeBackend = makeBackend
    }

    deinit {
        let backend = backend
        queue.async { backend?.stop() }
    }

    func start(
        orientation: StadiumParallaxScreenOrientation,
        initialTranslation: CGSize,
        onTranslation: @escaping @Sendable (CGSize) -> Void
    ) {
        queue.async { [self] in
            if backend == nil { backend = makeBackend() }
            backend?.start(
                orientation: orientation,
                initialTranslation: initialTranslation,
                onTranslation: onTranslation
            )
        }
    }

    func stop() {
        queue.async { [self] in backend?.stop() }
    }
}

private nonisolated final class CoreMotionStadiumParallaxBackend: StadiumParallaxMotionBackend, @unchecked Sendable {
    private let motionManager: CMMotionManager
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.skynolimit.top-scores.stadium-parallax-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    init() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        motionManager = CMMotionManager()
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        log(stage: "initialize", startedAt: startedAt)
    }

    func start(
        orientation: StadiumParallaxScreenOrientation,
        initialTranslation: CGSize,
        onTranslation: @escaping @Sendable (CGSize) -> Void
    ) {
        let availabilityStartedAt = DispatchTime.now().uptimeNanoseconds
        let isAvailable = motionManager.isDeviceMotionAvailable
            && CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical)
        log(stage: isAvailable ? "available" : "unavailable", startedAt: availabilityStartedAt)
        guard isAvailable else { return }

        let processor = StadiumParallaxMotionProcessor(
            orientation: orientation,
            initialTranslation: initialTranslation
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { motion, _ in
            guard let motion, let nextTranslation = processor.translation(for: motion) else { return }
            onTranslation(nextTranslation)
        }
        log(stage: "start", startedAt: startedAt)
    }

    func stop() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        motionManager.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        log(stage: "stop", startedAt: startedAt)
    }

    private func log(stage: String, startedAt: UInt64) {
        #if DEBUG
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = (now - startedAt) / 1_000_000
        diagnosticLogAsync("[StadiumParallaxMotion] stage=\(stage) duration_ms=\(elapsed) uptime_ms=\(now / 1_000_000) main_thread=\(Thread.isMainThread)")
        #endif
    }
}

@MainActor
final class StadiumParallaxMotionModel: ObservableObject {
    static let shared = StadiumParallaxMotionModel()

    @Published private(set) var translation = CGSize.zero

    private let driver: StadiumParallaxMotionDriver
    private var activeViews: Set<UUID> = []
    private var orientation: UIInterfaceOrientation = .portrait
    private var generation = UUID()

    init(driver: StadiumParallaxMotionDriver = StadiumParallaxMotionDriver()) {
        self.driver = driver
    }

    func activate(viewID: UUID, orientation: UIInterfaceOrientation) {
        let wasInactive = activeViews.isEmpty
        activeViews.insert(viewID)
        if self.orientation != orientation {
            self.orientation = orientation
            if !wasInactive {
                restartUpdates()
                return
            }
        }
        if wasInactive {
            startUpdates()
        }
    }

    func deactivate(viewID: UUID) {
        activeViews.remove(viewID)
        guard activeViews.isEmpty else { return }
        stopUpdates()
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard self.orientation != orientation else { return }
        self.orientation = orientation
        guard !activeViews.isEmpty else { return }
        restartUpdates()
    }

    private func restartUpdates() {
        stopUpdates(centresImage: false)
        startUpdates()
    }

    private func startUpdates() {
        generation = UUID()
        let currentGeneration = generation
        driver.start(
            orientation: StadiumParallaxScreenOrientation(orientation),
            initialTranslation: translation
        ) { [weak self] nextTranslation in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.translation = nextTranslation
            }
        }
    }

    private func stopUpdates(centresImage: Bool = true) {
        generation = UUID()
        driver.stop()
        guard centresImage else { return }
        withAnimation(.easeOut(duration: 0.45)) {
            translation = .zero
        }
    }
}

private struct StadiumParallaxMotionLifecycleModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = StadiumParallaxMotionModel.shared
    @State private var isVisible = false
    @State private var viewID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateMotionActivity()
            }
            .onDisappear {
                isVisible = false
                updateMotionActivity()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateMotionActivity()
            }
            .onChange(of: scenePhase) { _, _ in
                updateMotionActivity()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                guard motionIsEnabled else { return }
                motion.updateOrientation(currentInterfaceOrientation)
            }
    }

    private var motionIsEnabled: Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
    }

    private func updateMotionActivity() {
        if motionIsEnabled {
            motion.activate(viewID: viewID, orientation: currentInterfaceOrientation)
        } else {
            motion.deactivate(viewID: viewID)
        }
    }
}

extension View {
    func stadiumParallaxMotionLifecycle() -> some View {
        modifier(StadiumParallaxMotionLifecycleModifier())
    }
}
