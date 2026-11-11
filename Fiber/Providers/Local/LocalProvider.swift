import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

nonisolated struct ImportReport: Sendable {
    var added = 0
    var lyricsFiles = 0
    var skipped: [String] = []

    var summary: String {
        var parts: [String] = []
        parts.append(added == 1 ? "Added 1 song." : "Added \(added) songs.")
        if lyricsFiles > 0 { parts.append(lyricsFiles == 1 ? "Found 1 lyrics file." : "Found \(lyricsFiles) lyrics files.") }
        if !skipped.isEmpty { parts.append("Skipped: " + skipped.joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}

/// Audio files the user imported. Files are copied into Documents/Music, which
/// is also visible in the Files app, and played by Fiber's own engine.
final class LocalProvider: MusicProvider {
    let service = ServiceID.local
    let connection = ConnectionState.notRequired
    let capabilities = ProviderCapabilities(
        browse: false, search: true, radio: false, playback: .inApp, seek: true, equalizer: true,
        backgroundAudio: true, syncedLyrics: true, libraryRead: true, libraryWrite: true,
        summary: "Your own audio files, played by Fiber with the equalizer. Synced lyrics come from .lrc files next to a song.")

    static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, UTType("org.xiph.flac") ?? .audio]
    static let importTypes: [UTType] = audioTypes + [UTType(filenameExtension: "lrc") ?? .plainText, .folder]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac", "mp4"]

    private let library: LibraryStore
    private let audio: FileAudioEngine

    init(library: LibraryStore, audio: FileAudioEngine) {
        self.library = library
        self.audio = audio
    }

    nonisolated static var musicDirectory: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func makeEngine() throws -> any PlaybackEngine { audio }

    func audioURL(for track: Track) async throws -> URL {
        let url = Self.musicDirectory.appendingPathComponent(track.id.raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.playback("The file for “\(track.title)” is missing. It may have been deleted in the Files app.")
        }
        return url
    }

    // MARK: Importing

    /// Copies picked files (or the audio inside picked folders) into the library.
    func importItems(at urls: [URL]) async -> ImportReport {
        var report = ImportReport()
        var newTracks: [Track] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            for file in Self.expand(url) {
                let fileExtension = file.pathExtension.lowercased()
                do {
                    if fileExtension == "lrc" {
                        _ = try Self.copyIntoLibrary(file)
                        report.lyricsFiles += 1
                    } else if Self.audioExtensions.contains(fileExtension), !file.lastPathComponent.hasSuffix(".artwork.mp4") {
                        let name = try Self.copyIntoLibrary(file)
                        newTracks.append(try await Self.readTrack(named: name))
                        report.added += 1
                    }
                } catch {
                    report.skipped.append("\(file.lastPathComponent) (\(error.localizedDescription))")
                }
            }
        }
        library.addLocal(newTracks)
        return report
    }

    /// Indexes files that were dropped into Documents/Music from the Files app
    /// or Finder, and forgets tracks whose files are gone.
    func rescan() async -> ImportReport {
        var report = ImportReport()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.musicDirectory.path)) ?? []
        let known = Set(library.localTracks.map(\.id.raw))
        var newTracks: [Track] = []
        for name in names where !name.hasSuffix(".artwork.mp4") && !known.contains(name) && Self.audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
            do {
                newTracks.append(try await Self.readTrack(named: name))
                report.added += 1
            } catch {
                report.skipped.append("\(name) (\(error.localizedDescription))")
            }
        }
        library.addLocal(newTracks)
        for track in library.localTracks where !names.contains(track.id.raw) {
            library.removeLocal(track.id)
        }
        return report
    }

    func delete(_ track: Track) {
        let url = Self.musicDirectory.appendingPathComponent(track.id.raw)
        // If the file is already gone the track should still leave the library.
        try? FileManager.default.removeItem(at: url)
        library.removeLocal(track.id)
    }

    private nonisolated static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL]) ?? []
    }

    /// Copies a file into Documents/Music, adding a number if the name is taken.
    private nonisolated static func copyIntoLibrary(_ source: URL) throws -> String {
        let folder = musicDirectory
        if source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return source.lastPathComponent }
        let base = source.deletingPathExtension().lastPathComponent
        let fileExtension = source.pathExtension
        var name = source.lastPathComponent
        var attempt = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(attempt).\(fileExtension)"
            attempt += 1
        }
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        return name
    }

    private static func readTrack(named name: String) async throws -> Track {
        let url = musicDirectory.appendingPathComponent(name)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ProviderError.playback("not a playable audio file") }
        let metadata = try await asset.load(.commonMetadata)

        func text(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return nil }
            let value = try? await item.load(.stringValue)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let fallback = Self.splitFileName(url.deletingPathExtension().lastPathComponent)
        let title = await text(.commonIdentifierTitle) ?? fallback.title
        let artist = await text(.commonIdentifierArtist) ?? "Unknown Artist"
        let album = await text(.commonIdentifierAlbumName)

        var artwork = Artwork.generated(seed: DemoCatalog.seed(album ?? title), style: .bloom, label: nil)
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue) {
            // Songs from one album share a cover file, named after the image's hash.
            let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
            let coverName = "\(digest).img"
            let coverURL = ArtworkFiles.url(named: coverName)
            if !FileManager.default.fileExists(atPath: coverURL.path) { try data.write(to: coverURL, options: .atomic) }
            artwork = .file(name: coverName)
        }

        return Track(id: MediaID(service: .local, raw: name), title: title, artistName: artist, albumTitle: album,
                     albumID: album.map { MediaID(service: .local, raw: "album|\($0)|\(artist)") }, artistID: nil,
                     duration: duration, trackNumber: fallback.number, isExplicit: false, artwork: artwork)
    }

    /// "03 Song Name" → (3, "Song Name")
    private nonisolated static func splitFileName(_ name: String) -> (number: Int?, title: String) {
        let digits = name.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return (nil, name) }
        let rest = name.dropFirst(digits.count).drop { " .-_".contains($0) }
        return rest.isEmpty ? (nil, name) : (number, String(rest))
    }

    // MARK: Provider

    func search(_ term: String) async throws -> SearchResults {
        func matches(_ text: String?) -> Bool { text?.localizedStandardContains(term) ?? false }
        return SearchResults(
            tracks: library.songs.filter { matches($0.title) || matches($0.artistName) || matches($0.albumTitle) },
            albums: library.albums.filter { matches($0.title) || matches($0.artistName) },
            artists: [],
            playlists: library.playlists.map(\.playlist).filter { matches($0.name) })
    }

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail {
        guard let album = library.localAlbums.first(where: { $0.id == id }) else { throw ProviderError.notFound }
        return AlbumDetail(album: album, tracks: library.localAlbumTracks(id))
    }

    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail {
        guard let playlist = library.playlist(id) else { throw ProviderError.notFound }
        return PlaylistDetail(playlist: playlist.playlist, tracks: playlist.tracks)
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        let lyricsURL = Self.musicDirectory.appendingPathComponent(track.id.raw).deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lyricsURL.path) else { return nil }
        let text = try String(contentsOf: lyricsURL, encoding: .utf8)
        return LRCParser.parse(text, source: lyricsURL.lastPathComponent)
    }
}

extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
