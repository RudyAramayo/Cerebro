import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class FixtureMusicController: ROBAppleMusicAppControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var resolution: ROBAppleMusicResolution = .notFound
    var resolveError: Error?
    var playError: Error?
    var cancelBeforeResolveReturns = false

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func resolve(
        mediaType: ROBAppleMusicMediaType,
        query: String,
        artist: String?
    ) async throws -> ROBAppleMusicResolution {
        record("resolve:\(mediaType.rawValue):\(query):\(artist ?? "")")
        if let resolveError { throw resolveError }
        if cancelBeforeResolveReturns {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return resolution
    }

    func play(mediaType: ROBAppleMusicMediaType, persistentID: String) async throws {
        record("play:\(mediaType.rawValue):\(persistentID)")
        if let playError { throw playError }
    }

    private func record(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

@main
struct ROBAppleMusicServiceFixtureTests {
    static func main() async throws {
        try testFixedAutomationContract()
        try testPlaylistMatching()
        try testSongMatchingWithArtist()
        try await testStrictInvalidArguments()
        try await testFoundAndMutationOrder()
        try await testNotFoundDoesNotPlay()
        try await testAmbiguityIsBoundedAndDoesNotPlay()
        try await testAutomationErrorsAreHonest()
        try await testCancellationBarrierPreventsPlay()
        print("ROB Apple Music service fixtures passed")
    }

    private static func testFixedAutomationContract() throws {
        try expect(ROBAppleMusicService.toolName == "apple_music", "Tool name changed")
        try expect(
            ROBAppleMusicAppleScriptController.osascriptPath == "/usr/bin/osascript",
            "Music automation must use the fixed system osascript path"
        )
        try expect(
            ROBAppleMusicAppleScriptController.resolveSongScript.contains(
                "search library playlist 1 for queryText only songs"
            ),
            "Song resolution no longer searches the local Music library"
        )
        try expect(
            ROBAppleMusicAppleScriptController.resolveSongScript.contains("item 1 of argv") &&
                ROBAppleMusicAppleScriptController.resolveSongScript.contains("item 2 of argv") &&
                ROBAppleMusicAppleScriptController.resolvePlaylistScript.contains("item 1 of argv"),
            "Queries must enter fixed AppleScripts through argv"
        )
        try expect(
            ROBAppleMusicAppleScriptController.resolveSongScript.contains("itemArtist contains artistText"),
            "Song artist filtering must happen before the bounded result set is emitted"
        )
        try expect(
            ROBAppleMusicAppleScriptController.resolvePlaylistScript.contains("subscription playlist") &&
                ROBAppleMusicAppleScriptController.playPlaylistScript.contains("subscription playlist"),
            "Saved subscription playlists are not covered by resolution and playback"
        )
        try expect(
            ROBAppleMusicAppleScriptController.playSongScript.contains("persistent ID is itemID") &&
                ROBAppleMusicAppleScriptController.playPlaylistScript.contains("persistent ID is itemID"),
            "Playback must re-resolve only the selected persistent ID"
        )
        try expect(
            ROBAppleMusicAppleScriptController.playSongScript.contains("persistent ID of current track") &&
                ROBAppleMusicAppleScriptController.playPlaylistScript.contains("persistent ID of current playlist"),
            "Playback success must be correlated to the resolved item before returning status playing"
        )
    }

    private static func testPlaylistMatching() throws {
        let roadTrip = item(.playlist, "P1", "Road Trip")
        let roadTripArchive = item(.playlist, "P2", "Road Trip Archive")
        let exact = ROBAppleMusicMatcher.playlist(
            candidates: [roadTripArchive, roadTrip],
            query: "road trip"
        )
        try expect(exact == .found(roadTrip), "Exact playlist match did not outrank contains")

        let uniqueContains = ROBAppleMusicMatcher.playlist(
            candidates: [roadTripArchive],
            query: "trip"
        )
        try expect(uniqueContains == .found(roadTripArchive), "Unique contains playlist did not resolve")

        let ambiguous = ROBAppleMusicMatcher.playlist(
            candidates: [roadTrip, roadTripArchive],
            query: "road"
        )
        guard case .ambiguous(let candidates) = ambiguous else {
            throw FixtureFailure.failed("Multiple contains playlist matches were not ambiguous")
        }
        try expect(candidates.count == 2, "Ambiguous playlist candidates were lost")
    }

    private static func testSongMatchingWithArtist() throws {
        let first = item(.song, "S1", "Heroes", artist: "David Bowie")
        let second = item(.song, "S2", "Heroes", artist: "Motörhead")
        let resolution = ROBAppleMusicMatcher.song(
            candidates: [first, second],
            query: "heroes",
            artist: "Bowie"
        )
        try expect(resolution == .found(first), "Artist filtering did not disambiguate the song")
    }

    private static func testStrictInvalidArguments() async throws {
        let controller = FixtureMusicController()
        let service = ROBAppleMusicService(appController: controller)
        let rejectedArguments: [[String: Any]] = [
            [:],
            ["media_type": "album", "query": "Blue"],
            ["media_type": "song"],
            ["media_type": "song", "query": ""],
            ["media_type": "song", "query": "Bad\nQuery"],
            ["media_type": "song", "query": String(repeating: "q", count: ROBAppleMusicService.maximumQueryCharacters + 1)],
            [
                "media_type": "song",
                "query": "a" + String(
                    repeating: "\u{0301}",
                    count: ROBAppleMusicService.maximumQueryCharacters
                )
            ],
            ["media_type": "song", "query": "Blue", "artist": "Bad\u{0000}Artist"],
            ["media_type": "playlist", "query": "Favorites", "artist": "Someone"],
            ["media_type": "song", "query": "Blue", "url": "https://example.com"]
        ]
        for arguments in rejectedArguments {
            let result = await service.execute(arguments: arguments)
            try expect(result["status"] as? String == "rejected", "Invalid arguments were accepted: \(arguments.keys)")
            try expect(JSONSerialization.isValidJSONObject(result), "Rejected result was not JSON-safe")
        }
        try expect(controller.events.isEmpty, "Rejected arguments reached Music")
    }

    private static func testFoundAndMutationOrder() async throws {
        let controller = FixtureMusicController()
        controller.resolution = .found(item(.song, "SONG-42", "Heroes", artist: "David Bowie"))
        let result = await ROBAppleMusicService(appController: controller).execute(arguments: [
            "media_type": "song",
            "query": " Heroes ",
            "artist": "David Bowie"
        ])
        try expect(result["status"] as? String == "playing", "Successful playback was not reported as playing")
        try expect(result["action"] as? String == "play", "Successful result omitted its action")
        try expect(
            controller.events == [
                "resolve:song:Heroes:David Bowie",
                "play:song:SONG-42"
            ],
            "Playback did not happen strictly after resolution by persistent ID"
        )
        try expect(JSONSerialization.isValidJSONObject(result), "Playing result was not JSON-safe")
    }

    private static func testNotFoundDoesNotPlay() async throws {
        let controller = FixtureMusicController()
        controller.resolution = .notFound
        let result = await ROBAppleMusicService(appController: controller).execute(arguments: [
            "media_type": "playlist",
            "query": "Missing Mix"
        ])
        try expect(result["status"] as? String == "not_found", "Missing playlist was not reported honestly")
        try expect(controller.events == ["resolve:playlist:Missing Mix:"], "Not-found resolution attempted playback")
    }

    private static func testAmbiguityIsBoundedAndDoesNotPlay() async throws {
        let controller = FixtureMusicController()
        controller.resolution = .ambiguous((0..<9).map {
            item(.playlist, "P\($0)", "Workout Mix \($0)")
        })
        let result = await ROBAppleMusicService(appController: controller).execute(arguments: [
            "media_type": "playlist",
            "query": "Workout"
        ])
        try expect(result["status"] as? String == "ambiguous", "Ambiguous playlist was not reported")
        let candidates = try require(result["candidates"] as? [[String: Any]], "Ambiguous result omitted candidates")
        try expect(candidates.count == 5, "Candidate output was not bounded")
        try expect(controller.events.count == 1, "Ambiguous resolution attempted playback")
        try expect(JSONSerialization.isValidJSONObject(result), "Ambiguous result was not JSON-safe")
    }

    private static func testAutomationErrorsAreHonest() async throws {
        let resolvingController = FixtureMusicController()
        resolvingController.resolveError = ROBAppleMusicError.automationPermissionRequired
        let denied = await ROBAppleMusicService(appController: resolvingController).execute(arguments: [
            "media_type": "song", "query": "Heroes"
        ])
        try expect(denied["status"] as? String == "failed", "TCC denial was presented as playback")
        try expect(
            denied["error_code"] as? String == "automation_permission_required",
            "TCC denial did not retain its actionable error code"
        )

        let playingController = FixtureMusicController()
        playingController.resolution = .found(item(.playlist, "P1", "Favorites"))
        playingController.playError = ROBAppleMusicError.timedOut
        let timedOut = await ROBAppleMusicService(appController: playingController).execute(arguments: [
            "media_type": "playlist", "query": "Favorites"
        ])
        try expect(timedOut["status"] as? String == "failed", "Timed-out play was presented as success")
        try expect(timedOut["error_code"] as? String == "timed_out", "Timeout error was obscured")
        try expect(playingController.events == ["resolve:playlist:Favorites:", "play:playlist:P1"], "Play error order changed")
    }

    private static func testCancellationBarrierPreventsPlay() async throws {
        let controller = FixtureMusicController()
        controller.resolution = .found(item(.song, "S1", "Heroes", artist: "David Bowie"))
        controller.cancelBeforeResolveReturns = true
        let result = await Task {
            await ROBAppleMusicService(appController: controller).execute(arguments: [
                "media_type": "song", "query": "Heroes"
            ])
        }.value
        try expect(result["status"] as? String == "cancelled", "Cancellation was not reported")
        try expect(controller.events == ["resolve:song:Heroes:"], "Cancellation barrier allowed playback")
    }

    private static func item(
        _ mediaType: ROBAppleMusicMediaType,
        _ persistentID: String,
        _ name: String,
        artist: String? = nil
    ) -> ROBAppleMusicItem {
        ROBAppleMusicItem(
            mediaType: mediaType,
            persistentID: persistentID,
            name: name,
            artist: artist
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() { throw FixtureFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureFailure.failed(message) }
        return value
    }
}
