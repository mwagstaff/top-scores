import SwiftUI
import WebKit

struct FantasySignInView: View {
    let onComplete: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("We’ll return to Top Scores automatically when your account is detected. If that does not happen, tap Done after signing in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                FantasySignInWebView { entryID in
                    dismiss()
                    onComplete(entryID)
                }
            }
            .navigationTitle("Sign in to FPL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onComplete(nil)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct FantasySignInWebView: UIViewRepresentable {
    let onAuthenticated: (Int) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        if let url = URL(string: "https://fantasy.premierleague.com/") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startDetection(webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopDetection()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: (Int) -> Void
        private let authenticatedClient = FantasyAuthenticatedAPIClient()
        private var hasAuthenticated = false
        private var hasCapturedSession = false
        private var detectionTask: Task<Void, Never>?
        private weak var webView: WKWebView?

        init(onAuthenticated: @escaping (Int) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func startDetection(webView: WKWebView) {
            guard detectionTask == nil else { return }
            self.webView = webView
            detectionTask = Task { [weak self] in
                defer { self?.detectionTask = nil }
                while !Task.isCancelled {
                    guard let self, !hasAuthenticated else { return }
                    if !hasCapturedSession,
                       let sessionJSON = try? await oidcSessionJSON(),
                       sessionJSON.isEmpty == false,
                       (try? FantasyAuthSessionStore.saveOIDCSessionJSON(sessionJSON)) != nil {
                        hasCapturedSession = true
                        #if DEBUG
                        diagnosticPrint("[FantasySignIn] oidc_session_captured")
                        #endif
                    }
                    do {
                        let entryID = try await authenticatedClient.detectSignedInEntryID()
                        hasAuthenticated = true
                        #if DEBUG
                        diagnosticPrint("[FantasySignIn] account_detected entry_id=\(entryID)")
                        #endif
                        onAuthenticated(entryID)
                        return
                    } catch let error as FantasyPublicAPIError {
                        if case .authenticationRequired = error {
                            hasCapturedSession = false
                        }
                    } catch {
                        // A transient web or network error is retried while the
                        // sign-in sheet remains visible.
                    }
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
        }

        func stopDetection() {
            detectionTask?.cancel()
            detectionTask = nil
            webView = nil
        }

        private func oidcSessionJSON() async throws -> String? {
            guard let webView else { return nil }
            let script = """
            (() => {
                const clientID = 'bfcbaf69-aade-4c1b-8f00-c1cb8a193030';
                const key = Object.keys(window.localStorage).find(candidate =>
                    candidate.startsWith('oidc.user:') && candidate.includes(clientID)
                );
                return key ? window.localStorage.getItem(key) : null;
            })();
            """
            return try await webView.evaluateJavaScript(script) as? String
        }
    }
}
