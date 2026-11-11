import AVFoundation

/// Ten-band equalizer settings. Only audio Fiber decodes itself passes through it.
nonisolated struct EqualizerSettings: Codable, Equatable, Sendable {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Float> = -12...12

    var isEnabled = false
    var preamp: Float = 0
    var gains: [Float] = Array(repeating: 0, count: 10)
    var presetName: String? = "Flat"

    static let presets: [(name: String, gains: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Booster", [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        ("Treble Booster", [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        ("Vocal Booster", [-2, -3, -3, 1, 3.5, 3.5, 3, 1.5, 0, -1.5]),
        ("Acoustic", [5, 5, 4, 1, 2, 2, 3.5, 4, 3.5, 2]),
        ("Electronic", [4.5, 4, 1, 0, -2, 2, 1, 1.5, 4, 5]),
        ("Hip-Hop", [5, 4.5, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        ("Rock", [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        ("Late Night", [3, 2.5, 1, 0, 1.5, 2.5, 2, 1, -1, -2.5]),
        ("Loudness", [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
    ]
}

/// Plays audio files through AVAudioEngine: player → equalizer → output.
/// Local files and the synthesized demo catalog both use this one engine, so
/// they share the equalizer and behave identically.
final class FileAudioEngine: PlaybackEngine {
    let mode = PlaybackMode.inApp
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?

    /// Each file-based service says how to turn one of its tracks into a file URL.
    var resolvers: [ServiceID: (Track) async throws -> URL] = [:]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)

    private var file: AVAudioFile?
    private var sampleRate = 44_100.0
    /// Frame in the file where the current scheduled segment begins.
    private var segmentStart: AVAudioFramePosition = 0
    /// Position remembered while the player node is not rendering.
    private var restingTime: TimeInterval = 0
    /// Bumped whenever the schedule changes, so stale completion callbacks are ignored.
    private var generation = 0
    private var wantsPlayback = false
    private var prepareCount = 0
    /// Last position read while playing, used to resume after the output changes.
    private var lastObservedTime: TimeInterval = 0

    init() {
        engine.attach(player)
        engine.attach(equalizer)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerSettings.frequencies[index]
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    func apply(_ settings: EqualizerSettings) {
        equalizer.bypass = !settings.isEnabled
        equalizer.globalGain = settings.preamp
        for (index, band) in equalizer.bands.enumerated() where index < settings.gains.count {
            band.gain = settings.gains[index]
        }
    }

    var currentTime: TimeInterval {
        guard player.isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return restingTime }
        let time = max(0, Double(segmentStart + playerTime.sampleTime) / sampleRate)
        lastObservedTime = time
        return time
    }

    func prepare(_ track: Track) async throws -> TimeInterval {
        stop()
        guard let resolve = resolvers[track.id.service] else {
            throw ProviderError.unsupported("Playing \(track.id.service.displayName) audio in Fiber")
        }
        prepareCount += 1
        let request = prepareCount
        let url = try await resolve(track)
        // A newer track was requested while this one was still being resolved.
        guard request == prepareCount else { throw CancellationError() }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ProviderError.playback("\(url.lastPathComponent) couldn't be opened (\(error.localizedDescription)).")
        }
        file = audioFile
        sampleRate = audioFile.processingFormat.sampleRate
        let format = audioFile.processingFormat
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        schedule(from: 0)
        return Double(audioFile.length) / sampleRate
    }

    func play() throws {
        guard file != nil else { return }
        wantsPlayback = true
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
    }

    func pause() {
        restingTime = currentTime
        wantsPlayback = false
        // Re-scheduling from the resting point keeps the clock exact after a pause.
        generation += 1
        player.stop()
        schedule(from: restingTime)
    }

    func seek(to time: TimeInterval) {
        guard file != nil else { return }
        let resume = wantsPlayback
        generation += 1
        player.stop()
        schedule(from: time)
        if resume { player.play() }
    }

    func stop() {
        generation += 1
        wantsPlayback = false
        player.stop()
        file = nil
        restingTime = 0
        segmentStart = 0
    }

    private func schedule(from time: TimeInterval) {
        guard let file else { return }
        let lastFrame = max(file.length - 1, 0)
        let frame = min(max(AVAudioFramePosition(time * sampleRate), 0), lastFrame)
        segmentStart = frame
        restingTime = Double(frame) / sampleRate
        lastObservedTime = restingTime
        generation += 1
        let scheduled = generation
        let endTime = Double(file.length) / sampleRate
        player.scheduleSegment(
            file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == scheduled else { return }
                self.wantsPlayback = false
                self.restingTime = endTime
                self.onFinish?()
            }
        }
    }

    /// Unplugging headphones or switching outputs resets the engine graph.
    private func recoverFromConfigurationChange() {
        guard file != nil, wantsPlayback else { return }
        let resumeAt = max(restingTime, lastObservedTime)
        do {
            schedule(from: resumeAt)
            try play()
        } catch {
            onFailure?("The audio output changed and playback couldn't restart (\(error.localizedDescription)).")
        }
    }
}
