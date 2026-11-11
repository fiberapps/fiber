import AVFoundation

/// Plays a remote audio URL inside Fiber. YouTube Music uses this so the queue,
/// lyrics clock and Lock Screen belong to Fiber rather than another app.
final class StreamAudioEngine: NSObject, PlaybackEngine {
    let mode = PlaybackMode.inApp
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var resolver: @MainActor (Track) async throws -> URL = { _ in throw ProviderError.notConnected(.youtubeMusic) }

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var generation = 0
    private var restingTime: TimeInterval = 0

    var currentTime: TimeInterval {
        let seconds = player?.currentTime().seconds ?? restingTime
        return seconds.isFinite ? max(0, seconds) : restingTime
    }

    func prepare(_ track: Track) async throws -> TimeInterval {
        generation += 1
        let token = generation
        let url = try await resolver(track)
        guard token == generation else { throw CancellationError() }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": YouTubeAudio.playbackUserAgent,
                "Referer": "https://www.youtube.com/",
            ],
        ])
        let item = AVPlayerItem(asset: asset)
        if player == nil { player = AVPlayer() }
        player?.replaceCurrentItem(with: item)
        observe(item)
        for _ in 0..<160 {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if item.status == .readyToPlay { break }
            if item.status == .failed {
                throw ProviderError.playback(item.error?.localizedDescription ?? "The audio stream failed before it started.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard item.status == .readyToPlay else { throw ProviderError.playback("The audio stream took too long to start.") }
        restingTime = 0
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : track.duration
    }

    func play() throws {
        guard let player, player.currentItem != nil else { throw ProviderError.playback("Nothing is loaded to play.") }
        player.play()
    }

    func pause() {
        restingTime = currentTime
        player?.pause()
    }

    func seek(to time: TimeInterval) {
        restingTime = max(0, time)
        player?.seek(to: CMTime(seconds: restingTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        generation += 1
        restingTime = 0
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        clearObservers()
    }

    private func observe(_ item: AVPlayerItem) {
        clearObservers()
        let token = generation
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.generation else { return }
                self.onFinish?()
            }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "Playback stopped before the song ended."
            MainActor.assumeIsolated {
                guard let self, token == self.generation else { return }
                self.onFailure?(message)
            }
        }
    }

    private func clearObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
    }
}
