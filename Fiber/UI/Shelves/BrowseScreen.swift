import SwiftUI

/// Home, New and Radio share this screen: a title and the shelves the
/// browsing service returns for that tab.
struct BrowseScreen: View {
    enum Page: String {
        case home = "Home", new = "New", radio = "Radio"
    }

    let page: Page

    @Environment(AppModel.self) private var app
    @State private var state = Loadable<[Shelf]>.loading

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: page.rawValue)
                    if app.browsingProvider?.service == .demo { DemoNotice() }
                }
                content
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(.black)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task(id: app.browsingLoadKey) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        case .failed(let message):
            FailureView(message: message) { Task { await load() } }
                .padding(.top, 60)
        case .loaded(let shelves):
            if shelves.isEmpty { emptyState }
            ForEach(Array(shelves.enumerated()), id: \.element.id) { position, shelf in
                ShelfView(shelf: shelf)
                // Recently Played comes from the user's own history, right after the first shelf.
                if page == .home, position == 0, !app.library.recents.isEmpty {
                    ShelfView(shelf: Shelf(id: "recently-played", title: "Recently Played", layout: .squares,
                                           entries: app.library.recents.prefix(12).map { ShelfEntry($0) }, canExpand: true))
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let name = app.browsingProvider?.service.displayName ?? "this service"
        Group {
            if page == .radio {
                ContentUnavailableView("No Radio on \(name)", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("\(name) doesn't offer radio stations to other apps. Choose a different default service in Settings to listen to radio."))
            } else {
                ContentUnavailableView("Nothing to Show Yet", systemImage: "music.note.list",
                                       description: Text("Listen to something on \(name) and it will show up here."))
            }
        }
        .padding(.top, 40)
    }

    private func load() async {
        guard let provider = app.browsingProvider else {
            state = .failed(app.browsingProblem)
            return
        }
        if case .failed = state { state = .loading }
        do {
            let shelves = switch page {
            case .home: try await provider.homeShelves()
            case .new: try await provider.newShelves()
            case .radio: try await provider.radioShelves()
            }
            guard !Task.isCancelled else { return }
            state = .loaded(shelves)
        } catch ProviderError.unsupported {
            guard !Task.isCancelled else { return }
            state = .loaded([])
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// Says plainly that what's on screen is the built-in demo, not a live service.
struct DemoNotice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.isSettingsPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                Text("Demo catalog · invented music")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings to connect a music service")
    }
}

/// "See all" for a shelf, and the page behind a search category.
struct ShelfListScreen: View {
    let title: String
    let load: () async throws -> [Shelf]

    @Environment(AppModel.self) private var app
    @State private var state = Loadable<[Shelf]>.loading

    var body: some View {
        ScrollView {
            switch state {
            case .loading:
                ProgressView().padding(.top, 120)
            case .failed(let message):
                FailureView(message: message) { Task { await reload() } }
            case .loaded(let shelves):
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(shelves) { shelf in
                        if shelves.count == 1 {
                            expanded(shelf)
                        } else {
                            ShelfView(shelf: shelf)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task { await reload() }
    }

    @ViewBuilder
    private func expanded(_ shelf: Shelf) -> some View {
        let tracks = shelf.entries.compactMap { if case .track(let track) = $0.item { track } else { nil } }
        if tracks.count == shelf.entries.count, !tracks.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(tracks) { track in
                    TrackRow(track: track, showsArtwork: true) {
                        app.play(tracks, at: tracks.firstIndex { $0.id == track.id } ?? 0)
                    }
                    Divider().overlay(Theme.separator).padding(.leading, 60)
                }
            }
            .padding(.horizontal, Theme.margin)
        } else {
            MediaGrid(items: shelf.entries.map(\.item))
        }
    }

    private func reload() async {
        do {
            state = .loaded(try await load())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
