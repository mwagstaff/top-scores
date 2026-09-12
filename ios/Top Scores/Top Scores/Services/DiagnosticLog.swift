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
    DiagnosticLogWriter.queue.async {
        NSLog("%@", message)
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
    PerformanceDiagnosticLogWriter.logger.info("\(message, privacy: .public)")
    #endif
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
