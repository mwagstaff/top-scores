import Foundation
import Testing
@testable import Top_Scores

struct AppAudienceTests {
    @Test func foregroundSessionsIgnoreInterruptionsAndSeparateBackgroundReturns() {
        let context = AppActivityContext()
        #expect(context.snapshot.state == "background")
        #expect(context.update(active: true, background: false))
        #expect(!context.update(active: true, background: false))
        #expect(!context.update(active: false, background: false))
        #expect(!context.update(active: true, background: false))
        #expect(!context.update(active: false, background: true))
        #expect(context.snapshot.state == "background")
        #expect(context.update(active: true, background: false))
    }

    @Test func retryPreservesEventIdentityAndClearsDurableQueueAfterAcknowledgement() async throws {
        let suite = "AppAudienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudienceURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var service = AppMetricsService(defaults: defaults, session: session)
        let context = AppActivityContext.Snapshot(state: "foreground")
        await service.enqueue(event: "app_open", screen: nil, durationMs: nil,
                              apiBaseURL: "https://analytics-test.invalid/api/v1", context: context, recordedAt: Date())
        let queued = try #require(defaults.data(forKey: "analytics.pendingEvents.v2"))
        let first = try #require((JSONSerialization.jsonObject(with: queued) as? [[String: Any]])?.first)
        let firstEncoded = try #require(first["body"] as? String)
        let firstBody = try #require(Data(base64Encoded: firstEncoded))
        let firstPayload = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        let id = try #require(firstPayload["eventId"] as? String)
        #expect(firstPayload["state"] as? String == "foreground")
        // Recreating the service loads its durable queue and preserves the original event ID.
        service = AppMetricsService(defaults: defaults, session: session)
        await service.enqueue(event: "screen_view", screen: "tables", durationMs: 30,
                              apiBaseURL: "https://analytics-test.invalid/api/v1", context: context, recordedAt: Date())
        let afterRetry = try #require(defaults.data(forKey: "analytics.pendingEvents.v2"))
        let remaining = try #require(JSONSerialization.jsonObject(with: afterRetry) as? [[String: Any]])
        #expect(remaining.count == 1)
        let encoded = try #require(remaining[0]["body"] as? String)
        let body = try #require(Data(base64Encoded: encoded))
        let nextPayload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(nextPayload["eventId"] as? String != id)
        #expect(nextPayload["event"] as? String == "screen_view")
    }
}

private nonisolated final class AudienceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let seen = SeenEvents()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let id = payload?["eventId"] as? String ?? "missing"
        let status = Self.seen.insert(id) ? 503 : 202
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private final class SeenEvents: @unchecked Sendable {
        let lock = NSLock()
        var ids = Set<String>()
        func insert(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
    }
}
