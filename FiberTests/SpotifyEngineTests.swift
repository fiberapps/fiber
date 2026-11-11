import Foundation
import Testing
@testable import Fiber

/// A `SpotifyEngine` on a fake clock, talking to a fake Spotify.
@MainActor
final class SpotifyEngineRig {
    final class Clock {
        var now: TimeInterval = 1_000
    }

    static let phone = #"{"devices":[{"id":"phone","name":"Breno's iPhone","type":"Smartphone","is_active":false,"is_restricted":false}]}"#
    static let noDevices = #"{"devices":[]}"#
    static let noActiveDevice = SpotifyStub.Reply.json(
        #"{"error":{"status":404,"message":"Player command failed: No active device found","reason":"NO_ACTIVE_DEVICE"}}"#, status: 404)

    let fixture: SpotifyFixture
    let clock = Clock()
    var devices: String
    /// Answers for the next play commands, in order; after that they succeed.
    var playReplies: [SpotifyStub.Reply] = []
    var appOpens = true
    /// Makes the fake clock jump past the 25 second wait when the app is opened.
    var launchTakesForever = false
    private(set) var launched: [URL] = []
    private(set) var finishes = 0
    private(set) var failures: [String] = []
    private(set) var playingChanges: [Bool] = []
    private(set) var engine: SpotifyEngine!

    var stub: SpotifyStub { fixture.stub }

    let track = Track(id: MediaID(service: .spotify, raw: "t1"), title: "Song", artistName: "Artist", duration: 200)
    let otherTrack = Track(id: MediaID(service: .spotify, raw: "t2"), title: "Other", artistName: "Artist", duration: 180)

    init(devices: String = SpotifyEngineRig.phone) throws {
        fixture = try SpotifyFixture()
        self.devices = devices
        // The playback check never answers, so tests decide what the engine hears with `apply`.
        fixture.stub.stalledPaths = ["/v1/me/player"]
        fixture.api = { [weak self] request in
            guard let self else { return .missing }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/me/player/devices"):
                return .json(self.devices)
            case ("PUT", "/v1/me/player/play"):
                return self.playReplies.isEmpty ? .noContent : self.playReplies.removeFirst()
            case ("PUT", _):
                return .noContent
            default:
                return .missing
            }
        }
        let clock = clock
        engine = SpotifyEngine(session: fixture.session, now: { clock.now }, openApp: { [weak self] url in
            guard let self else { return false }
            launched.append(url)
            if launchTakesForever { clock.now += 100 }
            return appOpens
        })
        engine.onFinish = { [weak self] in self?.finishes += 1 }
        engine.onFailure = { [weak self] in self?.failures.append($0) }
        engine.onPlayingChanged = { [weak self] in self?.playingChanges.append($0) }
    }

    func shutdown() {
        engine.stop()
    }

    func state(of song: Track? = nil, playing: Bool = true, at progress: TimeInterval) -> SpotifyPlayerState {
        let song = song ?? track
        return SpotifyPlayerState(device: nil, isPlaying: playing, progressMs: Int(progress * 1000),
                                  item: SpotifyTrackDTO(id: song.id.raw, name: song.title))
    }

    /// Gives the engine's own tasks time to run after a command went out.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Prepares and plays the first song, then lets Spotify confirm it at `progress`.
    func startPlaying(at progress: TimeInterval = 3) async throws {
        _ = try await engine.prepare(track)
        try engine.play()
        #expect(await stub.waitForCall("PUT", "/me/player/play"))
        await settle()
        clock.now += 1
        engine.apply(state(at: progress), startedAt: clock.now, latency: 0)
    }
}

@MainActor
struct SpotifyEngineTests {
    // MARK: Choosing a device

    private func device(_ id: String?, _ type: String, active: Bool = false, restricted: Bool = false) -> SpotifyDevice {
        SpotifyDevice(id: id, name: "\(type) \(id ?? "-")", type: type, isActive: active, isRestricted: restricted)
    }

    @Test func prefersTheDeviceThatIsAlreadyPlaying() {
        let picked = SpotifyEngine.pickDevice(from: [device("phone", "Smartphone"), device("mac", "Computer", active: true)])
        #expect(picked?.id == "mac")
    }

    @Test func prefersPhonesThenTablets() {
        #expect(SpotifyEngine.pickDevice(from: [device("mac", "Computer"), device("phone", "Smartphone")])?.id == "phone")
        #expect(SpotifyEngine.pickDevice(from: [device("mac", "Computer"), device("pad", "Tablet")])?.id == "pad")
        #expect(SpotifyEngine.pickDevice(from: [device("speaker", "Speaker"), device("mac", "Computer")])?.id == "speaker")
    }

    @Test func skipsDevicesThatCantBeControlled() {
        #expect(SpotifyEngine.pickDevice(from: [device("phone", "Smartphone", restricted: true)]) == nil)
        #expect(SpotifyEngine.pickDevice(from: [device(nil, "Smartphone")]) == nil)
        #expect(SpotifyEngine.pickDevice(from: []) == nil)
        #expect(SpotifyEngine.pickDevice(from: [device("phone", "Smartphone", restricted: true), device("mac", "Computer")])?.id == "mac")
    }

    @Test func explainsPremiumAndAvailabilityFailures() {
        #expect(SpotifyEngine.message(for: ProviderError.subscriptionRequired).contains("Premium"))
        #expect(SpotifyEngine.message(for: ProviderError.permissionDenied).contains("country"))
        #expect(SpotifyEngine.message(for: ProviderError.network("offline")) == ProviderError.network("offline").localizedDescription)
    }

    // MARK: Finding Spotify

    @Test func prepareFindsThePhone() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        #expect(rig.engine.mode == .remote(device: nil))
        let duration = try await rig.engine.prepare(rig.track)
        #expect(duration == 200)
        #expect(rig.engine.phase == .ready)
        #expect(rig.engine.mode == .remote(device: "Breno's iPhone"))
        #expect(rig.launched.isEmpty)
    }

    @Test func opensTheSpotifyAppWhenNoDeviceIsListed() async throws {
        let rig = try SpotifyEngineRig(devices: SpotifyEngineRig.noDevices)
        defer { rig.shutdown() }
        let preparing = Task { try await rig.engine.prepare(rig.track) }
        #expect(await eventually { !rig.launched.isEmpty })
        rig.devices = SpotifyEngineRig.phone
        #expect(try await preparing.value == 200)
        #expect(rig.launched.map(\.absoluteString) == ["spotify:"])
        #expect(rig.engine.mode == .remote(device: "Breno's iPhone"))
    }

    @Test func reportsAMissingSpotifyApp() async throws {
        let rig = try SpotifyEngineRig(devices: SpotifyEngineRig.noDevices)
        defer { rig.shutdown() }
        rig.appOpens = false
        let error = await providerError { _ = try await rig.engine.prepare(rig.track) }
        guard case .playback(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("isn't installed"))
    }

    @Test func givesUpWhenSpotifyNeverAppears() async throws {
        let rig = try SpotifyEngineRig(devices: SpotifyEngineRig.noDevices)
        defer { rig.shutdown() }
        rig.launchTakesForever = true
        let error = await providerError { _ = try await rig.engine.prepare(rig.track) }
        guard case .playback(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("didn't show up"))
        #expect(rig.launched.count == 1)
    }

    @Test func playBeforePrepareThrows() throws {
        let rig = try SpotifyEngineRig()
        #expect(throws: ProviderError.playback("Nothing is ready to play.")) { try rig.engine.play() }
    }

    // MARK: Starting a song

    @Test func playSendsTheSongToTheChosenDevice() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(rig.engine.phase == .loading)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))

        let request = try #require(rig.stub.calls("PUT", "/me/player/play").first)
        #expect(request.queryValues == ["device_id": "phone"])
        #expect(request.bodyJSON["uris"] as? [String] == ["spotify:track:t1"])
        #expect(request.bodyJSON["position_ms"] == nil)
    }

    @Test func aPositionChosenBeforePlayingIsSent() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        rig.engine.seek(to: 42.5)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        #expect(rig.stub.calls("PUT", "/me/player/play").first?.bodyJSON["position_ms"] as? Int == 42_500)
        #expect(rig.stub.calls("PUT", "/me/player/seek").isEmpty)
    }

    @Test func theClockStartsWhenSpotifyConfirms() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()

        rig.clock.now += 1
        #expect(rig.engine.currentTime == 0)
        // progress_ms describes the middle of the round trip, so half the latency is added.
        rig.engine.apply(rig.state(at: 3), startedAt: rig.clock.now, latency: 0.2)
        #expect(rig.engine.phase == .playing)
        #expect(abs(rig.engine.currentTime - 3.1) < 0.001)
        rig.clock.now += 2
        #expect(abs(rig.engine.currentTime - 5.1) < 0.001)
    }

    @Test func repliesThatPredateTheCommandAreIgnored() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()

        rig.engine.apply(rig.state(at: 3), startedAt: rig.clock.now + 0.1, latency: 0)
        #expect(rig.engine.phase == .loading)
        rig.engine.apply(rig.state(at: 3), startedAt: rig.clock.now + 0.5, latency: 0)
        #expect(rig.engine.phase == .playing)
    }

    @Test func aNotYetPlayingReplyKeepsLoading() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()

        rig.clock.now += 3
        rig.engine.apply(rig.state(of: rig.otherTrack, at: 50), startedAt: rig.clock.now, latency: 0)
        rig.engine.apply(nil, startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .loading)
        #expect(rig.failures.isEmpty)
    }

    @Test func givesUpWhenSpotifyNeverStarts() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()

        rig.clock.now += 13
        rig.engine.apply(nil, startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .idle)
        #expect(rig.failures.count == 1)
        #expect(rig.failures.first?.contains("didn't start playing") == true)
        #expect(rig.engine.mode == .remote(device: nil))
    }

    @Test func aRefusedPlayCommandIsReported() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        rig.playReplies = [.json(#"{"error":{"status":403,"message":"Premium required","reason":"PREMIUM_REQUIRED"}}"#, status: 403)]
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await eventually { !rig.failures.isEmpty })
        #expect(rig.failures.first?.contains("Premium") == true)
        #expect(rig.engine.phase == .idle)
    }

    // MARK: Spotify closed behind our back

    @Test func looksForSpotifyAgainWhenTheDeviceIsGone() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        rig.playReplies = [SpotifyEngineRig.noActiveDevice]
        rig.devices = SpotifyEngineRig.noDevices
        try rig.engine.play()

        #expect(await eventually { !rig.launched.isEmpty })
        // The engine is still looking, so the usual twelve second limit doesn't apply.
        rig.clock.now += 13
        rig.engine.apply(nil, startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .loading)
        #expect(rig.failures.isEmpty)

        rig.devices = SpotifyEngineRig.phone
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play", count: 2))
        #expect(rig.engine.mode == .remote(device: "Breno's iPhone"))
    }

    @Test func pausingWhileSpotifyOpensDoesNotStartTheSongLater() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        rig.playReplies = [SpotifyEngineRig.noActiveDevice]
        rig.devices = SpotifyEngineRig.noDevices
        try rig.engine.play()
        #expect(await eventually { !rig.launched.isEmpty })

        rig.engine.pause()
        rig.devices = SpotifyEngineRig.phone
        // The search notices the app within a second; the song must stay stopped.
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))
        #expect(rig.stub.calls("PUT", "/me/player/play").count == 1)
        #expect(rig.engine.phase == .paused)
    }

    @Test func aPauseRightAfterPlayReplacesIt() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        rig.engine.pause()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))
        await rig.settle()
        #expect(rig.stub.calls("PUT", "/me/player/play").isEmpty)
    }

    @Test func playingAgainAfterPausingWhileLoadingSendsTheSongAgain() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        rig.engine.pause()
        try rig.engine.play()
        #expect(rig.engine.phase == .loading)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()

        let order = rig.stub.requests.filter { $0.httpMethod == "PUT" }.compactMap { $0.url?.path }
        #expect(order == ["/v1/me/player/pause", "/v1/me/player/play"])
        #expect(rig.stub.calls("PUT", "/me/player/play").first?.bodyJSON["uris"] as? [String] == ["spotify:track:t1"])
    }

    // MARK: While playing

    @Test func smallDriftIsIgnoredAndLargeDriftIsCorrected() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 3)
        #expect(rig.engine.phase == .playing)
        #expect(rig.engine.currentTime == 3)

        rig.clock.now += 10
        #expect(rig.engine.currentTime == 13)
        rig.engine.apply(rig.state(at: 13.2), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.currentTime == 13)
        rig.engine.apply(rig.state(at: 15), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.currentTime == 15)
    }

    @Test func theClockNeverRunsPastTheEndOfTheSong() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 190)
        rig.clock.now += 60
        #expect(rig.engine.currentTime == 200)
    }

    @Test func anExternalPauseAndResumeAreReported() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 30)

        rig.clock.now += 5
        rig.engine.apply(rig.state(playing: false, at: 34), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .paused)
        #expect(rig.engine.currentTime == 34)
        #expect(rig.playingChanges == [false])

        rig.clock.now += 5
        rig.engine.apply(rig.state(at: 36), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .playing)
        #expect(rig.engine.currentTime == 36)
        #expect(rig.playingChanges == [false, true])
    }

    @Test func anotherSongTakingOverMeansReloadingNextTime() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 30)

        rig.clock.now += 5
        rig.engine.apply(rig.state(of: rig.otherTrack, at: 2), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .paused)
        #expect(rig.engine.currentTime == 35)
        #expect(rig.playingChanges == [false])

        // Spotify playing something else is not a resume of this song.
        rig.clock.now += 5
        rig.engine.apply(rig.state(of: rig.otherTrack, at: 7), startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .paused)

        try rig.engine.play()
        #expect(rig.engine.phase == .loading)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play", count: 2))
        let reload = try #require(rig.stub.calls("PUT", "/me/player/play").last)
        #expect(reload.bodyJSON["uris"] as? [String] == ["spotify:track:t1"])
        #expect(reload.bodyJSON["position_ms"] as? Int == 35_000)
    }

    @Test func finishesWhenSpotifyStopsAtTheEnd() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 195)

        rig.clock.now += 4.5
        rig.engine.apply(nil, startedAt: rig.clock.now, latency: 0)
        #expect(rig.finishes == 1)
        #expect(rig.engine.phase == .paused)
        #expect(rig.engine.currentTime == 200)

        // Spotify must not carry on into its own autoplay.
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))
    }

    @Test func finishesOnItsOwnClockWhenNoReplyArrives() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 195)
        rig.clock.now += 10
        #expect(await eventually(timeout: .seconds(4)) { rig.finishes == 1 })
    }

    // MARK: Controls

    @Test func pausingSendsOneCommandAndKeepsThePlace() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)

        rig.clock.now += 5
        rig.engine.pause()
        #expect(rig.engine.phase == .paused)
        #expect(rig.engine.currentTime == 15)
        rig.clock.now += 30
        #expect(rig.engine.currentTime == 15)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))
        await rig.settle()
        #expect(rig.stub.calls("PUT", "/me/player/pause").count == 1)
        #expect(rig.stub.calls("PUT", "/me/player/pause").first?.queryValues == ["device_id": "phone"])
    }

    @Test func resumingAsksSpotifyToContinueWithoutResendingTheSong() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)
        rig.engine.pause()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))

        try rig.engine.play()
        #expect(rig.engine.phase == .playing)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play", count: 2))
        let resume = try #require(rig.stub.calls("PUT", "/me/player/play").last)
        #expect(resume.bodyText.isEmpty)
        #expect(resume.queryValues == ["device_id": "phone"])
    }

    @Test func resumesFromTheSamePlaceWhenSpotifyLetGo() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)
        rig.clock.now += 5
        rig.engine.pause()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))

        // Spotify was closed meanwhile, so the resume fails and the song is sent again.
        rig.playReplies = [SpotifyEngineRig.noActiveDevice]
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play", count: 3))
        let reload = try #require(rig.stub.calls("PUT", "/me/player/play").last)
        #expect(reload.bodyJSON["uris"] as? [String] == ["spotify:track:t1"])
        #expect(reload.bodyJSON["position_ms"] as? Int == 15_000)
    }

    @Test func scrubbingSendsOnlyTheLastPosition() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)

        rig.engine.seek(to: 20)
        rig.engine.seek(to: 21)
        rig.engine.seek(to: 22)
        #expect(rig.engine.currentTime == 22)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/seek"))
        await rig.settle()

        let seeks = rig.stub.calls("PUT", "/me/player/seek")
        #expect(seeks.count == 1)
        #expect(seeks.first?.queryValues == ["device_id": "phone", "position_ms": "22000"])
    }

    @Test func seekingIsClampedToTheSong() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)
        rig.engine.seek(to: 9_999)
        #expect(rig.engine.currentTime == 200)
        rig.engine.seek(to: -5)
        #expect(rig.engine.currentTime == 0)
    }

    // MARK: Stopping

    @Test func stoppingPausesSpotifyAfterAShortDelay() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)

        rig.engine.stop()
        #expect(rig.engine.phase == .idle)
        #expect(rig.stub.calls("PUT", "/me/player/pause").isEmpty)
        #expect(await rig.stub.waitForCall("PUT", "/me/player/pause"))
    }

    @Test func skippingToAnotherSongSendsNoPause() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)

        // PlaybackController stops the old song, then prepares the next.
        rig.engine.stop()
        _ = try await rig.engine.prepare(rig.otherTrack)
        try await Task.sleep(for: .milliseconds(700))
        #expect(rig.stub.calls("PUT", "/me/player/pause").isEmpty)
    }

    @Test func disconnectingPausesImmediatelyAndOnlyOnce() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        try await rig.startPlaying(at: 10)

        await rig.engine.stopAndPause()
        #expect(rig.stub.calls("PUT", "/me/player/pause").count == 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(rig.stub.calls("PUT", "/me/player/pause").count == 1)
        #expect(rig.engine.phase == .idle)
    }

    @Test func stoppingSomethingThatIsNotPlayingSendsNothing() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        rig.engine.stop()
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.stub.calls("PUT", "/me/player/pause").isEmpty)
    }
}

@MainActor
struct SpotifyRelinkingTests {
    @Test func relinkedPlaybackConfirmsRequestedSong() async throws {
        let rig = try SpotifyEngineRig()
        defer { rig.shutdown() }
        _ = try await rig.engine.prepare(rig.track)
        try rig.engine.play()
        #expect(await rig.stub.waitForCall("PUT", "/me/player/play"))
        await rig.settle()
        rig.clock.now += 2
        let dto = try { () -> JSONDecoder in let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder }().decode(SpotifyTrackDTO.self, from: Data(#"{"id":"market-copy","name":"Song","linked_from":{"id":"t1"}}"#.utf8))
        rig.engine.apply(SpotifyPlayerState(device: nil, isPlaying: true, progressMs: 3000, item: dto),
                         startedAt: rig.clock.now, latency: 0)
        #expect(rig.engine.phase == .playing)
        #expect(rig.failures.isEmpty)
        #expect(!dto.matchesPlaybackID("unrelated-song"))
    }
}
