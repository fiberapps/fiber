import Foundation
import SwiftData

@Model
final class SavedItem {
    /// "<kind>|<service>:<id>"
    @Attribute(.unique) var key: String
    var kind: String
    /// A JSON-encoded `MediaItem` snapshot, so the library works offline and across services.
    var payload: Data
    var date: Date

    init(key: String, kind: String, payload: Data, date: Date) {
        self.key = key
        self.kind = kind
        self.payload = payload
        self.date = date
    }
}

@Model
final class StoredPlaylist {
    @Attribute(.unique) var identifier: String
    var name: String
    var created: Date
    /// JSON-encoded `[Track]`.
    var payload: Data

    init(identifier: String, name: String, created: Date, payload: Data) {
        self.identifier = identifier
        self.name = name
        self.created = created
        self.payload = payload
    }
}

nonisolated struct UserPlaylist: Identifiable, Hashable, Sendable {
    var id: MediaID
    var name: String
    var created: Date
    var tracks: [Track]

    var playlist: Playlist {
        Playlist(id: id, name: name, curator: "\(tracks.count) \(tracks.count == 1 ? "song" : "songs")",
                 artwork: tracks.first?.artwork ?? .generated(seed: DemoCatalog.seed(id.raw), style: .bloom, label: nil),
                 notes: nil, isEditable: true)
    }
}

/// The user's own library: saved items, favourites, play history, imported
/// files and playlists. Kept in memory for the interface and written through
/// to SwiftData on every change.
@Observable
final class LibraryStore {
    private enum Kind: String {
        case library, favorite, recent, local
    }

    private(set) var saved: [MediaItem] = []
    private(set) var favorites: [Track] = []
    private(set) var recents: [MediaItem] = []
    private(set) var localTracks: [Track] = []
    private(set) var playlists: [UserPlaylist] = []
    /// Set when the library can't be read or written, and shown in Settings.
    private(set) var storageProblem: String?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(inMemory: Bool = false) {
        let schema = Schema([SavedItem.self, StoredPlaylist.self])
        var problem: String?
        let opened: ModelContainer
        do {
            opened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory))
        } catch {
            // Keep the app usable, and say plainly that nothing will be kept.
            problem = "The library couldn't be opened, so changes won't be saved this session (\(error.localizedDescription))."
            do {
                opened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            } catch {
                fatalError("SwiftData could not create even an in-memory store: \(error)")
            }
        }
        container = opened
        storageProblem = problem
        reload()
    }

    // MARK: Reading

    private func reload() {
        do {
            let items = try context.fetch(FetchDescriptor<SavedItem>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
            func media(_ kind: Kind) -> [MediaItem] {
                items.filter { $0.kind == kind.rawValue }.compactMap { try? decoder.decode(MediaItem.self, from: $0.payload) }
            }
            func tracks(_ kind: Kind) -> [Track] {
                media(kind).compactMap { if case .track(let track) = $0 { track } else { nil } }
            }
            saved = media(.library)
            favorites = tracks(.favorite)
            recents = media(.recent)
            localTracks = tracks(.local).sorted {
                ($0.albumTitle ?? "", $0.trackNumber ?? 0, $0.title) < ($1.albumTitle ?? "", $1.trackNumber ?? 0, $1.title)
            }
            let stored = try context.fetch(FetchDescriptor<StoredPlaylist>(sortBy: [SortDescriptor(\.created, order: .reverse)]))
            playlists = stored.map {
                UserPlaylist(id: MediaID(service: .local, raw: $0.identifier), name: $0.name, created: $0.created,
                             tracks: (try? decoder.decode([Track].self, from: $0.payload)) ?? [])
            }
        } catch {
            storageProblem = "The library couldn't be read (\(error.localizedDescription))."
        }
    }

    private func commit() {
        do {
            try context.save()
        } catch {
            storageProblem = "A library change couldn't be saved (\(error.localizedDescription))."
        }
        reload()
    }

    private func item(_ kind: Kind, _ id: MediaID) -> SavedItem? {
        let key = "\(kind.rawValue)|\(id.key)"
        return try? context.fetch(FetchDescriptor<SavedItem>(predicate: #Predicate { $0.key == key })).first
    }

    private func put(_ kind: Kind, _ media: MediaItem) {
        guard let payload = try? encoder.encode(media) else { return }
        if let existing = item(kind, media.id) {
            existing.payload = payload
            existing.date = .now
        } else {
            context.insert(SavedItem(key: "\(kind.rawValue)|\(media.id.key)", kind: kind.rawValue, payload: payload, date: .now))
        }
    }

    // MARK: Library and favourites

    func isSaved(_ id: MediaID) -> Bool { saved.contains { $0.id == id } }

    func toggleSaved(_ media: MediaItem) {
        if let existing = item(.library, media.id) { context.delete(existing) } else { put(.library, media) }
        commit()
    }

    func isFavorite(_ id: MediaID) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ track: Track) {
        if let existing = item(.favorite, track.id) { context.delete(existing) } else { put(.favorite, .track(track)) }
        commit()
    }

    func recordPlayed(_ media: MediaItem) {
        put(.recent, media)
        // Keep the history short.
        if let all = try? context.fetch(FetchDescriptor<SavedItem>(
            predicate: #Predicate { $0.kind == "recent" }, sortBy: [SortDescriptor(\.date, order: .reverse)])) {
            for stale in all.dropFirst(40) { context.delete(stale) }
        }
        commit()
    }

    // MARK: Imported files

    func addLocal(_ tracks: [Track]) {
        for track in tracks { put(.local, .track(track)) }
        commit()
    }

    func removeLocal(_ id: MediaID) {
        if let existing = item(.local, id) { context.delete(existing) }
        if let favorite = item(.favorite, id) { context.delete(favorite) }
        commit()
    }

    // MARK: Derived collections

    /// Every song the user owns or saved: imported files, saved songs and favourites.
    var songs: [Track] {
        var seen = Set<MediaID>()
        let savedTracks = saved.compactMap { if case .track(let track) = $0 { track } else { nil } }
        return (localTracks + savedTracks + favorites).filter { seen.insert($0.id).inserted }
    }

    /// Albums built from imported files, grouped by album title and artist.
    var localAlbums: [Album] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in localTracks {
            guard let title = track.albumTitle, !title.isEmpty else { continue }
            let key = "\(title)|\(track.artistName)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        return order.compactMap { key in
            guard let first = groups[key]?.first, let title = first.albumTitle else { return nil }
            return Album(id: MediaID(service: .local, raw: "album|\(key)"), title: title, artistName: first.artistName, artwork: first.artwork)
        }
    }

    func localAlbumTracks(_ id: MediaID) -> [Track] {
        localTracks.filter { "album|\($0.albumTitle ?? "")|\($0.artistName)" == id.raw }
    }

    var albums: [Album] {
        localAlbums + saved.compactMap { if case .album(let album) = $0 { album } else { nil } }
    }

    var artistNames: [String] {
        Array(Set(songs.map(\.artistName) + albums.map(\.artistName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var savedPlaylists: [Playlist] {
        saved.compactMap { if case .playlist(let playlist) = $0 { playlist } else { nil } }
    }

    /// Albums and playlists, newest first, for "Recently Added".
    var recentlyAdded: [MediaItem] {
        let userLists = playlists.map { (date: $0.created, item: MediaItem.playlist($0.playlist)) }
        let collections = saved.filter {
            switch $0 {
            case .album, .playlist: true
            default: false
            }
        }
        // `saved` is already newest first; user playlists and local albums follow.
        return collections + userLists.sorted { $0.date > $1.date }.map(\.item) + localAlbums.map { .album($0) }
    }

    // MARK: Playlists

    private func storedPlaylist(_ id: MediaID) -> StoredPlaylist? {
        let identifier = id.raw
        return try? context.fetch(FetchDescriptor<StoredPlaylist>(predicate: #Predicate { $0.identifier == identifier })).first
    }

    @discardableResult
    func createPlaylist(named name: String, tracks: [Track] = []) -> MediaID {
        let identifier = "playlist-\(UUID().uuidString)"
        let payload = (try? encoder.encode(tracks)) ?? Data("[]".utf8)
        context.insert(StoredPlaylist(identifier: identifier, name: name, created: .now, payload: payload))
        commit()
        return MediaID(service: .local, raw: identifier)
    }

    func playlist(_ id: MediaID) -> UserPlaylist? { playlists.first { $0.id == id } }

    func renamePlaylist(_ id: MediaID, to name: String) {
        storedPlaylist(id)?.name = name
        commit()
    }

    func deletePlaylist(_ id: MediaID) {
        if let stored = storedPlaylist(id) { context.delete(stored) }
        commit()
    }

    func setTracks(_ tracks: [Track], in id: MediaID) {
        guard let stored = storedPlaylist(id), let payload = try? encoder.encode(tracks) else { return }
        stored.payload = payload
        commit()
    }

    func add(_ track: Track, to id: MediaID) {
        guard let current = playlist(id) else { return }
        setTracks(current.tracks + [track], in: id)
    }
}
