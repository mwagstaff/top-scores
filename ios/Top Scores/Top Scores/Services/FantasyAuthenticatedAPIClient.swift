import Foundation
import WebKit

@MainActor
struct FantasyAuthenticatedAPIClient {
    struct CurrentTeamResult {
        let entryID: Int
        let team: FantasyCurrentTeamResponse
    }

    func fetchCurrentTeam(entryID: Int) async throws -> CurrentTeamResult {
        let response = try await FantasyAuthenticatedWebRequest(entryID: entryID).start()

        do {
            let team = try JSONDecoder().decode(FantasyCurrentTeamResponse.self, from: response.data)
            return CurrentTeamResult(entryID: response.entryID, team: team)
        } catch {
            throw FantasyPublicAPIError.decodeFailed(
                operation: "fpl_current_team",
                underlying: error
            )
        }
    }
}

@MainActor
private final class FantasyAuthenticatedWebRequest: NSObject, WKNavigationDelegate {
    struct Response {
        let entryID: Int
        let data: Data
    }

    private let entryID: Int
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Response, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasRequestedTeam = false

    init(entryID: Int) {
        self.entryID = entryID
    }

    func start() async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(throwing: CancellationError())
                    return
                }

                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .default()

                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.navigationDelegate = self
                self.webView = webView

                guard let url = URL(string: "https://fantasy.premierleague.com/") else {
                    finish(throwing: FantasyPublicAPIError.invalidURL)
                    return
                }

                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.finish(throwing: URLError(.timedOut))
                }

                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(throwing: CancellationError())
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard !hasRequestedTeam else { return }
        hasRequestedTeam = true

        let script = """
        let resolvedEntryID = Number(requestedEntryID);
        const meResponse = await fetch('/api/me/', {
            cache: 'no-store',
            credentials: 'include'
        });

        if (meResponse.ok) {
            const me = await meResponse.json();
            const currentEntryID =
                me?.player?.entry ??
                me?.player?.entry_id ??
                me?.entry ??
                me?.entry_id;
            if (Number.isInteger(Number(currentEntryID)) && Number(currentEntryID) > 0) {
                resolvedEntryID = Number(currentEntryID);
            }
        } else if (meResponse.status === 401 || meResponse.status === 403) {
            return {
                status: meResponse.status,
                body: await meResponse.text(),
                entryID: resolvedEntryID
            };
        }

        const response = await fetch(`/api/my-team/${resolvedEntryID}/`, {
            cache: 'no-store',
            credentials: 'include'
        });
        return {
            status: response.status,
            body: await response.text(),
            entryID: resolvedEntryID
        };
        """

        webView.callAsyncJavaScript(
            script,
            arguments: ["requestedEntryID": NSNumber(value: entryID)],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            guard case let .success(value) = result else {
                if case let .failure(error) = result {
                    self.finish(throwing: error)
                }
                return
            }

            guard let payload = value as? [String: Any],
                  let status = (payload["status"] as? NSNumber)?.intValue,
                  let resolvedEntryID = (payload["entryID"] as? NSNumber)?.intValue,
                  let body = payload["body"] as? String,
                  let data = body.data(using: .utf8) else {
                self.finish(throwing: FantasyPublicAPIError.invalidHTTPResponse)
                return
            }

            if status == 401 || status == 403 {
                self.finish(throwing: FantasyPublicAPIError.authenticationRequired)
                return
            }

            guard (200...299).contains(status) else {
                self.finish(
                    throwing: FantasyPublicAPIError.badStatus(
                        status,
                        operation: "fpl_current_team",
                        snippet: String(body.prefix(240))
                    )
                )
                return
            }

            self.finish(returning: Response(entryID: resolvedEntryID, data: data))
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(throwing: error)
    }

    private func finish(returning response: Response) {
        guard let continuation else { return }
        cleanUp()
        continuation.resume(returning: response)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        cleanUp()
        continuation.resume(throwing: error)
    }

    private func cleanUp() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}
