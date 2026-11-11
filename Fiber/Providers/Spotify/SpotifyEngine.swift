import Foundation
import UIKit

/// Plays Spotify songs by remote-controlling the Spotify app over the Web API
/// (Spotify Connect). Spotify makes the sound; this engine tells it which song
/// to play and keeps a clock that follows Spotify's reported position, so the
/// lyrics stay in step.
///
/// Fiber keeps the queue and sends one song at a time. While Fiber is in the
/// background (iOS suspends it) the song in Spotify plays to its end, and the
/// queue moves on when Fiber is opened again.
final class SpotifyEngine: PlaybackEngine {
    enum Phase: Equatable {
        /// Nothing prepared.
        case idle
        /// A song is chosen and Spotify hasn't been told yet.
        case ready
        /// The play command is on its way; the clock waits for Spotify to confirm.
        case loading
        case playing
        case paused
    }

    private(set) var phase = Phase.idle
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?

    private let session: SpotifySession
    private let now: () -> TimeInterval
    private let openApp: @MainActor (URL) async -> Bool

    private var track: Track?
    private var duration: TimeInterval = 0
    /// Seconds into the song at `anchor`.
    private var position: TimeInterval = 0
    private var anchor: TimeInterval = 0
    private var device: SpotifyDevice?
    /// True while Spotify isn't known to hold the prepared song, so the next play must send it again.
    private var needsLoad = true
    /// Bumped by every command that makes older queued work obsolete.
    private var generation = 0
    private var lastCommand: TimeInterval = 0
    private var loadStarted: TimeInterval = 0
    /// True while waiting for the Spotify app to show up as a device after a play command found it gone.
    private var isSearching = false
    private var tail: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    init(session: SpotifySession,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         openApp: @escaping @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }) {
        self.session = session
        self.now = now
        self.openApp = openApp
    }

    var mode: PlaybackMode { .remote(device: device?.name) }

    var currentTime: TimeInterval {
        guard phase == .playing else { return position }
        let elapsed = position + (now() - anchor)
        return duration > 0 ? min(elapsed, duration) : elapsed
    }

    // MARK: PlaybackEngine

    func prepare(_ track: Track) async throws -> TimeInterval {
        stopTask?.cancel()
        stopTask = nil
        pollTask?.cancel()
        seekTask?.cancel()
        generation += 1
        self.track = track
        duration = track.duration
        position = 0
        needsLoad = true
        phase = .ready
        if device == nil { device = try await findDevice() }
        return track.duration
    }

    func play() throws {
        guard track != nil else { throw ProviderError.playback("Nothing is ready to play.") }
        switch phase {
        case .ready:
            beginLoad()
        case .paused:
            needsLoad ? beginLoad() : resume()
        case .idle:
            throw ProviderError.playback("Nothing is ready to play.")
        case .loading, .playing:
            break
        }
    }

    func pause() {
        guard phase == .playing || phase == .loading else { return }
        // A play command that hasn't landed yet may still start the song, so reload on the next play.
        if phase == .loading { needsLoad = true }
        position = currentTime
        phase = .paused
        lastCommand = now()
        generation += 1
        enqueue(nil) { [self] in
            _ = try? await session.send("PUT", "/me/player/pause", query: deviceQuery())
        }
        startPolling()
    }

    func seek(to time: TimeInterval) {
        position = min(max(time, 0), duration)
        switch phase {
        case .idle, .ready:
            return
        case .paused where needsLoad:
            return
        case .playing:
            anchor = now()
        default:
            break
        }
        lastCommand = now()
        seekTask?.cancel()
        let token = generation
        // Scrubbing sends many positions; only the last one is worth a request.
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.enqueue(token) { [self] in
                let milliseconds = Int(self.position * 1000)
                _ = try? await self.session.send("PUT", "/me/player/seek", query: self.deviceQuery(["position_ms": String(milliseconds)]))
            }
        }
    }

    func stop() {
        let wasActive = phase == .playing || phase == .loading
        pollTask?.cancel()
        seekTask?.cancel()
        generation += 1
        phase = .idle
        // Skipping to another song calls stop() first; waiting a moment lets
        // the next song's play command replace the pause instead of following it.
        if wasActive { schedulePause() }
    }

    /// Stops Spotify right away, for when the account is being disconnected.
    func stopAndPause() async {
        let wasActive = phase == .playing || phase == .loading
        stop()
        stopTask?.cancel()
        stopTask = nil
        if wasActive { _ = try? await session.send("PUT", "/me/player/pause", query: deviceQuery()) }
    }

    // MARK: Commands

    /// Commands go out one at a time, in order, so a quick pause can't overtake the play before it.
    private func enqueue(_ token: Int?, _ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if let token, token != self.generation { return }
            await work()
        }
    }

    private func deviceQuery(_ extra: [String: String] = [:]) -> [String: String] {
        var query = extra
        if let id = device?.id { query["device_id"] = id }
        return query
    }

    private func beginLoad() {
        guard let track else { return }
        phase = .loading
        needsLoad = false
        loadStarted = now()
        lastCommand = loadStarted
        generation += 1
        let token = generation
        enqueue(token) { [self] in await load(track, token: token, attempt: 0) }
        startPolling()
    }

    private func load(_ track: Track, token: Int, attempt: Int) async {
        do {
            let target = try await currentDevice()
            // Looking for Spotify can take a while; the user may have paused or skipped meanwhile.
            guard token == generation else { return }
            loadStarted = now()
            var body: [String: Any] = ["uris": ["spotify:track:\(track.id.raw)"]]
            if position > 0.5 { body["position_ms"] = Int(position * 1000) }
            do {
                try await session.send("PUT", "/me/player/play", query: ["device_id": target.id ?? ""], json: body)
            } catch ProviderError.playback where attempt == 0 {
                // The device we knew has gone (Spotify was closed); look again, which can open Spotify.
                device = nil
                guard token == generation else { return }
                await load(track, token: token, attempt: 1)
                return
            }
            if token == generation { lastCommand = now() }
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            fail(Self.message(for: error))
        }
    }

    private func resume() {
        phase = .playing
        anchor = now()
        lastCommand = anchor
        generation += 1
        let token = generation
        enqueue(nil) { [self] in
            do {
                try await session.send("PUT", "/me/player/play", query: deviceQuery())
            } catch is CancellationError {
                return
            } catch {
                // Spotify no longer holds the song (closed or taken over): send it again from here.
                guard token == generation, phase == .playing else { return }
                position = currentTime
                needsLoad = true
                beginLoad()
            }
        }
        startPolling()
    }

    private func schedulePause() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.enqueue(nil) { [self] in
                _ = try? await session.send("PUT", "/me/player/pause", query: deviceQuery())
            }
        }
    }

    private func fail(_ message: String) {
        pollTask?.cancel()
        phase = .idle
        device = nil
        onFailure?(message)
    }

    static func message(for error: Error) -> String {
        switch error {
        case ProviderError.subscriptionRequired:
            "Spotify only lets other apps start playback for Premium accounts. Check this account's plan, or play the song in the Spotify app."
        case ProviderError.notFound:
            "Spotify couldn't find this recording for your account. Try opening it in Spotify to check regional availability, then search for another release in Fiber."
        case ProviderError.permissionDenied:
            "Spotify wouldn't play this song. It may be unavailable in your country or on this device."
        default:
            error.localizedDescription
        }
    }

    // MARK: Finding the Spotify app

    private func currentDevice() async throws -> SpotifyDevice {
        if let device { return device }
        isSearching = true
        defer { isSearching = false }
        let found = try await findDevice()
        device = found
        return found
    }

    /// The device Spotify should play on: the one already playing, otherwise
    /// this phone, otherwise whatever is available.
    static func pickDevice(from devices: [SpotifyDevice]) -> SpotifyDevice? {
        let usable = devices.filter { $0.id != nil && $0.isRestricted != true }
        if let active = usable.first(where: { $0.isActive == true }) { return active }
        for type in ["Smartphone", "Tablet"] {
            if let match = usable.first(where: { $0.type == type }) { return match }
        }
        return usable.first
    }

    /// Spotify only shows up as a device while its app is running, so if there
    /// is none, open the app and wait for it to appear.
    private func findDevice() async throws -> SpotifyDevice {
        var launched = false
        let deadline = now() + 25
        while true {
            let list: SpotifyDeviceList = try await session.get("/me/player/devices")
            if let found = Self.pickDevice(from: list.devices) { return found }
            if !launched {
                launched = true
                guard let url = URL(string: "spotify:"), await openApp(url) else {
                    throw ProviderError.playback("The Spotify app isn't installed on this iPhone. Install it, sign in, then try again.")
                }
            }
            guard now() < deadline else {
                throw ProviderError.playback("Spotify didn't show up as a device. Open the Spotify app, play any song for a moment, then try again.")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Following Spotify's clock

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextPollDelay() else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                if self.phase == .playing, self.duration > 0, self.currentTime >= self.duration - 0.05 {
                    self.finish()
                    return
                }
                await self.poll()
            }
        }
    }

    private func nextPollDelay() -> TimeInterval? {
        switch phase {
        case .loading:
            return 0.6
        case .playing:
            let remaining = max(duration - currentTime, 0)
            return remaining < 10 ? min(1.5, remaining + 0.05) : 4
        case .paused:
            // Notices a resume from the Spotify app; nothing to watch once Spotify has let go of the song.
            return needsLoad ? nil : 8
        case .idle, .ready:
            return nil
        }
    }

    private func poll() async {
        let started = now()
        do {
            let state: SpotifyPlayerState? = try await session.getIfPresent("/me/player", query: ["market": "from_token"])
            apply(state, startedAt: started, latency: now() - started)
        } catch {
            // A missed check isn't a problem: the local clock keeps running and the next one catches up.
        }
    }

    /// Reconciles what Spotify reports with what Fiber believes. Internal so tests can drive it.
    func apply(_ state: SpotifyPlayerState?, startedAt: TimeInterval, latency: TimeInterval) {
        guard let track else { return }
        // Replies to checks that began before the latest command describe the old situation.
        guard startedAt - lastCommand >= (phase == .loading ? 0.3 : 1.0) else { return }

        let holdsTrack = state?.item?.matchesPlaybackID(track.id.raw) == true
        let isPlaying = holdsTrack && state?.isPlaying == true
        // progress_ms describes the middle of the round trip.
        let progress = Double(state?.progressMs ?? 0) / 1000 + (isPlaying ? latency / 2 : 0)

        switch phase {
        case .loading:
            if isPlaying {
                position = progress
                anchor = now()
                phase = .playing
            } else if !isSearching, now() - loadStarted > 12 {
                fail("Spotify didn't start playing the song. Make sure the Spotify app is open and signed in to a Premium account.")
            }
        case .playing:
            if isPlaying {
                if abs(progress - currentTime) > 0.4 {
                    position = progress
                    anchor = now()
                }
            } else if duration - currentTime < (holdsTrack ? 1.5 : 3) {
                // The song reached its end and Spotify stopped or moved on.
                finish()
            } else {
                // Paused, skipped or taken over from the Spotify app or another device.
                position = holdsTrack ? progress : currentTime
                phase = .paused
                needsLoad = !holdsTrack
                onPlayingChanged?(false)
            }
        case .paused:
            if isPlaying, !needsLoad {
                position = progress
                anchor = now()
                phase = .playing
                onPlayingChanged?(true)
            }
        case .idle, .ready:
            break
        }
    }

    private func finish() {
        pollTask?.cancel()
        generation += 1
        position = duration
        phase = .paused
        needsLoad = true
        // Without this Spotify could carry on with its own autoplay after the song.
        schedulePause()
        onFinish?()
    }
}
