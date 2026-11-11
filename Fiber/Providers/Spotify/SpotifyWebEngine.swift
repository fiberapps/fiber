import SwiftUI
import WebKit

/// Experimental embedded official Spotify SDK player. Never substitutes another audio source.
@Observable
final class SpotifyWebEngine: NSObject, PlaybackEngine, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = SpotifyWebEngine()
    let mode = PlaybackMode.inApp
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var isPresented = false
    var status = "Connect the browser player to start Spotify inside Fiber."
    @ObservationIgnored private var session: SpotifySession?
    @ObservationIgnored private var webView: WKWebView?
    private var deviceID: String?
    private var requested: Track?
    private var position = 0.0
    private var anchor = 0.0
    private var playing = false
    private var failure: String?
    private var generation = 0
    private var started = false
    private weak var hostContainer: UIView?
    var currentTime: TimeInterval { position + (playing ? ProcessInfo.processInfo.systemUptime - anchor : 0) }

    func configure(session: SpotifySession) { self.session = session }
    func prepare(_ track: Track) async throws -> TimeInterval {
        generation += 1
        let token = generation
        requested = track; position = 0; playing = false; started = false; failure = nil
        _ = browser()
        restoreHost()
        command("window.fiberActivate && window.fiberActivate(false)")
        var asked = false
        for step in 0..<450 {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if let failure { throw ProviderError.playback(failure) }
            if deviceID != nil {
                isPresented = false
                restoreHost()
                return track.duration
            }
            // The Web Playback SDK can only start from a tap inside its page.
            // Keep playing silent until that one tap has happened this launch.
            if step == 12 && deviceID == nil {
                isPresented = true
                asked = true
            }
            if asked && !isPresented && deviceID == nil && step > 18 {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProviderError.playback("Spotify's player inside Fiber didn't connect. Open Spotify in Fiber, tap Enable Audio, then try the song again.")
    }
    func play() throws {
        guard let session, let deviceID, let requested else { throw ProviderError.playback("Tap Enable Audio in Spotify inside Fiber, then try again.") }
        let token = generation
        restoreHost()
        command("player?.resume()")
        Task {
            do {
                try await session.send("PUT", "/me/player/play", query: ["device_id": deviceID], json: ["uris": ["spotify:track:\(requested.id.raw)"], "position_ms": Int(position * 1000)])
                command("player?.resume()")
            } catch {
                guard token == generation else { return }
                onFailure?(error.localizedDescription)
            }
        }
    }
    func pause() { position = currentTime; playing = false; command("player?.pause()") }
    func seek(to time: TimeInterval) { position = max(0, time); anchor = ProcessInfo.processInfo.systemUptime; command("player?.seek(\(Int(position * 1000)))") }
    func stop() { generation += 1; pause(); requested = nil; started = false }
    func disconnect() {
        stop(); command("player?.disconnect()"); deviceID = nil; session = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fiber")
        webView?.stopLoading(); webView = nil; isPresented = false
    }
    /// Keeps the player attached to a live view. iOS suspends a web player that
    /// is not in the window, which is what was sending sound out to the Spotify app.
    func attachHost(_ container: UIView) {
        hostContainer = container
        guard !isPresented else { return }
        place(browser(), in: container)
    }

    func restoreHost() {
        guard let hostContainer, !isPresented else { return }
        place(browser(), in: hostContainer)
    }

    private func place(_ view: WKWebView, in container: UIView) {
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
        }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func browser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "fiber")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        if let url = Bundle.main.url(forResource: "SpotifyPlayer", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    private func command(_ script: String) {
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            if let error { Task { @MainActor in self?.status = error.localizedDescription } }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "diagnostic":
            #if DEBUG
            if let data = try? JSONSerialization.data(withJSONObject: body),
               let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: folder.appendingPathComponent("spotify-web-diagnostic.json"))
            }
            #endif
        case "token":
            Task {
                do {
                    guard let session else { fail("Connect Spotify in Settings before enabling browser playback."); return }
                    let token = try await session.playbackToken()
                    guard self.session === session else { return }
                    let data = try JSONSerialization.data(withJSONObject: [token])
                    command("receiveToken(\(String(decoding: data, as: UTF8.self))[0])")
                } catch { fail(error.localizedDescription) }
            }
        case "ready":
            deviceID = body["device"] as? String
            status = "Spotify is playing inside Fiber."
            if requested != nil { isPresented = false; restoreHost() }
        case "notice":
            status = body["message"] as? String ?? status
        case "error": fail(body["message"] as? String ?? "Spotify playback inside Fiber failed.")
        case "state":
            guard let track = requested, let id = body["id"] as? String, id == track.id.raw else { return }
            let wasPlaying = playing
            position = (body["position"] as? Double ?? 0) / 1000
            anchor = ProcessInfo.processInfo.systemUptime
            playing = !(body["paused"] as? Bool ?? true)
            if playing { started = true }
            if wasPlaying != playing { onPlayingChanged?(playing) }
            if started, !playing, position >= track.duration - 1 { started = false; onFinish?() }
        default: break
        }
    }
    private func fail(_ message: String) {
        failure = message; status = message; deviceID = nil; playing = false
        onFailure?(message)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
}

struct SpotifyBrowserScreen: View {
    @Bindable var engine = SpotifyWebEngine.shared
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("This is Spotify's player inside Fiber. Tap Enable Audio once. After that, songs play here, including on the Lock Screen.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 12)
                Text(engine.status).font(.footnote).padding(.horizontal, 20).padding(.vertical, 8)
                SpotifyBrowserView(engine: engine)
            }
            .background(.black)
            .navigationTitle("Spotify in Fiber")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { engine.isPresented = false } } }
        }
        .preferredColorScheme(.dark)
        .onDisappear { engine.restoreHost() }
    }
}

/// Invisible home for the Spotify player so audio keeps running after the enable sheet closes.
struct SpotifyAudioHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        SpotifyWebEngine.shared.attachHost(container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        SpotifyWebEngine.shared.attachHost(uiView)
    }
}

private struct SpotifyBrowserView: UIViewRepresentable {
    let engine: SpotifyWebEngine
    func makeUIView(context: Context) -> WKWebView { engine.browser() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
