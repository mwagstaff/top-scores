import Foundation
import MetricKit

private enum DiagnosticLogWriter {
    nonisolated static let queue = DispatchQueue(
        label: "dev.skynolimit.topscores.diagnostic-log",
        qos: .utility
    )
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
