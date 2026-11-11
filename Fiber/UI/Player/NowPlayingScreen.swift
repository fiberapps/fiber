import SwiftUI

/// The bar that floats above the tab bar on every tab.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        HStack(spacing: 10) {
            Button {
                if playback.current != nil { app.isPlayerPresented = true }
            } label: {
                HStack(spacing: 10) {
                    if let track = playback.current {
                        ArtworkView(artwork: track.artwork, cornerRadius: 6, points: 32)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.title).font(.system(size: 13, weight: .semibold))
                            Text(track.artistName).font(.system(size: 13)).opacity(0.85)
                        }
                        .lineLimit(1)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.55))
                            .frame(width: 32, height: 32)
                            .background(Color(white: 0.25), in: .rect(cornerRadius: 6, style: .continuous))
                        Text("Not Playing").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.current.map { "Now playing, \($0.title) by \($0.artistName)" } ?? "Not playing")
            .accessibilityHint(playback.current == nil ? "" : "Opens the player")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38, height: 38)
                    .contentShape(.rect)
            }
            .accessibilityLabel(playback.status.isPlaying ? "Pause" : "Play")
            .disabled(playback.current == nil)

            Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18))
                    .frame(width: 38, height: 38)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Next")
            .disabled(!playback.hasNext)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
    }
}

/// The full-screen player: artwork, lyrics or the queue above one set of controls.
struct NowPlayingScreen: View {
    enum Panel {
        case artwork, lyrics, queue
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Namespace private var namespace
    @State var panel = Panel.artwork
    @State private var lyrics = Loadable<Lyrics?>.loading
    /// In the lyrics panel the controls fade away after a moment, as in the reference recording.
    @State private var controlsHidden = false
    @State private var hideTask: Task<Void, Never>?
    /// The effect word being sung right now, which tints the background.
    @State private var mood: LyricEffect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion keeps the recolouring but drops particles and the background wash.
    private var effectLevel: LyricEffectLevel {
        reduceMotion && app.settings.lyricEffects == .full ? .subtle : app.settings.lyricEffects
    }

    var body: some View {
        let playback = app.playback
        PaletteReader(artwork: playback.current?.artwork ?? .none) { palette in
            ZStack {
                PlayerBackdrop(palette: palette, isAnimating: playback.status.isPlaying)
                MoodWash(effect: panel == .lyrics ? mood : nil)
                if let track = playback.current {
                    #if targetEnvironment(macCatalyst)
                    desktopContent(track)
                    #else
                    content(track).frame(maxWidth: 700)
                    #endif
                } else {
                    ContentUnavailableView("Not Playing", systemImage: "music.note")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: playback.current?.id) { await loadLyrics() }
        .onChange(of: panel) { scheduleHide() }
        .onChange(of: playback.status.isPlaying) { scheduleHide() }
    }

    #if targetEnvironment(macCatalyst)
    private func desktopContent(_ track: Track) -> some View {
        GeometryReader { geometry in
            let column = max(280, min(geometry.size.width * 0.43, 660))
            let cover = max(180, min(column - 64, geometry.size.height - 290))
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Label("Back to Library", systemImage: "chevron.down") }
                    Spacer()
                    Button { panel = .lyrics } label: { Label("Lyrics", systemImage: "quote.bubble") }
                        .tint(panel != .queue ? .white : .secondary)
                    Button { panel = .queue } label: { Label("Queue", systemImage: "list.bullet") }
                        .tint(panel == .queue ? .white : .secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 12)
                HStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Spacer(minLength: 0)
                        ArtworkView(artwork: track.artwork, cornerRadius: 14, points: 640)
                            .frame(width: cover, height: cover)
                            .shadow(color: .black.opacity(0.3), radius: 28, y: 16)
                        VStack(spacing: 4) {
                            Text(track.title).font(.system(size: 25, weight: .bold)).lineLimit(2)
                            Text(track.artistName).font(.system(size: 18)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        .multilineTextAlignment(.center)
                        Scrubber(elapsed: app.playback.elapsed, duration: app.playback.duration,
                                 onSeek: { app.playback.seek(to: $0) })
                        TransportButtons()
                        HStack(spacing: 12) {
                            desktopToggle("Shuffle", symbol: "shuffle", selected: app.playback.isShuffled) { app.playback.toggleShuffle() }
                            desktopToggle("Repeat Song", symbol: "repeat.1", selected: app.playback.repeatMode == .one) {
                                app.playback.repeatMode = app.playback.repeatMode == .one ? .off : .one
                            }
                            desktopToggle("Repeat Queue", symbol: "repeat", selected: app.playback.repeatMode == .all) {
                                app.playback.repeatMode = app.playback.repeatMode == .all ? .off : .all
                            }
                        }
                        HStack(spacing: 16) { VolumeSlider(); RoutePicker().frame(width: 28, height: 28) }
                        Spacer(minLength: 0)
                    }
                    .frame(width: column).padding(.leading, 12)
                    Group {
                        if panel == .queue { QueueList() }
                        else { lyricsPanel(track) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
    }

    private func desktopToggle(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 36)
                .background(selected ? .white.opacity(0.22) : .white.opacity(0.06), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : .white.opacity(0.6))
        .accessibilityLabel(title).accessibilityValue(selected ? "On" : "Off")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
    #endif

    private func content(_ track: Track) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .onTapGesture { dismiss() }
                .accessibilityLabel("Close player")
                .accessibilityAddTraits(.isButton)

            ZStack(alignment: .bottom) {
                Group {
                    switch panel {
                    case .artwork: artworkPanel(track)
                    case .lyrics: lyricsPanel(track)
                    case .queue: queuePanel(track)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                controls
                    .opacity(controlsHidden ? 0 : 1)
                    .allowsHitTesting(!controlsHidden)
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: panel)
        .animation(.easeInOut(duration: 0.45), value: controlsHidden)
    }

    // MARK: Panels

    private func artworkPanel(_ track: Track) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            ArtworkView(artwork: track.artwork, cornerRadius: 12, points: 380)
                .matchedGeometryEffect(id: "cover", in: namespace)
                .padding(.horizontal, 26)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .scaleEffect(app.playback.status.isPlaying ? 1 : 0.82)
                .animation(.spring(duration: 0.55, bounce: 0.3), value: app.playback.status.isPlaying)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 20, weight: .bold))
                    Text(track.artistName).font(.system(size: 18)).opacity(0.7)
                }
                .lineLimit(1)
                .matchedGeometryEffect(id: "titles", in: namespace, properties: .position, anchor: .leading)
                Spacer(minLength: 0)
                favoriteButton(track)
                moreMenu(track)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            // Leaves room for the controls, which sit over the bottom of every panel.
            .padding(.bottom, controlsHeight + 6)
        }
    }

    private func compactHeader(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artwork, cornerRadius: 8, points: 72)
                .matchedGeometryEffect(id: "cover", in: namespace)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 16, weight: .bold))
                Text(track.artistName).font(.system(size: 14)).opacity(0.7)
            }
            .lineLimit(1)
            .matchedGeometryEffect(id: "titles", in: namespace, properties: .position, anchor: .leading)
            Spacer(minLength: 0)
            moreMenu(track)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .padding(.bottom, 8)
    }

    private var desktopLyricScale: Double {
        #if targetEnvironment(macCatalyst)
        max(1, 44 / app.settings.lyricTextSize.points)
        #else
        1
        #endif
    }

    private func lyricsPanel(_ track: Track) -> some View {
        VStack(spacing: 0) {
            #if !targetEnvironment(macCatalyst)
            compactHeader(track)
            #endif
            switch lyrics {
            case .loading:
                ProgressView().tint(.white).frame(maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Lyrics Unavailable", systemImage: "quote.bubble", description: Text(message))
            case .loaded(nil):
                ContentUnavailableView(
                    "No Lyrics", systemImage: "quote.bubble",
                    description: Text(app.settings.usesOnlineLyrics
                        ? "Nothing was found for this song. For your own files, an .lrc file with the same name also works."
                        : "Online lyrics are off in Settings. For your own files, an .lrc file with the same name also works."))
            case .loaded(let found?):
                LyricsView(lyrics: found, isPlaying: app.playback.status.isPlaying,
                           clock: { app.playback.preciseTime },
                           onSeek: { app.playback.seek(to: $0) },
                           effects: effectLevel, fill: app.settings.lyricFill, textSize: app.settings.lyricTextSize,
                           fontScale: desktopLyricScale,
                           onMood: { mood = $0 })
                    .simultaneousGesture(TapGesture().onEnded { revealControls() })
            }
        }
    }

    private func queuePanel(_ track: Track) -> some View {
        VStack(spacing: 0) {
            compactHeader(track)
            QueueList()
                .padding(.bottom, controlsHeight)
        }
    }

    // MARK: Controls

    private let controlsHeight: CGFloat = 318

    private var controls: some View {
        let playback = app.playback
        return VStack(spacing: 0) {
            Scrubber(elapsed: playback.elapsed, duration: playback.duration,
                     onSeek: { playback.seek(to: $0) })
            TransportButtons()
                .padding(.top, 18)
            VolumeSlider()
                .padding(.top, 22)
            HStack {
                panelButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
                Spacer()
                RoutePicker()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Audio output")
                Spacer()
                panelButton(.queue, symbol: "list.bullet", label: "Queue")
            }
            .padding(.horizontal, 36)
            .padding(.top, 14)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 4)
        .frame(height: controlsHeight, alignment: .bottom)
    }

    private func panelButton(_ target: Panel, symbol: String, label: String) -> some View {
        let isOn = panel == target
        return Button {
            panel = isOn ? .artwork : target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isOn ? .black.opacity(0.8) : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .background(.white.opacity(isOn ? 0.75 : 0), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func favoriteButton(_ track: Track) -> some View {
        let isFavorite = app.library.isFavorite(track.id)
        return Button {
            app.library.toggleFavorite(track)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: isFavorite)
        .accessibilityLabel(isFavorite ? "Undo Favorite" : "Favorite")
    }

    private func moreMenu(_ track: Track) -> some View {
        Menu {
            TrackMenuItems(track: track)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: .circle)
        }
        .accessibilityLabel("More")
    }

    // MARK: Behaviour

    private func revealControls() {
        controlsHidden = false
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if targetEnvironment(macCatalyst)
        controlsHidden = false
        return
        #else
        guard panel == .lyrics, app.playback.status.isPlaying, case .loaded(.some) = lyrics else {
            controlsHidden = false
            return
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            controlsHidden = true
        }
        #endif
    }

    private func loadLyrics() async {
        guard let track = app.playback.current else { return }
        lyrics = .loading
        do {
            let found = try await app.lyrics(for: track)
            guard app.playback.current?.id == track.id else { return }
            lyrics = .loaded(found)
        } catch {
            lyrics = .failed(error.localizedDescription)
        }
        scheduleHide()
    }
}

/// A soft glow in the effect's colour, laid over the backdrop while that word is sung.
private struct MoodWash: View {
    let effect: LyricEffect?

    var body: some View {
        ZStack {
            if let effect {
                RadialGradient(colors: [effect.glow.opacity(0.5), effect.glow.opacity(0)],
                               center: effect.washCenter, startRadius: 0, endRadius: 560)
                    .blendMode(.plusLighter)
                    .transition(.opacity)
                    .id(effect)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: effect)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Playing Next": shuffle, repeat, and the upcoming songs, which can be
/// reordered, removed or tapped to jump ahead.
struct QueueList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Playing Next").font(.system(size: 17, weight: .bold))
                    if let context = playback.contextTitle {
                        Text("From \(context)").font(.system(size: 13)).opacity(0.6).lineLimit(1)
                    }
                }
                Spacer()
                toggle("shuffle", isOn: playback.isShuffled, label: "Shuffle") { playback.toggleShuffle() }
                toggle(playback.repeatMode == .one ? "repeat.1" : "repeat", isOn: playback.repeatMode != .off,
                       label: "Repeat") { playback.cycleRepeat() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)

            if playback.upNext.isEmpty {
                Text("Nothing else is queued.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(playback.upNext.enumerated()), id: \.offset) { offset, track in
                        Button {
                            playback.jump(toUpNext: offset)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(artwork: track.artwork, cornerRadius: 4, points: 44)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title).font(.system(size: 16))
                                    Text(track.artistName).font(.system(size: 13)).opacity(0.6)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "line.3.horizontal").opacity(0.4)
                            }
                            .foregroundStyle(.white)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.15))
                        .listRowInsets(EdgeInsets(top: 6, leading: 30, bottom: 6, trailing: 30))
                    }
                    .onMove { playback.moveUpNext(from: $0, to: $1) }
                    .onDelete { playback.removeUpNext(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func toggle(_ symbol: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isOn ? .black.opacity(0.8) : .white)
                .frame(width: 44, height: 34)
                .background(.white.opacity(isOn ? 0.8 : 0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
