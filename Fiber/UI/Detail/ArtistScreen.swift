import SwiftUI

/// An artist from a catalog: top songs and albums.
struct ArtistScreen: View {
    let artist: Artist

    @Environment(AppModel.self) private var app
    @State private var state = Loadable<ArtistDetail>.loading

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    ArtworkView(artwork: artist.artwork, cornerRadius: 90, points: 180)
                        .frame(width: 180, height: 180)
                    Text(artist.name)
                        .font(.system(size: 28, weight: .bold))
                    if let genre = artist.genre {
                        Text(genre).font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.top, 8)

                switch state {
                case .loading:
                    ProgressView().padding(.top, 40)
                case .failed(let message):
                    FailureView(message: message) { Task { await load() } }
                case .loaded(let detail):
                    ArtistBody(songs: detail.topTracks, albums: detail.albums, context: .artist(artist))
                }
            }
            .padding(.bottom, 32)
        }
        .background(.black)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id) { await load() }
    }

    private func load() async {
        guard let provider = app.provider(for: artist.id.service) else {
            state = .failed(ProviderError.notConnected(artist.id.service).localizedDescription)
            return
        }
        do {
            state = .loaded(try await provider.artistDetail(artist.id))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// An artist as it exists in the user's library, grouped by name.
struct LibraryArtistScreen: View {
    let name: String

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            ArtistBody(songs: app.librarySongs.filter { $0.artistName == name },
                       albums: app.libraryAlbums.filter { $0.artistName == name }, context: nil)
                .padding(.vertical, 12)
        }
        .background(.black)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct ArtistBody: View {
    let songs: [Track]
    let albums: [Album]
    let context: MediaItem?

    @Environment(AppModel.self) private var app
    @State private var showsAllSongs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !songs.isEmpty {
                HStack(spacing: 14) {
                    Button {
                        app.play(songs, context: context)
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 34)
                    }
                    Button {
                        app.play(songs, shuffled: true, context: context)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 34)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .buttonStyle(.glass)
                .padding(.horizontal, Theme.margin)

                VStack(alignment: .leading, spacing: 8) {
                    ShelfHeader(title: "Top Songs")
                    VStack(spacing: 0) {
                        ForEach(showsAllSongs ? songs : Array(songs.prefix(5))) { track in
                            TrackRow(track: track, showsArtwork: true, showsArtist: false) {
                                app.play(songs, at: songs.firstIndex { $0.id == track.id } ?? 0, context: context)
                            }
                            Divider().overlay(Theme.separator).padding(.leading, 60)
                        }
                        if songs.count > 5 {
                            Button(showsAllSongs ? "Show Less" : "Show All \(songs.count) Songs") {
                                withAnimation(.snappy) { showsAllSongs.toggle() }
                            }
                            .font(.system(size: 15, weight: .medium))
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
            }
            if !albums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "Albums")
                    HorizontalShelf(spacing: 12) {
                        ForEach(albums) { SquareCard(item: .album($0)) }
                    }
                }
            }
            if songs.isEmpty, albums.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "music.microphone",
                                       description: Text("Songs and albums by this artist will appear once they're in your library."))
            }
        }
    }
}
