import Foundation
import Observation

@MainActor
@Observable
final class MatchCommentaryStore {
    private(set) var payload: MatchCommentaryPayload?
    private(set) var hasError = false
    private let fetch: (URL, String) async throws -> MatchCommentaryPayload

    init(fetch: @escaping (URL, String) async throws -> MatchCommentaryPayload = { baseURL, id in
        try await APIClient(baseURL: baseURL).fetchMatchCommentary(matchId: id)
    }) {
        self.fetch = fetch
    }

    // Owned by the view's .task: tab changes, backgrounding and navigation
    // cancel the request/sleep, and returning to the feed refreshes immediately.
    func follow(matchID: String, baseURL: URL) async {
        while !Task.isCancelled {
            let delay: Double?
            do {
                let result = try await fetch(baseURL, matchID)
                try Task.checkCancellation()
                payload = result
                hasError = false
                delay = result.refreshAfterSeconds
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                hasError = true
                delay = 30
            }
            guard let delay else { return }
            do { try await Task.sleep(for: .seconds(max(15, delay))) }
            catch { return }
        }
    }
}
