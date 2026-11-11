import SwiftUI

enum AppTab: Hashable {
    case home, new, radio, library, search
}

/// The five tabs, with the mini-player floating above the system tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = LaunchOptions.tab ?? AppTab.home
    @Namespace private var playerNamespace

    var body: some View {
        @Bindable var app = app
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                TabStack(initialRoute: LaunchOptions.openAlbum ? app.demoAlbumRoute : nil) { BrowseScreen(page: .home) }
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.new) {
                TabStack { BrowseScreen(page: .new) }
            }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: AppTab.radio) {
                TabStack { BrowseScreen(page: .radio) }
            }
            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                TabStack { LibraryScreen() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                TabStack { SearchScreen() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.accent)
        .tabViewBottomAccessory {
            MiniPlayer()
                .matchedTransitionSource(id: "player", in: playerNamespace)
        }
        .fullScreenCover(isPresented: $app.isPlayerPresented) {
            NowPlayingScreen(panel: LaunchOptions.panel ?? .artwork)
                .environment(app)
                .navigationTransition(.zoom(sourceID: "player", in: playerNamespace))
                .sheet(isPresented: Binding(get: { SpotifyWebEngine.shared.isPresented }, set: { SpotifyWebEngine.shared.isPresented = $0; if !$0 { SpotifyWebEngine.shared.restoreHost() } })) {
                    SpotifyBrowserScreen()
                }
        }
        .sheet(isPresented: $app.isSettingsPresented) {
            SettingsScreen().environment(app)
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(message: toast).padding(.top, 6)
            }
        }
        .alert("Playback", isPresented: Binding(get: { app.playback.problem != nil }, set: { if !$0 { app.playback.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.playback.problem ?? "")
        }
        .sheet(isPresented: Binding(get: { !app.isPlayerPresented && SpotifyWebEngine.shared.isPresented }, set: { SpotifyWebEngine.shared.isPresented = $0; if !$0 { SpotifyWebEngine.shared.restoreHost() } })) {
            SpotifyBrowserScreen()
        }
        .sheet(isPresented: Binding(
            get: { (app.provider(for: .youtubeMusic) as? YouTubeProvider)?.isSigningIn ?? false },
            set: { if !$0 { (app.provider(for: .youtubeMusic) as? YouTubeProvider)?.cancelSignIn() } }
        )) {
            if let youtube = app.provider(for: .youtubeMusic) as? YouTubeProvider {
                YouTubeSignInScreen(provider: youtube)
            }
        }
        .background {
            SpotifyAudioHost().frame(width: 180, height: 100).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
        }
        .sensoryFeedback(.selection, trigger: tab)
        .task {
            await LaunchOptions.run(app)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-spotify-browser") { SpotifyWebEngine.shared.isPresented = true }
            #endif
        }
        .preferredColorScheme(.dark)
    }
}

/// One tab's navigation stack and the destinations every tab shares.
private struct TabStack<Root: View>: View {
    var initialRoute: Route?
    @ViewBuilder var root: Root

    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            root.navigationDestination(for: Route.self) { route in
                switch route {
                case .album(let album):
                    CollectionScreen(source: .album(album))
                case .playlist(let playlist):
                    CollectionScreen(source: .playlist(playlist))
                case .artist(let artist):
                    ArtistScreen(artist: artist)
                case .artistName(let name):
                    LibraryArtistScreen(name: name)
                case .library(let section):
                    LibraryListScreen(section: section)
                case .shelf(let shelf):
                    ShelfListScreen(title: shelf.title ?? "") { [shelf] }
                case .category(let category):
                    ShelfListScreen(title: category.name) {
                        guard let provider = app.provider(for: category.id.service) else {
                            throw ProviderError.notConnected(category.id.service)
                        }
                        return try await provider.categoryShelves(category.id)
                    }
                }
            }
        }
        // Toolbar buttons are white, as in the references; the accent is kept for the tab bar.
        .tint(.white)
        .onAppear {
            if let initialRoute, path.isEmpty { path = [initialRoute] }
        }
    }
}

/// Launch arguments for driving the app from scripts: screenshots and UI checks.
/// Example: `-tab library`, `-open album`, `-autoplay 1`, `-player lyrics`, `-seek 20`.
/// They only choose what is on screen; they never change stored data.
enum LaunchOptions {
    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-" + name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var tab: AppTab? {
        switch value("tab") {
        case "home": .home
        case "new": .new
        case "radio": .radio
        case "library": .library
        case "search": .search
        default: nil
        }
    }

    static var openAlbum: Bool { value("open") == "album" }

    static var panel: NowPlayingScreen.Panel? {
        switch value("player") {
        case "artwork": .artwork
        case "lyrics": .lyrics
        case "queue": .queue
        default: nil
        }
    }

    static func run(_ app: AppModel) async {
        if value("settings") != nil { app.isSettingsPresented = true }
        guard let autoplay = value("autoplay").flatMap(Int.init) else { return }
        guard let provider = app.provider(for: .demo),
              let shelves = try? await provider.newShelves(),
              let releases = shelves.last?.entries, !releases.isEmpty,
              case .album(let album) = releases[min(max(autoplay - 1, 0), releases.count - 1)].item,
              let detail = try? await provider.albumDetail(album.id)
        else { return }
        app.play(detail.tracks, context: .album(album))
        if let seconds = value("seek").flatMap(Double.init) {
            // Wait for the track to load before moving the playhead.
            for _ in 0..<100 where app.playback.status != .playing { try? await Task.sleep(for: .milliseconds(100)) }
            app.playback.seek(to: seconds)
        }
        if value("pause") != nil { app.playback.pause() }
        if panel != nil { app.isPlayerPresented = true }
    }
}
