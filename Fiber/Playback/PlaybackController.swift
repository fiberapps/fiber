import AVFoundation
import Observation

/// Owns the queue and drives whichever engine the current track needs.
/// Shuffle, repeat and queue editing live here, so they behave the same for
/// every service.
@Observable
final class PlaybackController {
    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var status = PlaybackStatus.idle
    private(set) var duration: TimeInterval = 0
    /// Position refreshed a few times a second, for progress bars.
    private(set) var elapsed: TimeInterval = 0
    private(set) var mode: PlaybackMode?
    private(set) var isShuffled = false
    private(set) var contextTitle: String?
    var repeatMode = RepeatMode.off
    /// The latest playback problem, shown as an alert.
    var problem: String?

    /// Called once a track actually starts, with what the user chose to play.
    @ObservationIgnored var onStarted: ((Track, MediaItem?) -> Void)?

    @ObservationIgnored private let engineFor: (ServiceID) throws -> any PlaybackEngine
    @ObservationIgnored private var engine: (any PlaybackEngine)?
    @ObservationIgnored private var context: MediaItem?
    @ObservationIgnored private var originalOrder: [Track]?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let nowPlaying = NowPlayingBridge()
    @ObservationIgnored private var resumeAfterInterruption = false

    init(engineFor: @escaping (ServiceID) throws -> any PlaybackEngine) {
        self.engineFor = engineFor
        observeAudioSession()
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var hasNext: Bool { index + 1 < queue.count || (repeatMode == .all && !queue.isEmpty) }

    /// Exact position, read every frame by the lyrics view.
    var preciseTime: TimeInterval { engine?.currentTime ?? elapsed }

    // MARK: Starting playback

    func play(_ tracks: [Track], startingAt start: Int = 0, shuffled: Bool = false, context: MediaItem? = nil) {
        guard !tracks.isEmpty else { return }
        self.context = context
        contextTitle = context?.title
        originalOrder = nil
        isShuffled = shuffled
        if shuffled {
            originalOrder = tracks
            queue = tracks.shuffled()
            begin(at: 0)
        } else {
            queue = tracks
            begin(at: min(max(start, 0), tracks.count - 1))
        }
    }

    private func begin(at position: Int) {
        guard queue.indices.contains(position) else { return }
        loadTask?.cancel()
        engine?.stop()
        index = position
        let track = queue[position]
        status = .loading
        elapsed = 0
        duration = track.duration
        problem = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try self.engineFor(track.id.service)
                self.attach(engine)
                let realDuration = try await engine.prepare(track)
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                if realDuration > 0 { self.duration = realDuration }
                try self.activateSession(for: engine)
                try engine.play()
                self.status = .playing
                self.startTicker()
                self.publish()
                self.onStarted?(track, self.context)
            } catch is CancellationError {
                return
            } catch {
                guard self.current?.id == track.id else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func attach(_ engine: any PlaybackEngine) {
        if let previous = self.engine, previous !== engine { previous.stop() }
        self.engine = engine
        mode = engine.mode
        engine.onFinish = { [weak self] in self?.trackFinished() }
        engine.onFailure = { [weak self] message in self?.fail(message) }
        engine.onPlayingChanged = { [weak self] isPlaying in self?.externalChange(isPlaying: isPlaying) }
        if engine.mode == .inApp {
            nowPlaying.activate(.init(
                play: { [weak self] in self?.resume() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.togglePlayPause() },
                next: { [weak self] in self?.next() },
                previous: { [weak self] in self?.previous() },
                seek: { [weak self] in self?.seek(to: $0) }))
        } else {
            nowPlaying.deactivate()
        }
    }

    /// Someone paused or resumed outside Fiber (Control Center, a headset, another device).
    private func externalChange(isPlaying: Bool) {
        guard status == .playing || status == .paused else { return }
        elapsed = engine?.currentTime ?? elapsed
        status = isPlaying ? .playing : .paused
        if isPlaying { startTicker() } else { stopTicker() }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        problem = message
        stopTicker()
        publish()
    }

    // MARK: Transport

    func togglePlayPause() {
        switch status {
        case .playing: pause()
        case .paused: resume()
        case .idle, .failed: if current != nil { begin(at: index) }
        case .loading: break
        }
    }

    func pause() {
        guard status == .playing else { return }
        engine?.pause()
        elapsed = engine?.currentTime ?? elapsed
        status = .paused
        stopTicker()
        publish()
    }

    func resume() {
        guard status == .paused, let engine else { return }
        do {
            try activateSession(for: engine)
            try engine.play()
            status = .playing
            startTicker()
            publish()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func next() {
        if index + 1 < queue.count {
            begin(at: index + 1)
        } else if repeatMode == .all, !queue.isEmpty {
            begin(at: 0)
        }
    }

    func previous() {
        // Like every music player: go back a track only near the start of this one.
        if preciseTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            begin(at: index - 1)
        }
    }

    func seek(to time: TimeInterval) {
        guard let engine, current != nil else { return }
        let target = min(max(time, 0), max(duration - 0.25, 0))
        engine.seek(to: target)
        elapsed = target
        publish()
    }

    private func trackFinished() {
        if repeatMode == .one {
            begin(at: index)
        } else if hasNext {
            next()
        } else {
            // End of the queue: rest at the start of the last track.
            engine?.seek(to: 0)
            elapsed = 0
            status = .paused
            stopTicker()
            publish()
        }
    }

    // MARK: Queue

    func toggleShuffle() {
        guard let playing = current else {
            isShuffled.toggle()
            return
        }
        if isShuffled {
            if let original = originalOrder {
                queue = original.filter { track in queue.contains { $0.id == track.id } }
                    + queue.filter { track in !original.contains { $0.id == track.id } }
                index = queue.firstIndex { $0.id == playing.id } ?? 0
            }
            originalOrder = nil
            isShuffled = false
        } else {
            originalOrder = queue
            queue = Array(queue[...index]) + queue[(index + 1)...].shuffled()
            isShuffled = true
        }
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track]) }
        queue.insert(track, at: index + 1)
        originalOrder?.append(track)
    }

    func addToQueue(_ tracks: [Track]) {
        guard current != nil else { return play(tracks) }
        queue.append(contentsOf: tracks)
        originalOrder?.append(contentsOf: tracks)
    }

    /// Jumps to a track in "Up Next". `offset` counts from the first upcoming track.
    func jump(toUpNext offset: Int) {
        begin(at: index + 1 + offset)
    }

    func removeUpNext(at offsets: IndexSet) {
        var upcoming = upNext
        upcoming.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + upcoming
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var upcoming = upNext
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + upcoming
    }

    // MARK: Clock and system integration

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .playing, let engine = self.engine else { return }
                self.elapsed = engine.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func publish() {
        guard mode == .inApp else { return }
        nowPlaying.update(track: current, elapsed: preciseTime, duration: duration, isPlaying: status == .playing)
    }

    private func activateSession(for engine: any PlaybackEngine) throws {
        // The system player and remote devices manage their own audio session.
        guard engine.mode == .inApp else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.handleInterruption(type, shouldResume: options?.contains(.shouldResume) ?? false) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Headphones unplugged or a Bluetooth device dropped: stop instead of blasting the speaker.
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { if self?.mode == .inApp { self?.pause() } }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard mode == .inApp else { return }
        switch type {
        case .began:
            resumeAfterInterruption = status == .playing
            pause()
        case .ended:
            if resumeAfterInterruption, shouldResume { resume() }
            resumeAfterInterruption = false
        default:
            break
        }
    }
}
