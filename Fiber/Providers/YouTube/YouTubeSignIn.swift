import SwiftUI
import WebKit

/// Google's own YouTube Music sign-in page. Fiber reads the session cookie
/// after the account is signed in and then plays through its own audio engine.
struct YouTubeSignInScreen: View {
    let provider: YouTubeProvider

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sign in with the Google account that holds your YouTube Music library. When the library appears, Fiber keeps the session and plays songs itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                YouTubeSignInWebView { header, account in
                    provider.completeSignIn(cookieHeader: header, account: account)
                }
            }
            .background(.black)
            .navigationTitle("YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { provider.cancelSignIn() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct YouTubeSignInWebView: UIViewRepresentable {
    var onSession: (String, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSession: onSession) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        view.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSession: (String, String?) -> Void
        private var delivered = false

        init(onSession: @escaping (String, String?) -> Void) { self.onSession = onSession }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self, !self.delivered, let header = Self.cookieHeader(from: cookies) else { return }
                webView?.evaluateJavaScript(
                    "document.querySelector('button[aria-label], a[aria-label]')?.getAttribute('aria-label') || ''"
                ) { value, _ in
                    guard !self.delivered else { return }
                    self.delivered = true
                    let label = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = (label?.isEmpty == false) ? label : nil
                    Task { @MainActor in self.onSession(header, account) }
                }
            }
        }

        nonisolated static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
            let relevant = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain.contains("youtube.com") || domain.contains("google.com")
            }
            let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard YouTubeAuth.sapisid(in: header) != nil else { return nil }
            let signedIn = relevant.contains { ["LOGIN_INFO", "SID", "__Secure-1PSID", "__Secure-3PSID"].contains($0.name) }
            return signedIn ? header : nil
        }
    }
}
