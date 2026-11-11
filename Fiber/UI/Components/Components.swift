import SwiftUI

enum Theme {
    /// The pink-red used for the selected tab and library icons in the references.
    static let accent = Color(red: 1.0, green: 0.216, blue: 0.373)
    static let margin: CGFloat = 20
    static let secondaryText = Color(white: 0.6)
    static let separator = Color.white.opacity(0.14)
}

/// Loads a palette for a cover and hands it to its content.
struct PaletteReader<Content: View>: View {
    let artwork: Artwork
    @ViewBuilder var content: (ArtPalette) -> Content

    @State private var palette: ArtPalette?

    var body: some View {
        content(palette ?? ArtworkLoader.shared.cachedPalette(for: artwork) ?? .neutral)
            .task(id: artwork) {
                let loaded = await ArtworkLoader.shared.palette(for: artwork)
                withAnimation(.easeInOut(duration: 0.35)) { palette = loaded }
            }
    }
}

/// The large page title with the account button, as on every main tab.
struct PageHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(0.2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
            Button {
                app.isSettingsPresented = true
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .padding(2)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account and Settings")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A shelf title, with a chevron when the shelf can be opened in full.
struct ShelfHeader: View {
    let title: String
    var route: Route?

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 6) {
                        Text(title)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 22, weight: .bold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.margin)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityLabel("Explicit")
    }
}

/// Title and subtitle under a square cover.
struct CoverCaption: View {
    let title: String
    let subtitle: String?
    var isExplicit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if isExplicit { ExplicitBadge() }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps a label so tapping it does the right thing for that kind of item:
/// collections open, stations and songs play.
struct MediaLink<Label: View>: View {
    let item: MediaItem
    /// The list a song belongs to, so tapping it queues its neighbours too.
    var siblings: [Track] = []
    @ViewBuilder var label: Label

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch item {
            case .album(let album): NavigationLink(value: Route.album(album)) { label }
            case .playlist(let playlist): NavigationLink(value: Route.playlist(playlist)) { label }
            case .artist(let artist): NavigationLink(value: Route.artist(artist)) { label }
            case .category(let category): NavigationLink(value: Route.category(category)) { label }
            case .station(let station):
                Button { app.play(station: station) } label: { label }
                    .accessibilityHint("Plays this station")
            case .track(let track):
                Button {
                    let list = siblings.isEmpty ? [track] : siblings
                    app.play(list, at: list.firstIndex { $0.id == track.id } ?? 0)
                } label: { label }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

/// A gentle press-down, used for artwork and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// The actions offered for a song wherever it appears.
struct TrackMenuItems: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            app.playback.playNext(track)
            app.showToast("Playing Next")
        }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
            app.playback.addToQueue([track])
            app.showToast("Added to Queue")
        }
        Divider()
        Button(app.library.isFavorite(track.id) ? "Undo Favorite" : "Favorite",
               systemImage: app.library.isFavorite(track.id) ? "star.slash" : "star") {
            app.toggleFavorite(track)
        }
        if track.id.service != .local {
            Button(app.library.isSaved(track.id) ? "Remove from Library" : "Add to Library",
                   systemImage: app.library.isSaved(track.id) ? "minus.circle" : "plus") {
                app.toggleSaved(.track(track))
            }
        }
        Menu("Add to a Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist", systemImage: "plus") {
                app.library.createPlaylist(named: track.title, tracks: [track])
                app.showToast("Playlist Created")
            }
            ForEach(app.library.playlists) { playlist in
                Button(playlist.name) {
                    app.library.add(track, to: playlist.id)
                    app.showToast("Added to \(playlist.name)")
                }
            }
        }
    }
}

/// One song in a list: optional number or cover, title, artist, and the menu.
struct TrackRow: View {
    let track: Track
    var number: Int?
    var showsArtwork = false
    var showsArtist = true
    let action: () -> Void

    @Environment(AppModel.self) private var app

    private var isCurrent: Bool { app.playback.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if showsArtwork {
                        ArtworkView(artwork: track.artwork, cornerRadius: 4, points: 48)
                            .frame(width: 48, height: 48)
                    } else if let number {
                        ZStack {
                            if isCurrent {
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative, isActive: app.playback.status.isPlaying)
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(number)").foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .font(.system(size: 16))
                        .frame(width: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title)
                                .font(.system(size: 17))
                                .lineLimit(1)
                            if track.isExplicit { ExplicitBadge() }
                        }
                        if showsArtist {
                            Text(track.artistName)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                TrackMenuItems(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 36, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More for \(track.title)")
        }
        .foregroundStyle(.white)
        .frame(minHeight: showsArtwork ? 58 : 50)
    }
}

/// Loading, failure and empty states for anything that fetches from a service.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.glass)
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}
