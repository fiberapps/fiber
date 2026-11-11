import AVFoundation
import Foundation
import Testing
@testable import Fiber

@MainActor
struct YouTubeCatalogTests {
    @Test func readsASongRow() throws {
        let json = """
        {"contents":{"musicResponsiveListItemRenderer":{
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Thriller"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Michael Jackson"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Thriller 40"}]}}}
          ],
          "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"4:39"}]}}}],
          "playlistItemData":{"videoId":"0JFbiCg-8n4"},
          "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://yt3.googleusercontent.com/cover","width":120}]}}},
          "badges":[{"musicInlineBadgeRenderer":{"icon":{"iconType":"MUSIC_EXPLICIT_BADGE"}}}]
        }}}
        """
        let tracks = try YouTubeCatalog.tracks(in: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(tracks.count == 1)
        #expect(tracks[0].id.raw == "0JFbiCg-8n4")
        #expect(tracks[0].title == "Thriller")
        #expect(tracks[0].artistName == "Michael Jackson")
        #expect(tracks[0].albumTitle == "Thriller 40")
        #expect(tracks[0].duration == 279)
        #expect(tracks[0].isExplicit)
        #expect(tracks[0].artwork == .remote(template: "https://yt3.googleusercontent.com/cover=w{w}-h{h}"))
    }

    @Test func groupsHomeShelves() throws {
        let json = """
        {"contents":[{"musicCarouselShelfRenderer":{
          "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Low key vibes"}]}}},
          "contents":[{"musicTwoRowItemRenderer":{
            "title":{"runs":[{"text":"The Hits","navigationEndpoint":{"browseEndpoint":{
              "browseId":"VLRDCLAK5uy_test",
              "browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}
            }}}]},
            "subtitle":{"runs":[{"text":"Prince"},{"text":", "},{"text":"Michael Jackson"}]},
            "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDCLAK5uy_test","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}
          }}]
        }}]}
        """
        let shelves = try YouTubeCatalog.shelves(in: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(shelves.count == 1)
        #expect(shelves[0].title == "Low key vibes")
        guard case .playlist(let playlist) = shelves[0].entries[0].item else { Issue.record("Expected a playlist"); return }
        #expect(playlist.name == "The Hits")
        #expect(playlist.id.raw == "VLRDCLAK5uy_test")
        #expect(playlist.curator == "Prince, Michael Jackson")
    }

    @Test func separatesSearchKindsAndSkipsDuplicates() throws {
        let json = """
        {"contents":[
          {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Artist"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"UCabc","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}},
          {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Album"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_album"}}}},
          {"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"}]}}}],"playlistItemData":{"videoId":"vid1"}}},
          {"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song again"}]}}}],"playlistItemData":{"videoId":"vid1"}}}
        ]}
        """
        let results = try YouTubeCatalog.searchResults(in: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(results.artists.map(\.name) == ["Artist"])
        #expect(results.albums.map(\.title) == ["Album"])
        #expect(results.tracks.map(\.id.raw) == ["vid1"])
    }

    @Test func readsAContinuationToken() throws {
        let json = #"{"contents":{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"next-page"}}}}}"#
        let token = try YouTubeCatalog.continuationToken(in: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(token == "next-page")
    }
}

struct YouTubeAudioTests {
    @Test func prefersAACOverOpusAndIgnoresCipherOnlyFormats() throws {
        let json: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": ["adaptiveFormats": [
                ["itag": 251, "mimeType": "audio/webm; codecs=\"opus\"", "bitrate": 136544, "url": "https://example.com/opus"],
                ["itag": 140, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 130677, "url": "https://example.com/aac"],
                ["itag": 18, "mimeType": "audio/mp4", "bitrate": 900000, "signatureCipher": "s=secret"],
            ]],
        ]
        #expect(try YouTubeAudio.bestURL(in: json) == URL(string: "https://example.com/aac"))
    }

    @Test func explainsAMissingStream() {
        let json: [String: Any] = ["playabilityStatus": ["status": "UNPLAYABLE", "reason": "This video is unavailable."]]
        #expect(throws: ProviderError.self) { try YouTubeAudio.bestURL(in: json) }
    }
}

struct YouTubeAuthTests {
    @Test func readsTheSecureCookieAndBuildsTheHash() {
        let header = "SID=abc; __Secure-3PAPISID=abc; LOGIN_INFO=1"
        #expect(YouTubeAuth.sapisid(in: header) == "abc")
        #expect(YouTubeAuth.authorization(sapisid: "abc", origin: "https://music.youtube.com", timestamp: 1000) == "SAPISIDHASH 1000_8640d4ab579b2bf127293e0c58d18813f9483ba8")
    }
}

struct LockScreenMotionTests {
    @Test func writesALoopingSquareVideo() async throws {
        let url = try await LockScreenMotion.videoFile(for: .neutral)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(duration.seconds > 3)
        #expect(tracks.count == 1)
        let natural = try await tracks[0].load(.naturalSize)
        #expect(natural.width == natural.height)
        #expect(natural.width >= 640)
    }
}
