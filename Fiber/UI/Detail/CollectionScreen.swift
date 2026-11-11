import SwiftUI

/// The album page from the references, also used for playlists: the cover runs
/// edge to edge under the status bar and melts into a colour taken from it.
struct CollectionScreen: View {
    enum Source: Hashable {
        case album(Album)
        case playlist(Playlist)

        var item: MediaItem {
            switch self {
            case .album(let album): .album(album)
            case .playlist(let playlist): .playlist(playlist)
            }
        }
    }

    let source: Source

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var state = Loadable<[Track]>.loading
    @State private var notesExpanded = false
    @State private var isEditing = false
    @State private var isConfirmingDelete = false

    private var userPlaylist: UserPlaylist? {
        guard case .playlist(let playlist) = source, playlist.isEditable else { return nil }
        return app.library.playlist(playlist.id)
    }

    private var item: MediaItem { userPlaylist.map { .playlist($0.playlist) } ?? source.item }

    private var tracks: [Track] {
        if let userPlaylist { return userPlaylist.tracks }
        if case .loaded(let tracks) = state { return tracks }
        return []
    }

    private var metaLine: String {
        switch source {
        case .album(let album):
            ([album.genre, album.year.map(String.init)].compactMap { $0 } + album.formatBadges).joined(separator: " · ")
        case .playlist(let playlist):
            playlist.isEditable ? "Playlist" : (playlist.curator ?? "Playlist")
        }
    }

    private var notes: String? {
        switch source {
        case .album(let album): album.notes
        case .playlist(let playlist): playlist.notes
        }
    }

    var body: some View {
        PaletteReader(artwork: item.artwork) { palette in
            ScrollView {
                VStack(spacing: 0) {
                    header(palette).frame(maxWidth: 620)
                    trackList
                }
                .padding(.bottom, 32)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .background(palette.floor.color.ignoresSafeArea())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        .task(id: source) { await load() }
        .sheet(isPresented: $isEditing) {
            if let userPlaylist { PlaylistEditor(playlist: userPlaylist) }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let userPlaylist { app.library.deletePlaylist(userPlaylist.id) }
                dismiss()
            }
        } message: {
            Text("The songs stay in your library.")
        }
    }

    // MARK: Header

    private func header(_ palette: ArtPalette) -> some View {
        VStack(spacing: 0) {
            ArtworkView(artwork: item.artwork, cornerRadius: 0, points: 430)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                // Pulling down stretches the cover instead of showing a gap.
                .visualEffect { content, proxy in
                    let pull = max(proxy.frame(in: .scrollView).minY, 0)
                    return content
                        .scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .bottom)
                }

            VStack(spacing: 2) {
                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                if case .album(let album) = source {
                    Text(album.artistName)
                        .font(.system(size: 20))
                }
                Text(metaLine)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.75)
                    .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.margin)
            .padding(.top, -34)

            actionRow
                .padding(.top, 14)

            if let notes {
                Button {
                    withAnimation(.snappy) { notesExpanded.toggle() }
                } label: {
                    Text(notes)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(notesExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.margin)
                .padding(.top, 16)
                .accessibilityHint(notesExpanded ? "Collapses the description" : "Shows the full description")
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            circleButton("shuffle", label: "Shuffle") {
                app.play(tracks, shuffled: true, context: item)
            }
            Button {
                app.play(tracks, context: item)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 160, height: 48)
                    .background(.white, in: .capsule)
            }
            .buttonStyle(PressableStyle())
            if userPlaylist != nil {
                circleButton("pencil", label: "Edit Playlist") { isEditing = true }
            } else {
                let saved = app.library.isSaved(item.id)
                circleButton(saved ? "checkmark" : "plus", label: saved ? "Remove from Library" : "Add to Library") {
                    app.toggleSaved(item)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
        }
        .disabled(tracks.isEmpty)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.14), in: .circle)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    // MARK: Tracks

    @ViewBuilder
    private var trackList: some View {
        switch state {
        case .loading where userPlaylist == nil:
            ProgressView().tint(.white).padding(.top, 40)
        case .failed(let message) where userPlaylist == nil:
            FailureView(message: message) { Task { await load() } }
        default:
            let isAlbum = if case .album = source { true } else { false }
            let albumArtist = if case .album(let album) = source { album.artistName } else { "" }
            VStack(spacing: 0) {
                Divider().overlay(Theme.separator)
                if tracks.isEmpty {
                    Text("No songs yet. Use “Add to a Playlist” from any song's menu.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                }
                ForEach(Array(tracks.enumerated()), id: \.offset) { position, track in
                    TrackRow(track: track, number: isAlbum ? (track.trackNumber ?? position + 1) : nil,
                             showsArtwork: !isAlbum, showsArtist: !isAlbum || track.artistName != albumArtist) {
                        app.play(tracks, at: position, context: item)
                    }
                    Divider().overlay(Theme.separator).padding(.leading, isAlbum ? 40 : 60)
                }
                if !tracks.isEmpty {
                    let minutes = Int((tracks.reduce(0) { $0 + $1.duration } / 60).rounded())
                    Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs"), \(minutes) \(minutes == 1 ? "minute" : "minutes")")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 18)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if case .album(let album) = source, let url = album.shareURL {
                ShareLink(item: url)
            }
            Menu("More", systemImage: "ellipsis") {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    for track in tracks.reversed() { app.playback.playNext(track) }
                    app.showToast("Playing Next")
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    app.playback.addToQueue(tracks)
                    app.showToast("Added to Queue")
                }
                if userPlaylist != nil {
                    Divider()
                    Button("Edit Playlist", systemImage: "pencil") { isEditing = true }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                } else {
                    Button(app.library.isSaved(item.id) ? "Remove from Library" : "Add to Library",
                           systemImage: app.library.isSaved(item.id) ? "minus.circle" : "plus") {
                        app.toggleSaved(item)
                    }
                }
            }
            .disabled(tracks.isEmpty && userPlaylist == nil)
        }
    }

    private func load() async {
        guard userPlaylist == nil else { return }
        guard let provider = app.provider(for: item.id.service) else {
            state = .failed(ProviderError.notConnected(item.id.service).localizedDescription)
            return
        }
        do {
            switch source {
            case .album(let album): state = .loaded(try await provider.albumDetail(album.id).tracks)
            case .playlist(let playlist): state = .loaded(try await provider.playlistDetail(playlist.id).tracks)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Rename a playlist, reorder its songs, or remove some.
struct PlaylistEditor: View {
    let playlist: UserPlaylist

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tracks: [Track] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Playlist Name", text: $name)
                }
                Section("Songs") {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                        VStack(alignment: .leading) {
                            Text(track.title)
                            Text(track.artistName).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .onMove { tracks.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { tracks.remove(atOffsets: $0) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != playlist.name { app.library.renamePlaylist(playlist.id, to: trimmed) }
                        if tracks != playlist.tracks { app.library.setTracks(tracks, in: playlist.id) }
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            name = playlist.name
            tracks = playlist.tracks
        }
    }
}
