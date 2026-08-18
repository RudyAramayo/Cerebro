//
//  ROBAppleMusicService.swift
//  Cerebro
//
//  Bounded local-library playback through macOS Music automation.
//

import Foundation
import Cocoa

enum ROBAppleMusicMediaType: String, CaseIterable, Sendable {
    case song
    case playlist
}

struct ROBAppleMusicRequest: Equatable, Sendable {
    let mediaType: ROBAppleMusicMediaType
    let query: String
    let artist: String?
}

struct ROBAppleMusicItem: Equatable, Sendable {
    let mediaType: ROBAppleMusicMediaType
    let persistentID: String
    let name: String
    let artist: String?
}

enum ROBAppleMusicResolution: Equatable, Sendable {
    case found(ROBAppleMusicItem)
    case notFound
    case ambiguous([ROBAppleMusicItem])
}

enum ROBAppleMusicError: LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case automationPermissionRequired
    case musicUnavailable
    case timedOut
    case invalidResponse
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail):
            return detail
        case .automationPermissionRequired:
            return "Automation permission is required for Cerebro to control Music."
        case .musicUnavailable:
            return "The Music app is unavailable."
        case .timedOut:
            return "Music did not respond before the local automation timeout."
        case .invalidResponse:
            return "Music returned an unreadable library result."
        case .executionFailed(let detail):
            return "Music automation failed: \(detail)"
        }
    }

    var resultCode: String {
        switch self {
        case .invalidArguments: return "invalid_arguments"
        case .automationPermissionRequired: return "automation_permission_required"
        case .musicUnavailable: return "music_unavailable"
        case .timedOut: return "timed_out"
        case .invalidResponse: return "invalid_response"
        case .executionFailed: return "automation_failed"
        }
    }
}

protocol ROBAppleMusicAppControlling: Sendable {
    func resolve(
        mediaType: ROBAppleMusicMediaType,
        query: String,
        artist: String?
    ) async throws -> ROBAppleMusicResolution

    func play(mediaType: ROBAppleMusicMediaType, persistentID: String) async throws
}

final class ROBAppleMusicService: @unchecked Sendable {
    static let toolName = "apple_music"
    static let maximumQueryCharacters = 120
    static let maximumArtistCharacters = 100

    private static let maximumCandidates = 5
    private let appController: any ROBAppleMusicAppControlling

    convenience init() {
        self.init(appController: ROBAppleMusicAppleScriptController())
    }

    static func requestAutomationPermission() -> String? {
        do {
            try ROBAppleScriptPermissionProbe.ensurePermission(for: "com.apple.Music")
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ??
                "The Music app could not be reached for automation permission."
        }
    }

    init(appController: any ROBAppleMusicAppControlling) {
        self.appController = appController
    }

    func execute(arguments: [String: Any]) async -> [String: Any] {
        let request: ROBAppleMusicRequest
        do {
            request = try Self.validatedRequest(arguments)
        } catch {
            return [
                "status": "rejected",
                "error_code": "invalid_arguments",
                "error": Self.boundedDescription(error),
                "allowed_media_types": ROBAppleMusicMediaType.allCases.map(\.rawValue)
            ]
        }

        var playRequestBegan = false
        do {
            let resolution = try await appController.resolve(
                mediaType: request.mediaType,
                query: request.query,
                artist: request.artist
            )
            switch resolution {
            case .notFound:
                return [
                    "status": "not_found",
                    "media_type": request.mediaType.rawValue,
                    "detail": request.mediaType == .song
                        ? "No matching song was found in the Music library."
                        : "No matching playlist was found in Music."
                ]

            case .ambiguous(let candidates):
                let safeCandidates = candidates
                    .filter { $0.mediaType == request.mediaType }
                    .prefix(Self.maximumCandidates)
                    .compactMap(Self.candidateResult)
                guard !safeCandidates.isEmpty else {
                    throw ROBAppleMusicError.invalidResponse
                }
                return [
                    "status": "ambiguous",
                    "media_type": request.mediaType.rawValue,
                    "detail": "More than one library item matched. Ask which one to play.",
                    "candidates": Array(safeCandidates)
                ]

            case .found(let item):
                guard item.mediaType == request.mediaType,
                      Self.isSafePersistentID(item.persistentID),
                      Self.boundedText(item.name, maximum: 160) != nil else {
                    throw ROBAppleMusicError.invalidResponse
                }

                // Resolution is deliberately read-only. Playback is a second
                // mutation using only the resolved persistent ID, with the
                // cancellation barrier immediately before it.
                try Task.checkCancellation()
                playRequestBegan = true
                try await appController.play(
                    mediaType: request.mediaType,
                    persistentID: item.persistentID
                )

                var result: [String: Any] = [
                    "status": "playing",
                    "action": "play",
                    "media_type": request.mediaType.rawValue,
                    "detail": "Music confirmed that playback started.",
                    "item": Self.candidateResult(item) ?? ["name": "Library item"]
                ]
                if request.mediaType == .song, request.artist != nil {
                    result["artist_filter_applied"] = true
                }
                return result
            }
        } catch is CancellationError {
            return [
                "status": "cancelled",
                "media_type": request.mediaType.rawValue,
                "detail": playRequestBegan
                    ? "Playback cancellation was requested after the Music command began; audio may already have started."
                    : "Playback was cancelled before Music was asked to play."
            ]
        } catch {
            let musicError = error as? ROBAppleMusicError
            return [
                "status": "failed",
                "media_type": request.mediaType.rawValue,
                "error_code": musicError?.resultCode ?? "automation_failed",
                "error": Self.boundedDescription(error)
            ]
        }
    }

    private static func validatedRequest(_ arguments: [String: Any]) throws -> ROBAppleMusicRequest {
        let supportedKeys: Set<String> = ["media_type", "query", "artist"]
        guard Set(arguments.keys).isSubset(of: supportedKeys) else {
            throw ROBAppleMusicError.invalidArguments("apple_music received unsupported arguments.")
        }
        guard let rawMediaType = arguments["media_type"] as? String,
              let normalizedMediaType = boundedInput(rawMediaType, maximum: 16),
              let mediaType = ROBAppleMusicMediaType(rawValue: normalizedMediaType.lowercased()) else {
            throw ROBAppleMusicError.invalidArguments("apple_music requires media_type song or playlist.")
        }
        guard let rawQuery = arguments["query"] as? String,
              let query = boundedInput(rawQuery, maximum: maximumQueryCharacters) else {
            throw ROBAppleMusicError.invalidArguments(
                "apple_music requires a nonempty, control-free query of at most \(maximumQueryCharacters) characters."
            )
        }

        var artist: String?
        if arguments.keys.contains("artist") {
            guard mediaType == .song else {
                throw ROBAppleMusicError.invalidArguments("artist is accepted only when media_type is song.")
            }
            guard let rawArtist = arguments["artist"] as? String,
                  let safeArtist = boundedInput(rawArtist, maximum: maximumArtistCharacters) else {
                throw ROBAppleMusicError.invalidArguments(
                    "artist must be nonempty, control-free text of at most \(maximumArtistCharacters) characters."
                )
            }
            artist = safeArtist
        }
        return ROBAppleMusicRequest(mediaType: mediaType, query: query, artist: artist)
    }

    private static func boundedInput(_ text: String, maximum: Int) -> String? {
        guard !containsControlCharacter(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.count <= maximum,
              trimmed.utf8.count <= maximum * 4 else { return nil }
        return trimmed
    }

    fileprivate static func boundedText(_ text: String, maximum: Int) -> String? {
        let flattened = text
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        return flattened.unicodeScalars
            .prefix(maximum)
            .map(String.init)
            .joined()
    }

    fileprivate static func isSafePersistentID(_ value: String) -> Bool {
        !value.isEmpty &&
            value.unicodeScalars.count <= 128 &&
            value.utf8.count <= 512 &&
            !containsControlCharacter(value)
    }

    private static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func candidateResult(_ item: ROBAppleMusicItem) -> [String: Any]? {
        guard let name = boundedText(item.name, maximum: 160) else { return nil }
        var result: [String: Any] = ["name": name]
        if item.mediaType == .song,
           let artist = item.artist.flatMap({ boundedText($0, maximum: 120) }) {
            result["artist"] = artist
        }
        return result
    }

    private static func boundedDescription(_ error: Error) -> String {
        let fallback = "The Music request failed."
        let raw = (error as? LocalizedError)?.errorDescription ?? fallback
        return boundedText(raw, maximum: 240) ?? fallback
    }
}

@objcMembers
public final class ROBAppleMusicPermissions: NSObject {
    @objc public static func requestAutomationPermission() -> NSString? {
        if let error = ROBAppleMusicService.requestAutomationPermission() {
            return error as NSString
        }
        return nil
    }
}

enum ROBAppleMusicMatcher {
    static func song(
        candidates rawCandidates: [ROBAppleMusicItem],
        query: String,
        artist: String?
    ) -> ROBAppleMusicResolution {
        var candidates = unique(rawCandidates.filter { $0.mediaType == .song })
        if let artist {
            let artistKey = key(artist)
            candidates = candidates.filter { candidate in
                candidate.artist.map { key($0).contains(artistKey) } ?? false
            }
        }
        let queryKey = key(query)
        let exact = candidates.filter { key($0.name) == queryKey }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        if candidates.count == 1 { return .found(candidates[0]) }
        return candidates.isEmpty ? .notFound : .ambiguous(candidates)
    }

    static func playlist(
        candidates rawCandidates: [ROBAppleMusicItem],
        query: String
    ) -> ROBAppleMusicResolution {
        let candidates = unique(rawCandidates.filter { $0.mediaType == .playlist })
        let queryKey = key(query)
        let exact = candidates.filter { key($0.name) == queryKey }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let containing = candidates.filter { key($0.name).contains(queryKey) }
        if containing.count == 1 { return .found(containing[0]) }
        if containing.count > 1 { return .ambiguous(containing) }
        return .notFound
    }

    private static func unique(_ items: [ROBAppleMusicItem]) -> [ROBAppleMusicItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.persistentID).inserted }
    }

    private static func key(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private protocol ROBAppleMusicScriptRunning: Sendable {
    func run(script: String, arguments: [String], timeout: TimeInterval) async throws -> String
}

final class ROBAppleMusicAppleScriptController: ROBAppleMusicAppControlling, @unchecked Sendable {
    static let osascriptPath = "/usr/bin/osascript"
    static let processTimeout: TimeInterval = 8
    private static let recordSeparator = "\u{1E}"
    private static let fieldSeparator = "\u{1F}"

    private let scriptRunner: any ROBAppleMusicScriptRunning

    init() {
        scriptRunner = ROBAppleMusicOSAProcessRunner()
    }

    fileprivate init(scriptRunner: any ROBAppleMusicScriptRunning) {
        self.scriptRunner = scriptRunner
    }

    func resolve(
        mediaType: ROBAppleMusicMediaType,
        query: String,
        artist: String?
    ) async throws -> ROBAppleMusicResolution {
        do {
            try ROBAppleScriptPermissionProbe.ensurePermission(for: "Music")
        } catch {
            throw ROBAppleScriptPermissionProbe.mappedToAppleMusicError(error)
        }
        switch mediaType {
        case .song:
            let output = try await scriptRunner.run(
                script: Self.resolveSongScript,
                arguments: [query, artist ?? ""],
                timeout: Self.processTimeout
            )
            return ROBAppleMusicMatcher.song(
                candidates: try Self.songItems(from: output),
                query: query,
                artist: artist
            )
        case .playlist:
            let output = try await scriptRunner.run(
                script: Self.resolvePlaylistScript,
                arguments: [query],
                timeout: Self.processTimeout
            )
            return ROBAppleMusicMatcher.playlist(
                candidates: try Self.playlistItems(from: output),
                query: query
            )
        }
    }

    func play(mediaType: ROBAppleMusicMediaType, persistentID: String) async throws {
        guard ROBAppleMusicService.isSafePersistentID(persistentID) else {
            throw ROBAppleMusicError.invalidResponse
        }
        let script = mediaType == .song ? Self.playSongScript : Self.playPlaylistScript
        do {
            try ROBAppleScriptPermissionProbe.ensurePermission(for: "Music")
        } catch {
            throw ROBAppleScriptPermissionProbe.mappedToAppleMusicError(error)
        }
        _ = try await scriptRunner.run(
            script: script,
            arguments: [persistentID],
            timeout: Self.processTimeout
        )
    }

    private static func songItems(from output: String) throws -> [ROBAppleMusicItem] {
        try records(from: output, fieldCount: 3).map { fields in
            guard let name = ROBAppleMusicService.boundedText(fields[1], maximum: 200) else {
                throw ROBAppleMusicError.invalidResponse
            }
            let artist = fields[2].isEmpty
                ? nil
                : ROBAppleMusicService.boundedText(fields[2], maximum: 160)
            guard fields[2].isEmpty || artist != nil else {
                throw ROBAppleMusicError.invalidResponse
            }
            return ROBAppleMusicItem(
                mediaType: .song,
                persistentID: fields[0],
                name: name,
                artist: artist
            )
        }
    }

    private static func playlistItems(from output: String) throws -> [ROBAppleMusicItem] {
        try records(from: output, fieldCount: 2).map { fields in
            guard let name = ROBAppleMusicService.boundedText(fields[1], maximum: 200) else {
                throw ROBAppleMusicError.invalidResponse
            }
            return ROBAppleMusicItem(
                mediaType: .playlist,
                persistentID: fields[0],
                name: name,
                artist: nil
            )
        }
    }

    private static func records(from output: String, fieldCount: Int) throws -> [[String]] {
        guard output.utf8.count <= 64 * 1_024 else { throw ROBAppleMusicError.invalidResponse }
        var records: [[String]] = []
        for record in output.split(separator: Character(recordSeparator), omittingEmptySubsequences: true) {
            let fields = record.split(
                separator: Character(fieldSeparator),
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == fieldCount,
                  ROBAppleMusicService.isSafePersistentID(fields[0]),
                  ROBAppleMusicService.boundedText(fields[1], maximum: 200) != nil else {
                throw ROBAppleMusicError.invalidResponse
            }
            records.append(fields)
        }
        return records
    }

    // Queries are always argv values. These fixed scripts are never assembled
    // from user text and no shell is involved.
    static let resolveSongScript = """
    on run argv
      if (count of argv) is not 2 then error "Invalid Cerebro Music arguments"
      set queryText to item 1 of argv as text
      set artistText to item 2 of argv as text
      set fieldSeparator to character id 31
      set recordSeparator to character id 30
      set exactText to ""
      set otherText to ""
      set exactCount to 0
      set otherCount to 0
      tell application id "com.apple.Music"
        set matchingTracks to search library playlist 1 for queryText only songs
        repeat with matchedTrack in matchingTracks
          try
            set itemID to persistent ID of matchedTrack as text
            set itemName to name of matchedTrack as text
            set itemArtist to artist of matchedTrack as text
            if (length of itemID) > 128 then set itemID to text 1 thru 128 of itemID
            if (length of itemName) > 200 then set itemName to text 1 thru 200 of itemName
            if (length of itemArtist) > 160 then set itemArtist to text 1 thru 160 of itemArtist
            if itemID is not "" and itemName is not "" and itemID does not contain fieldSeparator and itemName does not contain fieldSeparator and itemArtist does not contain fieldSeparator and itemID does not contain recordSeparator and itemName does not contain recordSeparator and itemArtist does not contain recordSeparator then
              set artistMatches to true
              set titleIsExact to false
              ignoring case, diacriticals
                if artistText is not "" then set artistMatches to itemArtist contains artistText
                set titleIsExact to itemName is queryText
              end ignoring
              if artistMatches then
                set itemRecord to itemID & fieldSeparator & itemName & fieldSeparator & itemArtist & recordSeparator
                if titleIsExact and exactCount < 12 then
                  set exactText to exactText & itemRecord
                  set exactCount to exactCount + 1
                else if not titleIsExact and otherCount < 12 then
                  set otherText to otherText & itemRecord
                  set otherCount to otherCount + 1
                end if
              end if
            end if
          end try
        end repeat
      end tell
      if exactCount > 0 then return exactText
      return otherText
    end run
    """

    static let resolvePlaylistScript = """
    on run argv
      if (count of argv) is not 1 then error "Invalid Cerebro Music arguments"
      set queryText to item 1 of argv as text
      set fieldSeparator to character id 31
      set recordSeparator to character id 30
      set exactText to ""
      set containsText to ""
      set exactCount to 0
      set containsCount to 0
      tell application id "com.apple.Music"
        set libraryPlaylists to (every user playlist) & (every subscription playlist)
        repeat with matchedPlaylist in libraryPlaylists
          try
            set itemID to persistent ID of matchedPlaylist as text
            set itemName to name of matchedPlaylist as text
            if (length of itemID) > 128 then set itemID to text 1 thru 128 of itemID
            if (length of itemName) > 200 then set itemName to text 1 thru 200 of itemName
            if itemID is not "" and itemName is not "" and itemID does not contain fieldSeparator and itemName does not contain fieldSeparator and itemID does not contain recordSeparator and itemName does not contain recordSeparator then
              ignoring case, diacriticals
                if itemName is queryText and exactCount < 12 then
                  set exactText to exactText & itemID & fieldSeparator & itemName & recordSeparator
                  set exactCount to exactCount + 1
                else if itemName contains queryText and containsCount < 12 then
                  set containsText to containsText & itemID & fieldSeparator & itemName & recordSeparator
                  set containsCount to containsCount + 1
                end if
              end ignoring
            end if
          end try
        end repeat
      end tell
      if exactCount > 0 then return exactText
      return containsText
    end run
    """

    static let playSongScript = """
    on run argv
      if (count of argv) is not 1 then error "Invalid Cerebro Music arguments"
      set itemID to item 1 of argv as text
      tell application id "com.apple.Music"
        set matchingTracks to every track of library playlist 1 whose persistent ID is itemID
        if (count of matchingTracks) is not 1 then error "Resolved song is no longer uniquely available"
        set targetTrack to item 1 of matchingTracks
        play targetTrack
        repeat with attempt from 1 to 20
          if player state is playing then
            try
              if (persistent ID of current track as text) is itemID then return "played"
            end try
          end if
          delay 0.1
        end repeat
        error "Music did not begin playing the resolved song"
      end tell
    end run
    """

    static let playPlaylistScript = """
    on run argv
      if (count of argv) is not 1 then error "Invalid Cerebro Music arguments"
      set itemID to item 1 of argv as text
      tell application id "com.apple.Music"
        set matchingPlaylists to (every user playlist whose persistent ID is itemID) & (every subscription playlist whose persistent ID is itemID)
        if (count of matchingPlaylists) is not 1 then error "Resolved playlist is no longer uniquely available"
        set targetPlaylist to item 1 of matchingPlaylists
        play targetPlaylist
        repeat with attempt from 1 to 20
          if player state is playing then
            try
              if (persistent ID of current playlist as text) is itemID then return "played"
            end try
          end if
          delay 0.1
        end repeat
        error "Music did not begin playing the resolved playlist"
      end tell
    end run
    """
}

private final class ROBAppleMusicOSAProcessRunner: ROBAppleMusicScriptRunning, @unchecked Sendable {
    func run(script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let invocation = ROBAppleMusicProcessInvocation(
            script: script,
            arguments: arguments,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await invocation.run()
        } onCancel: {
            invocation.cancel()
        }
    }
}

private final class ROBAppleMusicProcessInvocation: @unchecked Sendable {
    private let script: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(script: String, arguments: [String], timeout: TimeInterval) {
        self.script = script
        self.arguments = arguments
        self.timeout = timeout
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    continuation.resume(returning: try runSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    private func runSynchronously() throws -> String {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ROBAppleMusicAppleScriptController.osascriptPath)
        task.arguments = ["-e", script, "--"] + arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let pipeDrain = ROBAppleMusicPipeDrain(
            output: outputPipe.fileHandleForReading,
            error: errorPipe.fileHandleForReading
        )
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        let completion = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in completion.signal() }

        // Launch and cancellation share one lock-backed linearization point.
        // If cancellation wins, no process starts. If launch wins, cancel()
        // observes a running process and terminates it.
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        process = task
        do {
            try task.run()
        } catch {
            if process === task { process = nil }
            lock.unlock()
            throw ROBAppleMusicError.executionFailed("The local osascript process could not start.")
        }
        lock.unlock()
        pipeDrain.start()

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            if task.isRunning { task.terminate() }
            _ = completion.wait(timeout: .now() + 0.5)
            if task.isRunning { task.interrupt() }
            clearProcess(task)
            if isCancelled { throw CancellationError() }
            throw ROBAppleMusicError.timedOut
        }

        clearProcess(task)
        if isCancelled { throw CancellationError() }
        guard pipeDrain.waitForEOF(timeout: 1) else {
            throw ROBAppleMusicError.invalidResponse
        }
        let captured = pipeDrain.capturedData()
        let outputData = captured.output
        let errorData = captured.error
        guard task.terminationStatus == 0 else {
            throw Self.mappedError(errorData)
        }
        guard !captured.outputOverflowed,
              let output = String(data: outputData, encoding: .utf8) else {
            throw ROBAppleMusicError.invalidResponse
        }
        return output.trimmingCharacters(in: .newlines)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func clearProcess(_ task: Process) {
        lock.lock()
        if process === task { process = nil }
        lock.unlock()
    }

    private static func mappedError(_ data: Data) -> ROBAppleMusicError {
        let raw = String(data: data.prefix(4_096), encoding: .utf8) ?? "Unknown Apple Events error"
        let lower = raw.lowercased()
        if lower.contains("-1743") ||
            lower.contains("not authorized to send apple events") ||
            lower.contains("not permitted to send apple events") ||
            lower.contains("automation permission") {
            return .automationPermissionRequired
        }
        if lower.contains("application isn’t running") ||
            lower.contains("application isn't running") ||
            lower.contains("application \"music\" can’t be found") ||
            lower.contains("application \"music\" can't be found") {
            return .musicUnavailable
        }
        let detail = ROBAppleMusicService.boundedText(raw, maximum: 200) ?? "Unknown Apple Events error"
        return .executionFailed(detail)
    }
}

private final class ROBAppleMusicPipeDrain: @unchecked Sendable {
    private static let maximumOutputBytes = 64 * 1_024
    private static let maximumErrorBytes = 4 * 1_024

    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private let completionGroup = DispatchGroup()
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()
    private var outputOverflowed = false

    init(output: FileHandle, error: FileHandle) {
        outputHandle = output
        errorHandle = error
    }

    func start() {
        startDrain(handle: outputHandle, isOutput: true)
        startDrain(handle: errorHandle, isOutput: false)
    }

    func waitForEOF(timeout: TimeInterval) -> Bool {
        completionGroup.wait(timeout: .now() + timeout) == .success
    }

    func capturedData() -> (output: Data, error: Data, outputOverflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (outputData, errorData, outputOverflowed)
    }

    private func startDrain(handle: FileHandle, isOutput: Bool) {
        completionGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completionGroup.leave() }
            while true {
                let chunk = handle.readData(ofLength: 4_096)
                if chunk.isEmpty { return }
                append(chunk, isOutput: isOutput)
            }
        }
    }

    private func append(_ chunk: Data, isOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isOutput {
            let remaining = max(0, Self.maximumOutputBytes + 1 - outputData.count)
            if remaining > 0 { outputData.append(chunk.prefix(remaining)) }
            if outputData.count > Self.maximumOutputBytes { outputOverflowed = true }
        } else {
            let remaining = max(0, Self.maximumErrorBytes - errorData.count)
            if remaining > 0 { errorData.append(chunk.prefix(remaining)) }
        }
    }
}

private enum ROBAppleScriptPermissionProbeError: Error {
    case permissionRequired
    case applicationUnavailable
    case executionFailed(String)
}

private enum ROBAppleScriptPermissionProbe {
    static func ensurePermission(for application: String) throws {
        let scriptSource = """
        tell application id "\(application)"
          return name
        end tell
        """
        if Thread.isMainThread {
            try run(source: scriptSource)
            return
        }
        var capturedError: Error?
        DispatchQueue.main.sync {
            do {
                try run(source: scriptSource)
            } catch {
                capturedError = error
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    static func run(source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw ROBAppleScriptPermissionProbeError.executionFailed("The local AppleScript engine is unavailable.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if error == nil {
            return
        }
        throw mapped(error)
    }

    private static func mapped(_ error: NSDictionary?) -> Error {
        let code = error?[NSAppleScript.errorNumber] as? Int
        let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Unknown Apple Events error"
        let lower = message.lowercased()
        if code == -1743 || lower.contains("not authorized") ||
            lower.contains("not permitted") ||
            lower.contains("not allowed") {
            return ROBAppleScriptPermissionProbeError.permissionRequired
        }
        let unavailableSignals = [
            "application isn’t running",
            "application isn't running",
            "application \"music\" can’t be found",
            "application \"music\" can't be found",
            "application \"com.apple.music\" can’t be found",
            "application \"com.apple.music\" can't be found",
            "not found",
        ]
        if unavailableSignals.contains(where: { lower.contains($0) }) {
            return ROBAppleScriptPermissionProbeError.applicationUnavailable
        }
        return ROBAppleScriptPermissionProbeError.executionFailed(
            Self.bounded(message, maximum: 240)
        )
    }

    static func mappedToAppleMusicError(_ error: Error) -> ROBAppleMusicError {
        if let permissionError = error as? ROBAppleScriptPermissionProbeError {
            switch permissionError {
            case .permissionRequired:
                return .automationPermissionRequired
            case .applicationUnavailable:
                return .musicUnavailable
            case .executionFailed(let detail):
                return .executionFailed(detail)
            }
        }
        if let musicError = error as? ROBAppleMusicError {
            return musicError
        }
        return .executionFailed(
            ROBAppleMusicService.boundedText(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                maximum: 240
            ) ?? "Music automation failed."
        )
    }


    private static func bounded(_ value: String, maximum: Int) -> String {
        let flattened = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !flattened.isEmpty else { return "" }
        return String(flattened.unicodeScalars.prefix(maximum).map(String.init).joined())
    }
}
