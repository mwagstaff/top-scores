import Foundation
import MetricKit
import OSLog

private enum DiagnosticLogWriter {
    nonisolated static let queue = DispatchQueue(
        label: "dev.skynolimit.topscores.diagnostic-log",
        qos: .utility
    )
}

private enum PerformanceDiagnosticLogWriter {
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.skynolimit.topscores",
        category: "performance.interaction"
    )
}

nonisolated private final class PerformanceDiagnosticContext: @unchecked Sendable {
    struct Snapshot: Sendable {
        let sceneState: String
        let breadcrumbs: String
    }

    static let shared = PerformanceDiagnosticContext()

    private let lock = NSLock()
    private var sceneState = "launching"
    private var breadcrumbsByCategory: [String: String] = [:]

    private init() {}

    func setSceneState(_ state: String) {
        lock.withLock {
            sceneState = state
        }
    }

    func setBreadcrumb(category: String, value: String?) {
        lock.withLock {
            if let value {
                breadcrumbsByCategory[category] = value
            } else {
                breadcrumbsByCategory.removeValue(forKey: category)
            }
        }
    }

    func currentSceneState() -> String {
        lock.withLock { sceneState }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                sceneState: sceneState,
                breadcrumbs: breadcrumbsByCategory
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "|")
            )
        }
    }
}

/// Pings the main queue from a low-priority timer so stalls that happen before
/// a swipe's display-link monitor starts (or while it cannot render any frames)
/// still leave an attributable diagnostic trail.
nonisolated private final class MainRunLoopStallMonitor: @unchecked Sendable {
    static let shared = MainRunLoopStallMonitor()

    private struct OutstandingPing {
        let id: UInt64
        let sentAt: TimeInterval
        var hasReportedStall: Bool
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "dev.skynolimit.topscores.main-run-loop-watchdog",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var nextPingID = UInt64.zero
    private var outstandingPing: OutstandingPing?

    private init() {}

    func start() {
        let source: DispatchSourceTimer? = lock.withLock {
            guard timer == nil else { return nil }
            let source = DispatchSource.makeTimerSource(queue: queue)
            timer = source
            return source
        }
        guard let source else { return }
        source.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(50),
            leeway: .milliseconds(10)
        )
        source.setEventHandler { [weak self] in
            self?.sample()
        }
        source.resume()
    }

    private func sample() {
        guard PerformanceDiagnosticContext.shared.currentSceneState() == "active" else {
            lock.withLock {
                outstandingPing = nil
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        var pingToSend: (id: UInt64, sentAt: TimeInterval)?
        var stallDurationMilliseconds: Int?

        lock.withLock {
            if var outstandingPing {
                let duration = Int(((now - outstandingPing.sentAt) * 1_000).rounded())
                if duration >= 100, !outstandingPing.hasReportedStall {
                    outstandingPing.hasReportedStall = true
                    self.outstandingPing = outstandingPing
                    stallDurationMilliseconds = duration
                }
            } else {
                nextPingID &+= 1
                outstandingPing = OutstandingPing(
                    id: nextPingID,
                    sentAt: now,
                    hasReportedStall: false
                )
                pingToSend = (nextPingID, now)
            }
        }

        if let stallDurationMilliseconds {
            let context = PerformanceDiagnosticContext.shared.snapshot()
            let breadcrumbs = context.breadcrumbs.isEmpty ? "none" : context.breadcrumbs
            performanceDiagnosticLogAsync(
                "[MainRunLoop] stall_detected duration_ms=\(stallDurationMilliseconds) " +
                "scene=\(context.sceneState) breadcrumbs=\(breadcrumbs)"
            )
        }

        if let pingToSend {
            DispatchQueue.main.async { [weak self] in
                self?.acknowledge(pingToSend)
            }
        }
    }

    private func acknowledge(_ ping: (id: UInt64, sentAt: TimeInterval)) {
        let recoveredDurationMilliseconds: Int? = lock.withLock {
            guard let outstandingPing, outstandingPing.id == ping.id else { return nil }
            self.outstandingPing = nil
            guard outstandingPing.hasReportedStall else { return nil }
            return Int(
                ((ProcessInfo.processInfo.systemUptime - ping.sentAt) * 1_000).rounded()
            )
        }
        guard let recoveredDurationMilliseconds else { return }
        let context = PerformanceDiagnosticContext.shared.snapshot()
        let breadcrumbs = context.breadcrumbs.isEmpty ? "none" : context.breadcrumbs
        performanceDiagnosticLogAsync(
            "[MainRunLoop] stall_recovered duration_ms=\(recoveredDurationMilliseconds) " +
            "scene=\(context.sceneState) breadcrumbs=\(breadcrumbs)"
        )
    }
}

/// Keeps speculative background work away from latency-sensitive direct manipulation.
/// The counter supports overlapping interactions without allowing one completion to
/// release work that another interaction is still holding back.
nonisolated final class InteractiveMotionGate: @unchecked Sendable {
    static let shared = InteractiveMotionGate()

    private let lock = NSLock()
    private var activeInteractionCount = 0

    private init() {}

    func begin() {
        let count = lock.withLock {
            activeInteractionCount += 1
            return activeInteractionCount
        }
        diagnosticLogAsync("[InteractiveMotion] begin active=\(count)")
    }

    func end() {
        let count = lock.withLock {
            activeInteractionCount = max(0, activeInteractionCount - 1)
            return activeInteractionCount
        }
        diagnosticLogAsync("[InteractiveMotion] end active=\(count)")
    }

    var isActive: Bool {
        lock.withLock { activeInteractionCount > 0 }
    }

    func waitUntilIdle(operation: String) async -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        while lock.withLock({ activeInteractionCount > 0 }) {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled else { return false }
        let waitMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        )
        if waitMilliseconds >= 25 {
            diagnosticLogAsync(
                "[InteractiveMotion] resumed operation=\(operation) wait_ms=\(waitMilliseconds)"
            )
        }
        return true
    }

    /// Defers non-urgent work until direct manipulation has remained idle long
    /// enough that a short gap between consecutive swipes is not mistaken for
    /// the end of the interaction.
    func waitUntilSustainedIdle(
        operation: String,
        quietPeriodMilliseconds: Int = 750
    ) async -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var idleStartedAt: TimeInterval?

        while true {
            guard !Task.isCancelled else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if lock.withLock({ activeInteractionCount > 0 }) {
                idleStartedAt = nil
            } else if let idleStartedAt {
                if Int(((now - idleStartedAt) * 1_000).rounded()) >= quietPeriodMilliseconds {
                    break
                }
            } else {
                idleStartedAt = now
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let waitMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        )
        if waitMilliseconds >= quietPeriodMilliseconds + 25 {
            diagnosticLogAsync(
                "[InteractiveMotion] sustained_idle operation=\(operation) " +
                "wait_ms=\(waitMilliseconds) quiet_ms=\(quietPeriodMilliseconds)"
            )
        }
        return true
    }

    func waitUntilIdleBlocking(operation: String) {
        precondition(!Thread.isMainThread)
        let startedAt = ProcessInfo.processInfo.systemUptime
        while lock.withLock({ activeInteractionCount > 0 }) {
            Thread.sleep(forTimeInterval: 0.016)
        }
        let waitMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        )
        if waitMilliseconds >= 25 {
            diagnosticLogAsync(
                "[InteractiveMotion] resumed operation=\(operation) wait_ms=\(waitMilliseconds)"
            )
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

@inline(__always)
nonisolated func diagnosticPrint(_ item: @autoclosure () -> Any) {
    #if DEBUG
    print(item())
    #endif
}

@inline(__always)
nonisolated func diagnosticLogAsync(_ message: String) {
    #if DEBUG
    let enrichedMessage: String
    if message.contains("uptime_ms=") {
        enrichedMessage = message
    } else {
        let uptimeMilliseconds = UInt64(
            (ProcessInfo.processInfo.systemUptime * 1_000).rounded()
        )
        enrichedMessage = "\(message) uptime_ms=\(uptimeMilliseconds)"
    }
    DiagnosticLogWriter.queue.async {
        NSLog("%@", enrichedMessage)
    }
    #endif
}

/// Keeps the compact interaction summaries available in unified logging for
/// deployed builds, where a debugger and stdout are commonly unavailable.
@inline(__always)
nonisolated func performanceDiagnosticLogAsync(_ message: String) {
    #if DEBUG
    diagnosticLogAsync(message)
    #else
    let uptimeMilliseconds = UInt64(
        (ProcessInfo.processInfo.systemUptime * 1_000).rounded()
    )
    let enrichedMessage = "\(message) uptime_ms=\(uptimeMilliseconds)"
    PerformanceDiagnosticLogWriter.logger.info("\(enrichedMessage, privacy: .public)")
    #endif
}

nonisolated func performanceDiagnosticSetSceneState(_ state: String) {
    PerformanceDiagnosticContext.shared.setSceneState(state)
}

nonisolated func performanceDiagnosticSetBreadcrumb(
    category: String,
    value: String?
) {
    PerformanceDiagnosticContext.shared.setBreadcrumb(category: category, value: value)
}

final class AppDiagnosticsMonitor: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AppDiagnosticsMonitor()

    private let lock = NSLock()
    private var isStarted = false

    private override init() {
        super.init()
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()
        MXMetricManager.shared.add(self)
        MainRunLoopStallMonitor.shared.start()
        diagnosticLog("[AppDiagnostics] MetricKit crash and hang monitoring enabled")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics ?? []
            let hangs = payload.hangDiagnostics ?? []
            diagnosticLog(
                "[AppDiagnostics] diagnostic_payload crashes=%d hangs=%d period=%@...%@",
                crashes.count,
                hangs.count,
                String(describing: payload.timeStampBegin),
                String(describing: payload.timeStampEnd)
            )
            for crash in crashes {
                diagnosticLog(
                    "[AppDiagnostics] crash signal=%@ exception_type=%@ exception_code=%@ termination=%@",
                    crash.signal?.stringValue ?? "nil",
                    crash.exceptionType?.stringValue ?? "nil",
                    crash.exceptionCode?.stringValue ?? "nil",
                    crash.terminationReason ?? "nil"
                )
            }
            for hang in hangs {
                diagnosticLog(
                    "[AppDiagnostics] hang duration_ms=%d",
                    Int(hang.hangDuration.converted(to: .seconds).value * 1000)
                )
            }
            persist(payload)
        }
    }

    private func persist(_ payload: MXDiagnosticPayload) {
        let fileManager = FileManager.default
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = root
            .appendingPathComponent("TopScores", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("metrickit-\(UUID().uuidString).json")
            try payload.jsonRepresentation().write(to: fileURL, options: .atomic)
            diagnosticLog("[AppDiagnostics] diagnostic_payload_saved file=%@", fileURL.lastPathComponent)
        } catch {
            diagnosticLog("[AppDiagnostics] diagnostic_payload_save_failed error=%@", error.localizedDescription)
        }
    }
}
