import Foundation

#if DEBUG
import UIKit
#endif

/// Records loading milestones and main-queue responsiveness without publishing view state.
@MainActor
final class MatchDetailLoadDiagnostics {
    #if DEBUG
    private var session: MatchDetailLoadDiagnosticSession?
    #endif

    func start(matchID: String) {
        #if DEBUG
        stop()
        session = MatchDetailLoadDiagnosticSession(matchID: matchID)
        #endif
    }

    func mark(stage: String) {
        #if DEBUG
        session?.mark(stage: stage)
        #endif
    }

    func stop() {
        #if DEBUG
        session?.stop()
        session = nil
        #endif
    }
}

#if DEBUG
/// Pure timing state, driven by the timer's monotonic clock and protected by the session lock.
nonisolated struct MatchDetailResponsivenessState {
    struct Sample {
        var backgroundTimerGap: UInt64?
        var mainStillBlocked: UInt64?
        var enqueuePing = false
        var samplingComplete = false
    }

    static let samplingDuration: UInt64 = 15_000_000_000
    private let startedAt: UInt64
    private var lastSampleAt: UInt64
    private var pingQueuedAt: UInt64?
    private var lastHeartbeatAt: UInt64?
    private(set) var isActive = true
    private var samplingComplete = false

    init(startedAt: UInt64) {
        self.startedAt = startedAt
        lastSampleAt = startedAt
    }

    mutating func sample(at now: UInt64) -> Sample? {
        guard isActive, !samplingComplete else { return nil }
        var sample = Sample()
        let gap = now - lastSampleAt
        if gap >= 250_000_000 { sample.backgroundTimerGap = gap }
        lastSampleAt = now

        if let pingQueuedAt, let lastHeartbeatAt, now - lastHeartbeatAt >= 500_000_000 {
            sample.mainStillBlocked = now - pingQueuedAt
            self.lastHeartbeatAt = now
        }
        if now - startedAt >= Self.samplingDuration {
            samplingComplete = true
            sample.samplingComplete = true
        } else if pingQueuedAt == nil {
            pingQueuedAt = now
            lastHeartbeatAt = now
            sample.enqueuePing = true
        }
        return sample
    }

    mutating func acknowledgePing() -> Bool {
        guard isActive, pingQueuedAt != nil else { return false }
        pingQueuedAt = nil
        lastHeartbeatAt = nil
        return true
    }

    mutating func stop() -> Bool {
        let wasActive = isActive
        isActive = false
        pingQueuedAt = nil
        lastHeartbeatAt = nil
        return wasActive
    }
}

/// Mutable state is protected by the lock; timer callbacks never wait for the main queue.
private nonisolated final class MatchDetailLoadDiagnosticSession: @unchecked Sendable {
    private let id = UUID().uuidString
    private let matchID: String
    private let startedAt: UInt64
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var responsiveness: MatchDetailResponsivenessState
    private var pendingQueuedStage = "appeared"
    private var stage = "appeared"

    init(matchID: String) {
        self.matchID = matchID
        startedAt = DispatchTime.now().uptimeNanoseconds
        responsiveness = MatchDetailResponsivenessState(startedAt: startedAt)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "dev.skynolimit.topscores.match-detail-load",
            qos: .userInitiated
        ))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        log(stage: stage, detail: " sampling_window_ms=\(MatchDetailResponsivenessState.samplingDuration / 1_000_000)")
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    func mark(stage: String) {
        lock.lock()
        guard responsiveness.isActive else {
            lock.unlock()
            return
        }
        self.stage = stage
        lock.unlock()
        log(stage: stage)
    }

    func stop() {
        lock.lock()
        let wasActive = responsiveness.stop()
        lock.unlock()
        timer.cancel()
        if wasActive { log(stage: "stopped") }
    }

    private func sample() {
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard let sample = responsiveness.sample(at: queuedAt) else {
            lock.unlock()
            return
        }
        let queuedStage = stage
        if sample.enqueuePing { pendingQueuedStage = queuedStage }
        let pendingStage = pendingQueuedStage
        lock.unlock()

        if let gap = sample.backgroundTimerGap {
            log(stage: queuedStage, detail: " background_timer_gap_ms=\(gap / 1_000_000)", at: queuedAt)
        }
        if let delay = sample.mainStillBlocked {
            log(stage: queuedStage, detail: " main_still_blocked_ms=\(delay / 1_000_000) queued_stage=\(pendingStage)", at: queuedAt)
        }
        if sample.samplingComplete {
            timer.cancel()
            log(stage: "sampling_complete", at: queuedAt)
        }
        guard sample.enqueuePing else { return }

        DispatchQueue.main.async { [weak self] in
            // Lifecycle delivery can itself be delayed, so also check the app here.
            self?.acknowledgePing(
                queuedAt: queuedAt,
                queuedStage: queuedStage,
                isAppActive: UIApplication.shared.applicationState == .active
            )
        }
    }

    private func acknowledgePing(queuedAt: UInt64, queuedStage: String, isAppActive: Bool) {
        let acknowledgedAt = DispatchTime.now().uptimeNanoseconds
        let delay = acknowledgedAt - queuedAt
        lock.lock()
        let shouldLog = responsiveness.acknowledgePing() && isAppActive && delay >= 250_000_000
        let currentStage = stage
        lock.unlock()
        if shouldLog {
            log(stage: currentStage, detail: " main_queue_delay_ms=\(delay / 1_000_000) queued_stage=\(queuedStage)", at: acknowledgedAt)
        }
    }

    private func log(stage: String, detail: String = "", at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let elapsed = (now - startedAt) / 1_000_000
        diagnosticLogAsync(
            "[MatchDetailLoad] session=\(id) match=\(matchID) stage=\(stage) elapsed_ms=\(elapsed) uptime_ms=\(now / 1_000_000)\(detail)"
        )
    }
}
#endif
