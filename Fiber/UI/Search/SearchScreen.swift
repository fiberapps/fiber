import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var categories: [BrowseCategory] = []
    @State private var results = Loadable<(catalog: SearchResults, library: SearchResults)>.loaded((SearchResults(), SearchResults()))
    @FocusState private var isFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Search")
                searchField
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 12)

                if trimmedQuery.isEmpty {
                    categoryGrid
                } else {
                    resultsList
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(.black)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task(id: app.browsingLoadKey) {
            // Categories are optional decoration; a service without them just shows none.
            categories = (try? await app.browsingProvider?.browseCategories()) ?? []
        }
        .task(id: app.browsingLoadKey + ":" + trimmedQuery) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            TextField("Artists, Songs, Albums, and More", text: $query)
                .font(.system(size: 17))
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color(white: 0.11), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], spacing: 12) {
            ForEach(categories) { category in
                NavigationLink(value: Route.category(category)) {
                    Color.clear
                        .frame(height: 106)
                        .overlay {
                            ArtworkView(artwork: category.artwork, cornerRadius: 0, points: 190)
                                .frame(width: 190, height: 190)
                        }
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            Text(category.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
                                .padding(12)
                        }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    @ViewBuilder
    private var resultsList: some View {
        switch results {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        case .failed(let message):
            FailureView(message: message) { Task { await search() } }
        case .loaded(let found):
            if found.catalog.isEmpty, found.library.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery).padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    section("In Your Library", found.library)
                    section(app.browsingProvider?.service.displayName ?? "Catalog", found.catalog)
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ found: SearchResults) -> some View {
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title)
                if !found.tracks.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(found.tracks.prefix(8)) { track in
                            TrackRow(track: track, showsArtwork: true) { app.play([track]) }
                            Divider().overlay(Theme.separator).padding(.leading, 60)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
                let collections: [MediaItem] = found.artists.map { .artist($0) } + found.albums.map { .album($0) } + found.playlists.map { .playlist($0) }
                if !collections.isEmpty {
                    HorizontalShelf(spacing: 12) {
                        ForEach(collections) { SquareCard(item: $0, side: 140) }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func search() async {
        let term = trimmedQuery
        guard !term.isEmpty else {
            results = .loaded((SearchResults(), SearchResults()))
            return
        }
        results = .loading
        // Wait for a pause in typing before asking the service.
        do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
        do {
            let library = try await app.local.search(term)
            let catalog = try await app.browsingProvider?.search(term) ?? SearchResults()
            guard !Task.isCancelled else { return }
            results = .loaded((catalog, library))
        } catch is CancellationError {
            return
        } catch {
            results = .failed(error.localizedDescription)
        }
    }
}
