import Combine
import Foundation

@MainActor
final class WatchCompetitionRefreshStore: ObservableObject {
    @Published private(set) var matches: [WatchMatch]?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let fetch: (String, URL) async throws -> [WatchMatch]
    private var requestID = UUID()

    init(fetch: @escaping (String, URL) async throws -> [WatchMatch] = { date, baseURL in
        #if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["LIVE_ACTIVITY_MATCHES_JSON"] {
            return try JSONDecoder().decode([WatchMatch].self, from: Data(fixture.utf8))
        }
        #endif
        return try await WatchAPIClient(baseURL: baseURL).fetchMatches(on: date)
    }) {
        self.fetch = fetch
    }

    func run(date: String, baseURL: URL) async {
        while !Task.isCancelled {
            await refresh(date: date, baseURL: baseURL)
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func refresh(date: String, baseURL: URL) async {
        let id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let updated = try await fetch(date, baseURL)
            try Task.checkCancellation()
            guard requestID == id else { return }
            matches = updated
            loadError = nil
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            loadError = "Couldn’t update matches. Pull down to retry."
            diagnosticLog("Watch competition refresh failed: %@", error.localizedDescription)
        }
    }
}
