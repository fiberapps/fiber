import Foundation
import Testing
@testable import Fiber

struct LyricsTests {
    @Test func parsesLineTimedLyrics() throws {
        let lyrics = try #require(LRCParser.parse("[ti:Song]\n[00:01.50]First\n[00:04.00]Second\n", source: "test"))
        #expect(lyrics.timing == .line)
        #expect(lyrics.lines.map(\.text) == ["First", "Second"])
        #expect(lyrics.lines[0].start == 1.5)
        #expect(lyrics.lines[0].end == 4)
        #expect(lyrics.activeIndex(at: 0.5) == nil)
        #expect(lyrics.activeIndex(at: 2) == 0)
        #expect(lyrics.activeIndex(at: 99) == 1)
    }

    @Test func parsesWordTimedLyrics() throws {
        let lyrics = try #require(LRCParser.parse("[00:10.00]<00:10.00>one <00:10.50>two\n[00:12.00]next", source: "test"))
        #expect(lyrics.timing == .word)
        let words = try #require(lyrics.lines[0].words)
        #expect(words.map(\.text) == ["one", "two"])
        #expect(words[0].end == 10.5)
        #expect(words[1].end == 12)
    }

    @Test func plainTextIsNeverGivenTiming() throws {
        let lyrics = try #require(LRCParser.parse("just words\nmore words", source: "test"))
        #expect(lyrics.timing == .unsynced)
        #expect(lyrics.activeIndex(at: 10) == nil)
    }

    @Test func strayAngleBracketDoesNotHang() throws {
        let lyrics = try #require(LRCParser.parse("[00:01.00]a < b <00:02.00>c", source: "test"))
        #expect(lyrics.lines.count == 1)
    }

    @Test func demoLyricsStayInsideTheSong() {
        let catalog = DemoCatalog()
        for (id, sheet) in catalog.lyricSheets {
            let song = catalog.songs[id]!
            let lyrics = sheet.lyrics(for: song)
            #expect(lyrics.lines.last!.end <= song.duration)
            #expect(lyrics.lines.allSatisfy { $0.words?.isEmpty == false })
        }
    }
}

@MainActor
struct QueueTests {
    private final class SilentEngine: PlaybackEngine {
        let mode = PlaybackMode.remote(device: nil)
        var currentTime: TimeInterval = 0
        var onFinish: (() -> Void)?
        var onFailure: ((String) -> Void)?
        var onPlayingChanged: ((Bool) -> Void)?
        func prepare(_ track: Track) async throws -> TimeInterval { track.duration }
        func play() throws {}
        func pause() {}
        func seek(to time: TimeInterval) { currentTime = time }
        func stop() {}
    }

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: MediaID(service: .demo, raw: "t\($0)"), title: "T\($0)", artistName: "A", duration: 60) }
    }

    @Test func playNextAndQueueEditing() async throws {
        let engine = SilentEngine()
        let controller = PlaybackController { _ in engine }
        let list = tracks(4)
        controller.play(list, startingAt: 1)
        #expect(controller.current == list[1])
        controller.playNext(list[0])
        #expect(controller.upNext.first == list[0])
        controller.removeUpNext(at: [0])
        #expect(controller.upNext == [list[2], list[3]])
        controller.moveUpNext(from: [1], to: 0)
        #expect(controller.upNext == [list[3], list[2]])
    }

    @Test func shuffleKeepsCurrentTrackAndRestoresOrder() {
        let engine = SilentEngine()
        let controller = PlaybackController { _ in engine }
        let list = tracks(12)
        controller.play(list, startingAt: 3)
        controller.toggleShuffle()
        #expect(controller.current == list[3])
        #expect(Set(controller.queue) == Set(list))
        controller.toggleShuffle()
        #expect(controller.queue == list)
        #expect(controller.current == list[3])
    }

    @Test func repeatAllWrapsAround() {
        let engine = SilentEngine()
        let controller = PlaybackController { _ in engine }
        let list = tracks(2)
        controller.play(list, startingAt: 1)
        #expect(!controller.hasNext)
        controller.repeatMode = .all
        controller.next()
        #expect(controller.current == list[0])
    }
}

struct LyricEffectTests {
    @Test func findsKeywordsAcrossLanguages() {
        #expect(LyricEffectDetector.effect(for: "fire,") == .fire)
        #expect(LyricEffectDetector.effect(for: "Fogo") == .fire)
        #expect(LyricEffectDetector.effect(for: "fuego") == .fire)
        #expect(LyricEffectDetector.effect(for: "불이") == .fire)
        #expect(LyricEffectDetector.effect(for: "火が") == .fire)
        #expect(LyricEffectDetector.effect(for: "coração") == .heart)
        #expect(LyricEffectDetector.effect(for: "corazón") == .heart)
        #expect(LyricEffectDetector.effect(for: "심장은") == .heart)
        #expect(LyricEffectDetector.effect(for: "estrella") == .star)
        #expect(LyricEffectDetector.effect(for: "별이") == .star)
        #expect(LyricEffectDetector.effect(for: "星を") == .star)
        #expect(LyricEffectDetector.effect(for: "chuva") == .rain)
        #expect(LyricEffectDetector.effect(for: "비가") == .rain)
        #expect(LyricEffectDetector.effect(for: "frío") == .cold)
        #expect(LyricEffectDetector.effect(for: "차가운") == .cold)
        #expect(LyricEffectDetector.effect(for: "gold") == .light)
    }

    @Test func ignoresLookalikes() {
        #expect(LyricEffectDetector.effect(for: "start") == nil)
        #expect(LyricEffectDetector.effect(for: "solo") == nil)
        #expect(LyricEffectDetector.effect(for: "brain") == nil)
        #expect(LyricEffectDetector.effect(for: "비춰요") == nil)
        #expect(LyricEffectDetector.effect(for: "the") == nil)
        #expect(LyricEffectDetector.effect(for: "") == nil)
    }
}

struct LRCLibTests {
    @Test func prefersSyncedLyricsAndRespectsInstrumentals() throws {
        let synced = Data(#"{"instrumental":false,"plainLyrics":"a\nb","syncedLyrics":"[00:01.00] a\n[00:02.00] b"}"#.utf8)
        #expect(try LRCLibClient.lyrics(from: synced)?.timing == .line)
        let plain = Data(#"{"instrumental":false,"plainLyrics":"a\nb","syncedLyrics":null}"#.utf8)
        #expect(try LRCLibClient.lyrics(from: plain)?.timing == .unsynced)
        let instrumental = Data(#"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#.utf8)
        #expect(try LRCLibClient.lyrics(from: instrumental) == nil)
        #expect(throws: ProviderError.self) { try LRCLibClient.lyrics(from: Data("oops".utf8)) }
    }
}

@MainActor
struct BrowsingSelectionTests {
    private func row(_ id: ServiceID, _ connection: ConnectionState, browse: Bool = true) -> ServiceRow {
        ServiceRow(id: id, connection: connection, capabilities: ProviderCapabilities(browse: browse))
    }

    @Test func disabledDemoDefaultFallsBackToConnectedAppleMusic() {
        #expect(AppModel.selectBrowsingService(defaultService: .demo,
            candidates: [row(.appleMusic, .connected(account: nil))]) == .appleMusic)
    }

    @Test func explicitUsableDefaultIsRespected() {
        #expect(AppModel.selectBrowsingService(defaultService: .demo,
            candidates: [row(.appleMusic, .connected(account: nil)), row(.demo, .notRequired)]) == .demo)
    }

    @Test func connectionRestorationMakesServiceAvailable() {
        #expect(AppModel.selectBrowsingService(defaultService: .demo,
            candidates: [row(.appleMusic, .connecting)]) == nil)
        #expect(AppModel.selectBrowsingService(defaultService: .demo,
            candidates: [row(.appleMusic, .limited("No subscription"))]) == .appleMusic)
    }

    @Test func unavailableAndNonBrowsingServicesAreExcluded() {
        #expect(AppModel.selectBrowsingService(defaultService: .spotify,
            candidates: [row(.spotify, .unavailable("Not built")), row(.local, .notRequired, browse: false)]) == nil)
    }
}

struct WordTimingTests {
    @Test func ttmlPreservesSyllablesSpacesAndRealTiming() throws {
        let xml = #"<tt><body><p begin="00:01.000" end="00:04.000"><span begin="1s" end="1.4s">Hel</span><span begin="1.4s" end="2s">lo</span> <span begin="2.5s" end="4s">world!</span></p></body></tt>"#
        let lyrics = try #require(TTMLParser.parse(xml, source: "test"))
        #expect(lyrics.timing == .word)
        #expect(lyrics.lines[0].text == "Hello world!")
        #expect(lyrics.lines[0].words?.map(\.text).joined() == "Hello world!")
        #expect(lyrics.lines[0].words?[2].start == 2.5)
        #expect(lyrics.fillingMissingWordTiming() == lyrics)
    }

    @Test func lineOnlyTTMLAndPlainLyricsAreNotClaimedAsWordSynced() throws {
        let lyrics = try #require(TTMLParser.parse(#"<tt><p begin="1s" end="4s">Hello world</p></tt>"#, source: "test"))
        #expect(lyrics.timing == .line)
        #expect(lyrics.lines[0].words == nil)
        let estimated = lyrics.fillingMissingWordTiming()
        #expect(estimated.estimatedWordTiming == true)
        #expect(estimated.timing == .line)
        #expect(estimated.lines[0].words?.count == 2)
        let plain = try #require(LRCParser.parse("Hello world", source: "test"))
        #expect(plain.fillingMissingWordTiming() == plain)
    }

    @Test func estimatesStayWithinLineAndDoNotStretchAcrossLongGaps() throws {
        let source = try #require(LRCParser.parse("[00:01.00]A longer word\n[00:25.00]Next line", source: "test"))
        let lyrics = source.fillingMissingWordTiming()
        let words = try #require(lyrics.lines[0].words)
        #expect(words.map(\.text).joined() == source.lines[0].text)
        #expect(words.first?.start == 1)
        #expect(words.last!.end < 5)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(lyrics.fillingMissingWordTiming() == lyrics)
    }

    @Test func fallbackMatchesOtherAlbumButRejectsDifferentRecording() throws {
        let data = Data(#"[{"trackName":"hey boyyy","artistName":"Slayyyter","albumName":"Album","duration":278,"syncedLyrics":"[00:01.00]Test line"}]"#.utf8)
        #expect(try LRCLibClient.bestMatch(from: data, title: "HEY BOYYY", artist: "SLAYYYTER", album: "Single", duration: 277.8) != nil)
        #expect(try LRCLibClient.bestMatch(from: data, title: "HEY BOYYY (Live)", artist: "SLAYYYTER", album: nil, duration: 278) == nil)
        #expect(try LRCLibClient.bestMatch(from: data, title: "HEY BOYYY", artist: "Other", album: nil, duration: 278) == nil)
        #expect(try LRCLibClient.bestMatch(from: data, title: "HEY BOYYY", artist: "SLAYYYTER", album: nil, duration: 230) == nil)
    }

    @Test func unisonCreditsAndMetadataAreValidated() throws {
        let data = Data(#"{"success":true,"data":{"videoId":"test","song":"Example","artist":"Artist","format":"ttml","lyrics":"<tt><p begin='1s' end='2s'><span begin='1s' end='2s'>Test</span></p></tt>","submitter":{"keyId":"curator","displayName":"Contributor"}}}"#.utf8)
        let lyrics = try #require(try UnisonClient.lyrics(from: data, title: "EXAMPLE", artist: "Artist"))
        #expect(lyrics.timing == .word)
        #expect(lyrics.contributor == "Contributor")
        #expect(lyrics.sourceURL?.absoluteString == "https://unison.betterlyrics.org/song/test")
        #expect(try UnisonClient.lyrics(from: data, title: "Other", artist: "Artist") == nil)
    }
}
