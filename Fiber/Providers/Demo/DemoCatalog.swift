import Foundation

/// Invented artists, albums and songs for trying the app without an account.
/// All names, covers, audio and lyrics here are original to this project.
nonisolated struct DemoCatalog: Sendable {
    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    private(set) var tracksByAlbum: [MediaID: [Track]] = [:]
    private(set) var songs: [MediaID: DemoSong] = [:]
    private(set) var lyricSheets: [MediaID: DemoLyricSheet] = [:]
    private(set) var playlists: [Playlist] = []
    private(set) var playlistTracks: [MediaID: [Track]] = [:]
    private(set) var stations: [Station] = []
    private(set) var categories: [BrowseCategory] = []

    var allTracks: [Track] { albums.flatMap { tracksByAlbum[$0.id] ?? [] } }

    static func id(_ raw: String) -> MediaID { MediaID(service: .demo, raw: raw) }

    /// Stable across launches, unlike `hashValue`.
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    private struct AlbumSeed {
        var artist: String
        var title: String
        var year: Int
        var genre: String
        var style: ArtStyle
        var explicit = false
        var notes: String
        var tracks: [String]
        var lyrics: DemoLyricSheet? = nil
    }

    init() {
        let seeds: [AlbumSeed] = [
            .init(artist: "Nova Lune", title: "Soft Static", year: 2025, genre: "Alternative", style: .horizon,
                  notes: "Nova Lune's second record trades the bedroom haze of her debut for wide, patient songs about leaving town and coming back changed.",
                  tracks: ["Paper Lanterns", "Soft Static", "Ferry Lights", "Northbound", "A Room With Weather"], lyrics: .english),
            .init(artist: "Paper Tigers Club", title: "Neon Allowance", year: 2026, genre: "Pop", style: .stripes, explicit: true,
                  notes: "Four friends, one borrowed drum machine, and eleven days in a rented flat. The result is the brightest pop record of the season.",
                  tracks: ["Fuego Lento", "Pocket Money", "Sugar Rush Hour", "Disco for Introverts", "Keep the Change"], lyrics: .spanish),
            .init(artist: "Marés", title: "Sal na Pele", year: 2024, genre: "MPB", style: .bloom,
                  notes: "Gravado entre Salvador e Lisboa, o disco de Marés mistura violão, sintetizadores e o barulho do mar ao fundo.",
                  tracks: ["Sal na Pele", "Maré Cheia", "Dois Verões", "Janela Aberta", "Depois da Chuva"], lyrics: .portuguese),
            .init(artist: "Hana Sol", title: "여름 편지", year: 2026, genre: "K-Pop", style: .rings,
                  notes: "Hana Sol's first full album is a set of letters to one summer, each song written on a different night.",
                  tracks: ["여름 편지", "Blue Soda", "Midnight Bus", "Small Fireworks", "Sunday, Again"], lyrics: .korean),
            .init(artist: "Vesper Kid", title: "Motel Hours", year: 2023, genre: "R&B", style: .bloom, explicit: true,
                  notes: "Slow, close and a little dangerous. Vesper Kid sings like someone trying not to wake the next room.",
                  tracks: ["Checkout Time", "Velvet Static", "Room 214", "Ice Machine", "Vacancy"]),
            .init(artist: "Juno Vale", title: "Field Notes", year: 2022, genre: "Indie Folk", style: .halftone,
                  notes: "Recorded live to tape in a barn, with the doors open. You can hear the birds if you listen for them.",
                  tracks: ["Field Notes", "Gravel Hymn", "The Long Fence", "Sparrow Math", "Lantern Season"]),
            .init(artist: "Saturn Motel", title: "Afterimage", year: 2026, genre: "Electronic", style: .chevrons,
                  notes: "A night-drive record built from two synthesizers and a broken tape echo.",
                  tracks: ["Afterimage", "Turn Signal", "Phosphor", "Mile Marker 9", "Low Beams"]),
            .init(artist: "Kite Season", title: "Small Weather", year: 2025, genre: "Indie Pop", style: .horizon,
                  notes: "Ten short songs about very small things, sung like they matter. They do.",
                  tracks: ["Small Weather", "Umbrella Theory", "Second Coffee", "Bike Bell", "Good Light"]),
            .init(artist: "Miro Atlas", title: "Blue Hour Tapes", year: 2021, genre: "Jazz", style: .halftone,
                  notes: "A quartet session cut between midnight and four, when the city finally went quiet.",
                  tracks: ["Blue Hour", "Slow Elevator", "Corner Table", "Last Train Theme", "Rain Check"]),
            .init(artist: "Os Satélites", title: "Órbita Baixa", year: 2026, genre: "Rock", style: .stripes,
                  notes: "Guitarras altas, refrões enormes e nenhuma vontade de voltar para casa.",
                  tracks: ["Órbita Baixa", "Antena", "Gravidade Zero", "Sinal Fraco", "Reentrada"]),
            .init(artist: "Lumi Park", title: "ガラスの庭", year: 2024, genre: "Dance", style: .rings,
                  notes: "Club music that sounds like light through a window. Lumi Park's most generous record.",
                  tracks: ["ガラスの庭", "Prism Step", "Greenhouse", "Mirror Ball Morning", "After the Rain Room"], lyrics: .japanese),
            .init(artist: "Glasshouse", title: "Low Tide Radio", year: 2025, genre: "Ambient", style: .bloom,
                  notes: "Forty minutes of slow water and distant signal, meant to be played quietly.",
                  tracks: ["Low Tide", "Harbor Tone", "Buoy", "Salt Fog", "Signal Home"]),
        ]

        for (albumIndex, seed) in seeds.enumerated() {
            let artistID = Self.id("artist-\(Self.seed(seed.artist) % 100_000)")
            let albumID = Self.id("album-\(albumIndex + 1)")
            let cover = Artwork.generated(seed: Self.seed(seed.title + seed.artist), style: seed.style, label: nil)
            if !artists.contains(where: { $0.id == artistID }) {
                artists.append(Artist(id: artistID, name: seed.artist,
                                      artwork: .generated(seed: Self.seed(seed.artist), style: .bloom, label: nil), genre: seed.genre))
            }
            albums.append(Album(id: albumID, title: seed.title, artistName: seed.artist, artistID: artistID, artwork: cover,
                                year: seed.year, genre: seed.genre, isExplicit: seed.explicit, formatBadges: ["Synthesized"], notes: seed.notes))

            var tracks: [Track] = []
            for (trackIndex, title) in seed.tracks.enumerated() {
                let trackID = Self.id("album-\(albumIndex + 1)-track-\(trackIndex + 1)")
                let songSeed = Self.seed(title + seed.artist)
                let song = DemoSong(seed: songSeed, bpm: Double(84 + songSeed % 40), bars: 26 + Int(songSeed >> 8 % 5) * 4)
                songs[trackID] = song
                tracks.append(Track(id: trackID, title: title, artistName: seed.artist, albumTitle: seed.title, albumID: albumID,
                                    artistID: artistID, duration: song.duration, trackNumber: trackIndex + 1,
                                    isExplicit: seed.explicit && trackIndex.isMultiple(of: 2), artwork: cover))
                if trackIndex == 0, let sheet = seed.lyrics { lyricSheets[trackID] = sheet }
            }
            tracksByAlbum[albumID] = tracks
        }

        let everything = allTracks
        func pick(_ name: String, count: Int, where include: (Track) -> Bool = { _ in true }) -> [Track] {
            var random = SeededRandom(seed: Self.seed(name))
            return Array(everything.filter(include).shuffled(using: &random).prefix(count))
        }
        let genreByAlbum = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.genre ?? "") })
        let genre: @Sendable (Track) -> String = { track in track.albumID.flatMap { genreByAlbum[$0] } ?? "" }

        let playlistSeeds: [(name: String, style: ArtStyle, label: String?, notes: String, filter: (Track) -> Bool)] = [
            ("Made for You Mix", .chevrons, nil, "A mix drawn from across the demo catalog.", { _ in true }),
            ("Fiber Hits 2026", .stripes, "HITS\n2026", "The most played songs in the demo catalog this year.", { _ in true }),
            ("Late Night Drive", .bloom, "LATE\nNIGHT", "Headlights, empty roads, slow synths.", { ["Electronic", "R&B", "Ambient", "Jazz"].contains(genre($0)) }),
            ("Coffee & Rain", .halftone, "COFFEE\n& RAIN", "Quiet songs for a grey morning.", { ["Indie Folk", "Jazz", "Indie Pop", "Alternative"].contains(genre($0)) }),
            ("Sunrise Run", .horizon, "SUNRISE\nRUN", "Bright tempos to get you out the door.", { ["Pop", "Dance", "K-Pop", "Rock"].contains(genre($0)) }),
            ("Brasil Agora", .rings, "BRASIL\nAGORA", "Vozes novas, do litoral ao sertão.", { ["MPB", "Rock"].contains(genre($0)) }),
            ("Seoul Lights", .bloom, "SEOUL\nLIGHTS", "City pop and late trains.", { ["K-Pop", "Dance", "Electronic"].contains(genre($0)) }),
        ]
        for seed in playlistSeeds {
            let id = Self.id("playlist-\(Self.seed(seed.name) % 100_000)")
            playlists.append(Playlist(id: id, name: seed.name, curator: "Fiber Demo",
                                      artwork: .generated(seed: Self.seed(seed.name), style: seed.style, label: seed.label), notes: seed.notes))
            playlistTracks[id] = pick(seed.name, count: 14, where: seed.filter)
        }

        let stationSeeds: [(name: String, tagline: String)] = [
            ("One", "The new music that matters."), ("Hits Hits", "Songs you know by heart."),
            ("Indie", "Guitars, mostly."), ("Uno", "Música sem parar."),
            ("Club", "Dance music, all day."), ("Chill", "An escape from the noise."),
        ]
        stations = stationSeeds.map {
            Station(id: Self.id("station-\($0.name.lowercased().replacingOccurrences(of: " ", with: "-"))"), name: $0.name,
                    tagline: $0.tagline, artwork: .generated(seed: Self.seed("station" + $0.name), style: .tile, label: $0.name))
        }

        let genres = Array(Set(albums.compactMap(\.genre))).sorted()
        let styles: [ArtStyle] = [.bloom, .horizon, .rings, .stripes, .chevrons, .halftone]
        categories = genres.enumerated().map { index, name in
            BrowseCategory(id: Self.id("genre-\(name)"), name: name,
                           artwork: .generated(seed: Self.seed("genre" + name), style: styles[index % styles.count], label: nil))
        }
    }

    func tracks(forStation id: MediaID) -> [Track] {
        var random = SystemRandomNumberGenerator()
        let pools: [String: [String]] = [
            "station-indie": ["Indie Folk", "Indie Pop", "Alternative", "Rock"],
            "station-uno": ["MPB", "Rock", "Pop"],
            "station-club": ["Dance", "Electronic", "K-Pop"],
            "station-chill": ["Ambient", "Jazz", "R&B", "Indie Folk"],
        ]
        let allowed = pools[id.raw]
        let pool = allTracks.filter { track in
            guard let allowed else { return true }
            return allowed.contains(albums.first { $0.id == track.albumID }?.genre ?? "")
        }
        return pool.shuffled(using: &random)
    }
}

/// Original demo lyrics. Each line lasts one bar of its song, and the words
/// are spread over that bar, so the timing is authored together with the audio.
nonisolated struct DemoLyricSheet: Sendable {
    var language: String
    var lines: [String]
    /// Japanese is written without spaces; the spaces here only mark word boundaries.
    var joinsWithoutSpaces = false

    func lyrics(for song: DemoSong) -> Lyrics {
        var result: [LyricLine] = []
        let barLength = 4 * song.beat
        let singingBars = song.bars - DemoSong.introBars - 2
        for bar in 0..<singingBars {
            // Leave every fifth bar instrumental, like a breath between phrases.
            guard bar % 5 != 4 else { continue }
            let text = lines[(bar - bar / 5) % lines.count]
            let start = Double(DemoSong.introBars + bar) * barLength
            let parts = text.split(separator: " ").map(String.init)
            let slot = (barLength * 0.8) / Double(parts.count)
            let words = parts.enumerated().map { index, word in
                LyricWord(text: word, start: start + Double(index) * slot, end: start + Double(index + 1) * slot)
            }
            result.append(LyricLine(id: result.count, text: parts.joined(separator: joinsWithoutSpaces ? "" : " "),
                                    start: start, end: start + barLength, words: words))
        }
        return Lyrics(lines: result, timing: .word, source: "Written for the Fiber demo catalog", language: language)
    }

    static let english = DemoLyricSheet(language: "en", lines: [
        "Paper lanterns over the water", "Carry the fire a little farther",
        "I kept your name inside my pocket", "A falling star I couldn't stop",
        "Rain on the roof like slow applause", "My heart is loud, the street is quiet",
        "If the night gets cold we'll burn it brighter", "Stay till the morning turns to gold",
    ])
    static let portuguese = DemoLyricSheet(language: "pt", lines: [
        "O mar guardou o teu segredo", "Tem fogo aceso no meu peito",
        "A chuva cai devagarinho", "E o coração perde o caminho",
        "Uma estrela mora na janela", "A noite inteira é toda dela",
        "Se o frio chegar, a gente dança", "Até o sol virar lembrança",
    ])
    static let spanish = DemoLyricSheet(language: "es", lines: [
        "Llévame despacio por la ciudad", "Hay fuego lento en la oscuridad",
        "La lluvia canta sobre el cristal", "Mi corazón no sabe frenar",
        "Una estrella cae sobre el mar", "Y el frío ya no puede entrar",
        "Baila conmigo hasta el final", "Que la noche vuelva a empezar",
    ])
    static let korean = DemoLyricSheet(language: "ko", lines: [
        "여름밤에 편지를 써요", "내 마음에 불이 켜져요",
        "비가 내려도 괜찮아요", "별이 우리 길을 비춰요",
        "차가운 바람이 불어와도", "심장은 계속 뛰고 있죠",
        "눈을 감으면 네가 보여", "아침이 올 때까지 여기 있어요",
    ])
    static let japanese = DemoLyricSheet(language: "ja", lines: [
        "夜の 庭に 火が 灯る", "雨の 音が 遠く なる",
        "星を ひとつ 数えて", "心が そっと 揺れる",
        "冷たい 風の なかで", "君の 声を 探す",
        "朝が 来る まで", "ここで 踊ろう",
    ], joinsWithoutSpaces: true)
}
