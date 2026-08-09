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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: (Int) -> Void
        private var hasAuthenticated = false

        init(onAuthenticated: @escaping (Int) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard !hasAuthenticated else { return }

            let script = """
            const response = await fetch('/api/me/', {
                cache: 'no-store',
                credentials: 'include'
            });
            if (!response.ok) {
                return null;
            }
            const account = await response.json();
            const entryID = account?.player?.entry ?? account?.player?.entry_id ?? account?.entry ?? account?.entry_id;
            return Number.isInteger(Number(entryID)) && Number(entryID) > 0 ? Number(entryID) : null;
            """

            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self,
                      !self.hasAuthenticated,
                      case let .success(value) = result,
                      let entryID = (value as? NSNumber)?.intValue,
                      entryID > 0 else {
                    return
                }
                self.hasAuthenticated = true
                self.onAuthenticated(entryID)
            }
        }
    }
}
