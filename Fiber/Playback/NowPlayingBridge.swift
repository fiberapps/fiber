import AVFoundation
import MediaPlayer
import UIKit

/// Publishes the current track to the Lock Screen, Control Center and the
/// Dynamic Island, and receives their buttons plus headphone and Bluetooth
/// controls. Only used for audio Fiber plays itself; the system music player
/// and remote services publish their own.
final class NowPlayingBridge {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
    }

    private var handlers: Handlers?
    private var isActive = false
    private var artworkTask: Task<Void, Never>?
    private var artworkTrack: MediaID?

    func activate(_ handlers: Handlers) {
        self.handlers = handlers
        guard !isActive else { return }
        isActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.run { $0.play() } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.run { $0.pause() } ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.toggle() } ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.next() } ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.previous() } ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return self?.run { $0.seek(position) } ?? .commandFailed
        }
    }

    /// Hands the Lock Screen back when another player (system or remote) owns playback.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
        artworkTask?.cancel()
        artworkTrack = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func run(_ action: (Handlers) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let handlers else { return .noActionableNowPlayingItem }
        action(handlers)
        return .success
    }

    func update(track: Track?, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard isActive else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            return
        }
        var info = center.nowPlayingInfo ?? [:]
        if artworkTrack != track.id {
            info[MPMediaItemPropertyArtwork] = nil
            info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = nil
            info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = nil
        }
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistName
        info[MPMediaItemPropertyAlbumTitle] = track.albumTitle
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        center.nowPlayingInfo = info

        guard artworkTrack != track.id else { return }
        artworkTrack = track.id
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await ArtworkLoader.shared.image(for: track.artwork, pixels: 700),
                  !Task.isCancelled, let self, self.artworkTrack == track.id, self.isActive
            else { return }
            var latest = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            latest[MPMediaItemPropertyArtwork] = Self.artwork(from: image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = latest
            let local = await Self.localMotionArtwork(for: track)
            let generated: (key: String, artwork: MPMediaItemAnimatedArtwork)?
            if local == nil {
                let palette = await ArtworkLoader.shared.palette(for: track.artwork)
                let file = try? await Task.detached(priority: .utility) {
                    try await LockScreenMotion.videoFile(for: palette)
                }.value
                generated = file.flatMap { LockScreenMotion.animatedArtwork(file: $0, palette: palette, preview: image) }
            } else {
                generated = nil
            }
            guard !Task.isCancelled, self.artworkTrack == track.id, self.isActive else { return }
            if let motion = local ?? generated {
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[motion.key] = motion.artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// Local licensed motion assets: Song.mp3 pairs with Song.artwork.mp4 in Files → Fiber → Music.
    private static func localMotionArtwork(for track: Track) async -> (key: String, artwork: MPMediaItemAnimatedArtwork)? {
        guard track.id.service == .local else { return nil }
        let audio = LocalProvider.musicDirectory.appendingPathComponent(track.id.raw)
        let url = audio.deletingPathExtension().appendingPathExtension("artwork.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        let image = UIImage(cgImage: frame.image)
        let ratio = image.size.width / image.size.height
        let key: String
        if abs(ratio - 1) < 0.02 { key = MPNowPlayingInfoProperty1x1AnimatedArtwork }
        else if abs(ratio - 0.75) < 0.02 { key = MPNowPlayingInfoProperty3x4AnimatedArtwork }
        else { return nil }
        guard MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(key) else { return nil }
        let version = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let artwork = MPMediaItemAnimatedArtwork(artworkID: url.lastPathComponent + String(version),
            previewImageRequestHandler: { _, completion in completion(image) },
            videoAssetFileURLRequestHandler: { _, completion in completion(url) })
        return (key, artwork)
    }

    /// The system calls the image handler on its own queue, so it must not be
    /// tied to the main actor.
    private nonisolated static func artwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
