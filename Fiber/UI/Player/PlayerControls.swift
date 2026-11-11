import AVKit
import MediaPlayer
import SwiftUI

/// Slow-moving colour field made from the cover's own colours.
struct PlayerBackdrop: View {
    let palette: ArtPalette
    var isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating)) { timeline in
            MeshGradient(width: 3, height: 3, points: MotionField.points(at: timeline.date.timeIntervalSinceReferenceDate * 0.11),
                         colors: MotionField.colors(for: palette), smoothsColors: true)
        }
        .overlay(.black.opacity(0.22))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: palette)
    }
}

/// The playback position bar. It thickens while dragged and only seeks on release.
struct Scrubber: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    /// Nil when the service can't seek: the bar then only shows progress.
    let onSeek: ((TimeInterval) -> Void)?

    @State private var dragFraction: Double?

    private var fraction: Double {
        dragFraction ?? (duration > 0 ? min(max(elapsed / duration, 0), 1) : 0)
    }

    var body: some View {
        let shown = fraction * duration
        VStack(spacing: 7) {
            GeometryReader { proxy in
                let isDragging = dragFraction != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(isDragging ? 1 : 0.6))
                        .frame(width: max(proxy.size.width * fraction, 0))
                }
                .clipShape(.capsule)
                .frame(height: isDragging ? 13 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard onSeek != nil else { return }
                            dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let dragFraction { onSeek?(dragFraction * duration) }
                            dragFraction = nil
                        })
                .animation(.spring(duration: 0.3), value: isDragging)
            }
            .frame(height: 24)
            HStack {
                Text(shown.clockText)
                Spacer()
                Text("-" + max(duration - shown, 0).clockText)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(dragFraction == nil ? 0.5 : 0.9))
        }
        .accessibilityElement()
        .accessibilityLabel("Track position")
        .accessibilityValue("\(shown.clockText) of \(duration.clockText)")
        .accessibilityAdjustableAction { direction in
            guard let onSeek else { return }
            onSeek(elapsed + (direction == .increment ? 15 : -15))
        }
    }
}

/// Reads and sets the system volume through the system's own volume control,
/// which is the supported way for an app to offer a volume slider.
@Observable
final class SystemVolume {
    private(set) var level: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    @ObservationIgnored fileprivate weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.level = Double(value) }
        }
    }

    /// False where the system gives no volume control, such as the Simulator.
    var isAvailable: Bool { slider != nil }

    func set(_ value: Double) {
        level = value
        slider?.value = Float(value)
    }
}

/// Keeps the system volume control in the hierarchy, invisibly, so the custom
/// slider can drive it.
private struct VolumeHost: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
    }
}

struct VolumeSlider: View {
    @State private var volume = SystemVolume()
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.system(size: 12))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(isDragging ? 1 : 0.6))
                        .frame(width: proxy.size.width * volume.level)
                }
                .clipShape(.capsule)
                .frame(height: isDragging ? 13 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            volume.set(min(max(value.location.x / proxy.size.width, 0), 1))
                        }
                        .onEnded { _ in isDragging = false })
                .animation(.spring(duration: 0.3), value: isDragging)
            }
            .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.55))
        .background { VolumeHost(volume: volume).frame(width: 1, height: 1) }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume.level * 100)) percent")
        .accessibilityAdjustableAction { direction in
            volume.set(min(max(volume.level + (direction == .increment ? 0.1 : -0.1), 0), 1))
        }
    }
}

/// The system's output picker (AirPlay, Bluetooth, speakers).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Previous, play or pause, next.
struct TransportButtons: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        HStack(spacing: 0) {
            button("backward.fill", size: 30, label: "Previous") { playback.previous() }
            Button {
                playback.togglePlayPause()
            } label: {
                ZStack {
                    if playback.status == .loading {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
                .frame(width: 96, height: 72)
                .contentShape(.rect)
            }
            .buttonStyle(TransportPressStyle())
            .accessibilityLabel(playback.status.isPlaying ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .medium), trigger: playback.status.isPlaying)
            button("forward.fill", size: 30, label: "Next") { playback.next() }
                .disabled(!playback.hasNext)
        }
        .foregroundStyle(.white)
    }

    private func button(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 96, height: 72)
                .contentShape(.rect)
        }
        .buttonStyle(TransportPressStyle())
        .accessibilityLabel(label)
    }
}

private struct TransportPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : 0))
                    .frame(width: 78, height: 78)
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
    }
}
