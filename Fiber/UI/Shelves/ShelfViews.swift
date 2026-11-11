import SwiftUI

/// Draws one shelf in the layout its service asked for.
struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = shelf.title {
                ShelfHeader(title: title, route: shelf.canExpand ? .shelf(shelf) : nil)
            }
            switch shelf.layout {
            case .heroCards:
                HorizontalShelf(spacing: 12) {
                    ForEach(shelf.entries) { HeroCard(entry: $0) }
                }
            case .squares:
                HorizontalShelf(spacing: 12) {
                    ForEach(shelf.entries) { SquareCard(item: $0.item) }
                }
            case .editorial:
                HorizontalShelf(spacing: 12) {
                    ForEach(shelf.entries) { EditorialCard(entry: $0) }
                }
            case .onAir:
                HorizontalShelf(spacing: 12) {
                    ForEach(shelf.entries) { OnAirCard(entry: $0) }
                }
            case .songColumns:
                SongColumns(tracks: shelf.entries.compactMap { if case .track(let track) = $0.item { track } else { nil } })
            case .stationGrid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 12)], spacing: 12) {
                    ForEach(shelf.entries) { entry in
                        MediaLink(item: entry.item) {
                            ArtworkView(artwork: entry.item.artwork, cornerRadius: 22, points: 130)
                        }
                        .accessibilityLabel(entry.item.title)
                    }
                }
                .padding(.horizontal, Theme.margin)
            }
        }
    }
}

/// A horizontally scrolling row that snaps to its cards and bleeds to the screen edges.
struct HorizontalShelf<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                content
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Theme.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

struct SquareCard: View {
    let item: MediaItem
    var side: CGFloat = 169

    var body: some View {
        MediaLink(item: item) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(artwork: item.artwork, cornerRadius: isRound ? side / 2 : 8, points: side)
                    .frame(width: side, height: side)
                CoverCaption(title: item.title, subtitle: item.subtitle, isExplicit: item.isExplicit)
                    .multilineTextAlignment(isRound ? .center : .leading)
            }
            .frame(width: side)
        }
    }

    private var isRound: Bool {
        if case .artist = item { true } else { false }
    }
}

/// Tall "Top Picks" card: the cover on top, continued downward in its own colour.
struct HeroCard: View {
    let entry: ShelfEntry

    private let width: CGFloat = 260
    private let height: CGFloat = 346

    var body: some View {
        MediaLink(item: entry.item) {
            PaletteReader(artwork: entry.item.artwork) { palette in
                ZStack(alignment: .bottomLeading) {
                    palette.edge.color
                    VStack(spacing: 0) {
                        ArtworkView(artwork: entry.item.artwork, cornerRadius: 0, points: width)
                            .frame(width: width, height: width)
                            .mask {
                                LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let kicker = entry.kicker {
                            Text(kicker)
                                .font(.system(size: 13))
                                .opacity(0.9)
                        }
                        Text(entry.item.title)
                            .font(.system(size: 15, weight: .bold))
                        if let subtitle = entry.item.subtitle {
                            Text(subtitle.uppercased())
                                .font(.system(size: 13))
                                .opacity(0.9)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                    .padding(16)
                }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wide "New" card: kicker and headline above a landscape crop of the cover.
struct EditorialCard: View {
    let entry: ShelfEntry

    private let width: CGFloat = 350

    var body: some View {
        MediaLink(item: entry.item) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((entry.kicker ?? "").uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.secondaryText)
                    Text(entry.headline ?? entry.item.title)
                        .font(.system(size: 20))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                Color.clear
                    .frame(width: width, height: 233)
                    .overlay {
                        ArtworkView(artwork: entry.item.artwork, cornerRadius: 0, points: width)
                            .frame(width: width, height: width)
                    }
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.item.title).font(.system(size: 15, weight: .bold))
                            if let subtitle = entry.item.subtitle { Text(subtitle).font(.system(size: 13)).opacity(0.9) }
                        }
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                        .padding(14)
                    }
            }
            .frame(width: width, alignment: .leading)
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Radio "On Air Now" card: artwork with a caption band in the cover's colour.
struct OnAirCard: View {
    let entry: ShelfEntry

    private let width: CGFloat = 350

    var body: some View {
        MediaLink(item: entry.item) {
            PaletteReader(artwork: entry.item.artwork) { palette in
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: width, height: 233)
                        .overlay(alignment: .top) {
                            ArtworkView(artwork: entry.item.artwork, cornerRadius: 0, points: width)
                                .frame(width: width, height: width)
                        }
                        .clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        if let kicker = entry.kicker {
                            Text(kicker.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.4)
                                .opacity(0.75)
                        }
                        Text(entry.headline ?? entry.item.title)
                            .font(.system(size: 15, weight: .bold))
                        if let caption = entry.caption {
                            Text(caption).font(.system(size: 15)).opacity(0.9)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 99)
                    .background(Color(white: 0.5).opacity(0.9))
                    .background(palette.edge.color)
                }
                .frame(width: width)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Paged columns of four songs, as in "Best New Songs".
struct SongColumns: View {
    let tracks: [Track]

    @Environment(AppModel.self) private var app

    private var columns: [[Track]] {
        stride(from: 0, to: tracks.count, by: 4).map { Array(tracks[$0..<min($0 + 4, tracks.count)]) }
    }

    var body: some View {
        HorizontalShelf(spacing: 12) {
            ForEach(columns, id: \.first?.id) { column in
                VStack(spacing: 0) {
                    ForEach(column) { track in
                        TrackRow(track: track, showsArtwork: true) {
                            app.play(tracks, at: tracks.firstIndex { $0.id == track.id } ?? 0)
                        }
                        if track.id != column.last?.id {
                            Divider().overlay(Theme.separator).padding(.leading, 60)
                        }
                    }
                }
                .frame(width: 350)
            }
        }
    }
}

/// A full-screen grid for "see all", category pages and library lists.
struct MediaGrid: View {
    let items: [MediaItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 20) {
            ForEach(items) { item in
                GridCard(item: item)
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

struct GridCard: View {
    let item: MediaItem

    var body: some View {
        MediaLink(item: item) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(artwork: item.artwork, cornerRadius: 8, points: 190)
                CoverCaption(title: item.title, subtitle: item.subtitle, isExplicit: item.isExplicit)
            }
        }
    }
}
