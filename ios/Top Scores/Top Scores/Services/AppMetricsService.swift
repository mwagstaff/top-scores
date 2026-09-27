import Foundation
import UIKit
import Darwin

actor AppMetricsService {
    static let shared = AppMetricsService()

    private nonisolated struct PendingEvent: Codable, Sendable {
        let body: Data
        let endpoint: URL
        let recordedAt: Date
    }
    private static let queueKey = "analytics.pendingEvents.v2"
    private var pending: [PendingEvent]
    private var flushing = false
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 5
    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        pending = defaults.data(forKey: Self.queueKey)
            .flatMap { try? JSONDecoder().decode([PendingEvent].self, from: $0) } ?? []
    }

    nonisolated func fireScreenView(screen: String, durationMs: Int? = nil, apiBaseURL: String) {
        fireActivity("screen_view", screen: screen, durationMs: durationMs, apiBaseURL: apiBaseURL)
    }

    nonisolated func fireActivity(_ activity: String, screen: String? = nil, durationMs: Int? = nil, apiBaseURL: String) {
        let context = DeviceIdentity.activity.snapshot
        let recordedAt = Date()
        // Preloading or background refreshes are not feature visits.
        guard context.state == "foreground" else { return }
        Task(priority: .utility) {
            await enqueue(event: activity, screen: screen, durationMs: durationMs,
                          apiBaseURL: apiBaseURL, context: context, recordedAt: recordedAt)
        }
    }

    func enqueue(event: String, screen: String?, durationMs: Int?, apiBaseURL: String,
                         context: AppActivityContext.Snapshot, recordedAt: Date) async {
        guard let baseURL = URL(string: apiBaseURL),
              ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else { return }
        var payload = await buildPayload(event: event, screen: screen, durationMs: durationMs)
        payload["schemaVersion"] = 2
        payload["eventId"] = UUID().uuidString
        payload["surface"] = "ios_app"
        payload["state"] = context.state
        payload["recordedAt"] = ISO8601DateFormatter().string(from: recordedAt)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        pending.removeAll { Date().timeIntervalSince($0.recordedAt) > 48 * 3600 }
        if pending.count >= 200 { pending.removeFirst(pending.count - 199) }
        pending.append(PendingEvent(body: body, endpoint: baseURL.appendingPathComponent("app-metrics"), recordedAt: recordedAt))
        persist()
        await flush()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Self.queueKey)
        }
    }

    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        retryTask?.cancel()
        retryTask = nil
        pending.removeAll { Date().timeIntervalSince($0.recordedAt) > 48 * 3600 }
        while let item = pending.first {
            guard !Task.isCancelled else { persist(); return }
            var request = URLRequest(url: item.endpoint)
            request.httpMethod = "POST"
            request.httpBody = item.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            DeviceIdentity.applyHeader(to: &request)
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 429 || http.statusCode >= 500 {
                    if let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(UInt64.init) {
                        retryDelay = min(300, max(retryDelay, seconds))
                    }
                    throw URLError(.resourceUnavailable)
                }
                // Terminal validation failures are discarded; retries preserve the event ID.
                guard (200...299).contains(http.statusCode) || (400...499).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                // Enqueues can run while networking is suspended; remove this exact event.
                if let index = pending.firstIndex(where: { $0.body == item.body }) { pending.remove(at: index) }
                retryDelay = 5
                persist()
            } catch {
                persist()
                if Task.isCancelled { return }
                let delay = retryDelay
                retryDelay = min(300, retryDelay * 2)
                retryTask = Task(priority: .utility) { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    await self?.retryPending()
                }
                return
            }
        }
        persist()
    }

    private func retryPending() async {
        retryTask = nil
        await flush()
    }

    private func buildPayload(event: String, screen: String?, durationMs: Int?) async -> [String: Any] {
        await MainActor.run {
            let device = UIDevice.current
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let buildType: String
            #if DEBUG
            buildType = "debug"
            #else
            buildType = "production"
            #endif

            var payload: [String: Any] = [
                "event": event,
                "platform": device.systemName,
                "osVersion": device.systemVersion,
                "deviceType": Self.idiomName(device.userInterfaceIdiom),
                "deviceModel": Self.resolvedModelName(),
                "appVersion": version,
                "buildNumber": build,
                "buildType": buildType,
                "locale": Locale.current.identifier,
                "timezone": TimeZone.current.identifier,
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if let screen {
                payload["screen"] = screen
            }
            if let durationMs {
                payload["durationMs"] = durationMs
            }
            return payload
        }
    }

    private static func idiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone:
            return "phone"
        case .pad:
            return "pad"
        case .tv:
            return "tv"
        case .mac:
            return "mac"
        case .vision:
            return "vision"
        default:
            return "unspecified"
        }
    }

    /// Returns the human-readable device model name (e.g. "iPhone 16 Pro Max").
    /// Falls back to the raw hardware identifier (e.g. "iPhone17,2") for unrecognised models.
    private static func resolvedModelName() -> String {
        let identifier = hardwareIdentifier()
        return modelNames[identifier] ?? identifier
    }

    private static func hardwareIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawPtr in
            let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        #endif
    }

    // swiftlint:disable:next large_tuple
    private static let modelNames: [String: String] = [
        // iPhone 12
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        // iPhone SE
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
        // iPhone 14
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        // iPad mini
        "iPad11,1": "iPad mini 5",
        "iPad11,2": "iPad mini 5",
        "iPad14,1": "iPad mini 6",
        "iPad14,2": "iPad mini 6",
        "iPad14,7": "iPad mini 7",
        "iPad14,8": "iPad mini 7",
        // iPad Air
        "iPad13,16": "iPad Air 5",
        "iPad13,17": "iPad Air 5",
        "iPad14,9":  "iPad Air M2 11\"",
        "iPad14,10": "iPad Air M2 11\"",
        "iPad14,11": "iPad Air M2 13\"",
        "iPad14,12": "iPad Air M2 13\"",
        // iPad Pro
        "iPad14,3":  "iPad Pro 11\" M2",
        "iPad14,4":  "iPad Pro 11\" M2",
        "iPad14,5":  "iPad Pro 12.9\" M2",
        "iPad14,6":  "iPad Pro 12.9\" M2",
        "iPad16,3":  "iPad Pro 11\" M4",
        "iPad16,4":  "iPad Pro 11\" M4",
        "iPad16,5":  "iPad Pro 13\" M4",
        "iPad16,6":  "iPad Pro 13\" M4",
        // iPad
        "iPad13,18": "iPad 10",
        "iPad13,19": "iPad 10",
    ]
}
