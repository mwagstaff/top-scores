import Foundation
import OSLog

enum WatchPerformanceDiagnostics {
    static let subsystem = "dev.skynolimit.topscores.watch"
    static let logger = Logger(subsystem: subsystem, category: "Performance")
    static let signposter = OSSignposter(logger: logger)

    static func milliseconds(since start: DispatchTime) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Int(elapsed / 1_000_000)
    }
}

@MainActor
final class WatchMainThreadStallMonitor {
    static let shared = WatchMainThreadStallMonitor()

    private let sampleIntervalNanoseconds: UInt64 = 1_000_000_000
    private let stallThresholdNanoseconds: UInt64 = 200_000_000
    private var generation = 0
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        WatchPerformanceDiagnostics.logger.notice("Main-thread stall monitor started")
        scheduleSample(generation: generation)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        WatchPerformanceDiagnostics.logger.notice("Main-thread stall monitor stopped")
    }

    private func scheduleSample(generation: Int) {
        let expected = DispatchTime.now().uptimeNanoseconds + sampleIntervalNanoseconds
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(sampleIntervalNanoseconds))) { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let delay = now > expected ? now - expected : 0
            if delay >= self.stallThresholdNanoseconds {
                WatchPerformanceDiagnostics.logger.error(
                    "Main-thread stall detected: \(Int(delay / 1_000_000), privacy: .public) ms"
                )
            }
            self.scheduleSample(generation: generation)
        }
    }
}

@inline(__always)
nonisolated func diagnosticLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

@inline(__always)
nonisolated func diagnosticLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #endif
}
