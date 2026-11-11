import SwiftUI

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isNamingPlaylist = false
    @State private var isEditingSections = false
    @State private var newPlaylistName = ""

    private var sections: [LibrarySection] {
        LibrarySection.allCases.filter { !app.settings.hiddenLibrarySections.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Library") {
                    HStack(spacing: 4) {
                        headerButton("text.badge.plus", label: "New Playlist") {
                            newPlaylistName = ""
                            isNamingPlaylist = true
                        }
                        headerButton("checklist", label: "Edit Library Sections") { isEditingSections = true }
                    }
                    .padding(.horizontal, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                ForEach(sections) { section in
                    NavigationLink(value: Route.library(section)) {
                        HStack(spacing: 14) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 21))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 30)
                            Text(section.title)
                                .font(.system(size: 17))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(white: 0.35))
                        }
                        .frame(height: 51)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.margin)
                    Divider().overlay(Theme.separator).padding(.leading, 60).padding(.trailing, Theme.margin)
                }

                Text("Recently Added")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, Theme.margin)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)

                if let problem = app.remoteLibraryProblem {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Button("Try Again") { Task { await app.refreshRemoteLibrary() } }
                            .buttonStyle(.glass)
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 16)
                }

                if app.libraryRecentlyAdded.isEmpty, app.isLoadingRemoteLibrary {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                } else if app.libraryRecentlyAdded.isEmpty {
                    Text("Albums and playlists you add will show up here. Tap + on an album, or import your own files under Downloaded.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, Theme.margin)
                } else {
                    MediaGrid(items: app.libraryRecentlyAdded)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(.black)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .refreshable { await app.refreshRemoteLibrary() }
        .task { if app.remoteLibrary.isEmpty { await app.refreshRemoteLibrary() } }
        .alert("New Playlist", isPresented: $isNamingPlaylist) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                app.library.createPlaylist(named: name.isEmpty ? "New Playlist" : name)
            }
        }
        .sheet(isPresented: $isEditingSections) { LibrarySectionEditor() }
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Choose which rows appear at the top of the Library tab.
struct LibrarySectionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(LibrarySection.allCases) { section in
                Toggle(isOn: Binding(
                    get: { !app.settings.hiddenLibrarySections.contains(section) },
                    set: { shown in
                        if shown { app.settings.hiddenLibrarySections.remove(section) } else { app.settings.hiddenLibrarySections.insert(section) }
                    })
                ) {
                    Label(section.title, systemImage: section.symbol)
                }
                .tint(Theme.accent)
            }
            .navigationTitle("Library Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The list behind each Library row.
struct LibraryListScreen: View {
    let section: LibrarySection

    @Environment(AppModel.self) private var app
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var importMessage: String?
    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.vertical, 12)
        }
        .background(.black)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if section == .downloaded {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isWorking { ProgressView() }
                    Menu("Add Music", systemImage: "plus") {
                        Button("Import Files or Folders", systemImage: "square.and.arrow.down") { isImporting = true }
                        Button("Rescan Music Folder", systemImage: "arrow.clockwise") {
                            run { await app.local.rescan() }
                        }
                    }
                }
            }
            if section == .playlists {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Playlist", systemImage: "plus") {
                        newPlaylistName = ""
                        isNamingPlaylist = true
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: LocalProvider.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): run { await app.local.importItems(at: urls) }
            case .failure(let error): importMessage = "The files couldn't be opened (\(error.localizedDescription))."
            }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
        .alert("New Playlist", isPresented: $isNamingPlaylist) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                app.library.createPlaylist(named: name.isEmpty ? "New Playlist" : name)
            }
        }
    }

    private func run(_ work: @escaping () async -> ImportReport) {
        isWorking = true
        Task {
            let report = await work()
            isWorking = false
            importMessage = report.summary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .playlists:
            let lists = app.libraryPlaylists
            if lists.isEmpty {
                empty("No Playlists", "music.note.list", "Create one with the + button, or save a playlist from any service.")
            }
            ForEach(lists) { playlist in
                NavigationLink(value: Route.playlist(playlist)) {
                    HStack(spacing: 14) {
                        ArtworkView(artwork: playlist.artwork, cornerRadius: 6, points: 64)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).font(.system(size: 17))
                            if let curator = playlist.curator {
                                Text(curator).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.margin)
                Divider().overlay(Theme.separator).padding(.leading, 98)
            }
        case .artists:
            if app.libraryArtistNames.isEmpty {
                empty("No Artists", "music.microphone", "Artists appear here once you add or import their music.")
            }
            ForEach(app.libraryArtistNames, id: \.self) { name in
                NavigationLink(value: Route.artistName(name)) {
                    HStack {
                        Text(name).font(.system(size: 17))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    .frame(height: 50)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.margin)
                Divider().overlay(Theme.separator).padding(.leading, Theme.margin)
            }
        case .albums:
            if app.libraryAlbums.isEmpty {
                empty("No Albums", "square.stack", "Tap + on an album page to keep it here.")
            } else {
                MediaGrid(items: app.libraryAlbums.map { .album($0) })
            }
        case .songs:
            songList(app.librarySongs, emptyTitle: "No Songs", emptyText: "Favorite a song, add it to your library, or import your own files.")
        case .downloaded:
            songList(app.library.localTracks, emptyTitle: "No Files Yet",
                     emptyText: "Use + to import audio files or folders. You can also copy files into Fiber's Music folder in the Files app, then rescan.")
        }
    }

    @ViewBuilder
    private func songList(_ songs: [Track], emptyTitle: String, emptyText: String) -> some View {
        if songs.isEmpty {
            empty(emptyTitle, "music.note", emptyText)
        } else {
            HStack(spacing: 14) {
                Button { app.play(songs) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 34) }
                Button { app.play(songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 34) }
            }
            .font(.system(size: 17, weight: .semibold))
            .buttonStyle(.glass)
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 10)
            ForEach(songs) { track in
                TrackRow(track: track, showsArtwork: true) {
                    app.play(songs, at: songs.firstIndex { $0.id == track.id } ?? 0)
                }
                .padding(.horizontal, Theme.margin)
                .contextMenu {
                    if track.id.service == .local {
                        Button("Delete from Library", systemImage: "trash", role: .destructive) { app.local.delete(track) }
                    }
                }
                Divider().overlay(Theme.separator).padding(.leading, 80)
            }
        }
    }

    private func empty(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
            .padding(.top, 60)
    }
}
