#!/usr/bin/env python3
"""Static regression checks for headless Insta360 capture and perception."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_DELEGATE = (ROOT / "Cerebro" / "AppDelegate.m").read_text(encoding="utf-8")
CAMERA_SERVICE = (
    ROOT / "Cerebro" / "ROBInsta360CameraService.swift"
).read_text(encoding="utf-8")
PERCEPTION_SERVICE = (
    ROOT / "Cerebro" / "ROBInsta360PerceptionService.swift"
).read_text(encoding="utf-8")
DETECTOR_REGISTRY = (
    ROOT / "Cerebro" / "ROBDynamicDetectorRegistry.swift"
).read_text(encoding="utf-8")
SCENE_STORE = (ROOT / "Cerebro" / "ROBSceneSnapshot.swift").read_text(
    encoding="utf-8"
)


def braced_declaration(source: str, signature: str) -> str:
    declaration_start = source.index(signature)
    body_start = source.index("{", declaration_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[declaration_start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    startup = braced_declaration(
        APP_DELEGATE, "- (void)applicationDidFinishLaunching:"
    )
    shutdown = braced_declaration(APP_DELEGATE, "- (void)applicationWillTerminate:")
    # AppDelegate's private-interface declaration has the same selector, so
    # anchor this lookup to the implementation's opening brace.
    wake = braced_declaration(
        APP_DELEGATE, "- (void)workspaceDidWake:(NSNotification *)notification\n{"
    )

    require(
        startup.count("[[ROBInsta360CameraService shared] start];") == 1,
        "Cerebro startup no longer starts the singleton Insta360 service",
    )
    require(
        shutdown.count("[[ROBInsta360CameraService shared] stop];") == 1,
        "Cerebro termination no longer stops the singleton Insta360 service",
    )
    require(
        wake.count("[[ROBInsta360CameraService shared] recoverAfterWake];") == 1,
        "Wake recovery no longer reconnects the headless Insta360 service",
    )
    for lifecycle_name, lifecycle_method in (
        ("startup", startup),
        ("termination", shutdown),
        ("wake", wake),
    ):
        for forbidden in (
            "ROBInsta360DiagnosticsWindowController",
            "showInsta360Diagnostics:",
            "setDiagnosticsPreviewVisible",
            "showWindow:",
        ):
            require(
                forbidden not in lifecycle_method,
                f"Insta360 {lifecycle_name} unexpectedly depends on diagnostics UI: {forbidden}",
            )

    start = braced_declaration(CAMERA_SERVICE, "public func start()")
    stop = braced_declaration(CAMERA_SERVICE, "public func stop()")
    recover = braced_declaration(CAMERA_SERVICE, "public func recoverAfterWake()")
    require(
        "guard !self.desiredRunning else { return }" in start
        and "self.desiredRunning = true" in start
        and "self.connect(generation: self.generation)" in start,
        "Headless Insta360 start is no longer idempotent and connection-owning",
    )
    require(
        "self.desiredRunning = false" in stop
        and "self.stopOwnedPreview" in stop
        and "self.cancelRuntime()" in stop,
        "Headless Insta360 stop no longer releases its owned runtime",
    )
    require(
        "guard self.desiredRunning else { return }" in recover
        and "self.cancelRuntime()" in recover
        and "self.connect(generation: self.generation)" in recover,
        "Wake recovery no longer rebuilds a previously-running session",
    )

    # Decoder demand must react to settings even when no diagnostics window has
    # ever been constructed. Both detector and MLX preferences feed one handler.
    initializer = braced_declaration(CAMERA_SERVICE, "private override init()")
    require(
        initializer.count("selector: #selector(perceptionSettingsDidChange(_:))") == 2
        and "name: .robDetectorSettingsDidChange" in initializer
        and "name: .robMLXRuntimeDidChange" in initializer,
        "The headless service no longer observes every automatic-analysis preference",
    )
    settings_changed = braced_declaration(
        CAMERA_SERVICE, "private func perceptionSettingsDidChange("
    )
    require(
        "refreshDecoderDemand()" in settings_changed,
        "A perception preference change no longer reevaluates decoder demand",
    )
    analysis_demand = braced_declaration(
        CAMERA_SERVICE, "private var analysisNeedsFrames: Bool"
    )
    local_analysis_demand = braced_declaration(
        CAMERA_SERVICE, "private var localAnalysisNeedsFrames: Bool"
    )
    require(
        "geminiVideoDemandActive || localAnalysisNeedsFrames" in analysis_demand
        and "processingFramesPerSecond(for: .insta360) > 0"
        in local_analysis_demand
        and "ROBMLXRuntime.shared.insta360DetectionEnabled"
        in local_analysis_demand
        and "registry.requiresFrames(for: .insta360)" in local_analysis_demand,
        "Automatic MLX/detector consumers no longer keep headless decoding active",
    )
    decoder_demand = braced_declaration(
        CAMERA_SERVICE, "private func reevaluateDecoderDemand()"
    )
    require(
        "diagnosticsPreviewVisible || analysisNeedsFrames" in decoder_demand
        and "startDecoder(url: url, generation: generation)" in decoder_demand
        and "stopDecoder()" in decoder_demand,
        "Decoder lifetime is no longer driven by preview-or-analysis demand",
    )

    # Gemini receives the completed JPEG on the camera service queue with the
    # monotonic capture timestamp taken at frame extraction. It must not wait
    # for main-thread NSImage work, which could make an old panorama look new.
    consumer_protocol = braced_declaration(
        CAMERA_SERVICE, "public protocol ROBInsta360VideoFrameConsumer"
    )
    require(
        "capturedAt: Date" in consumer_protocol
        and "capturedAtUptime: TimeInterval" in consumer_protocol,
        "The raw Gemini consumer lost its original monotonic capture time",
    )
    set_consumer = braced_declaration(
        CAMERA_SERVICE, "public func setGeminiFrameConsumer("
    )
    require(
        "queue.async" in set_consumer
        and "self.geminiFrameConsumer = consumer" in set_consumer
        and "private weak var geminiFrameConsumer" in CAMERA_SERVICE,
        "Raw Gemini consumer access is no longer weak and service-queue serialized",
    )
    consume_video = braced_declaration(CAMERA_SERVICE, "private func consumeVideo(")
    for token in (
        "let capturedAtUptime = ProcessInfo.processInfo.systemUptime",
        "if geminiVideoDemandActive",
        "geminiFrameConsumer?.consumeInsta360JPEGFrame(",
        "capturedAt: capturedAt",
        "capturedAtUptime: capturedAtUptime",
    ):
        require(token in consume_video, f"Direct Gemini JPEG delivery lost: {token}")
    require(
        "DispatchQueue.main" not in consume_video
        and consume_video.index("consumeInsta360JPEGFrame(")
        < consume_video.index("scheduleLatestFrameDelivery()"),
        "Gemini's raw frame path can still be delayed by the AppKit main thread",
    )

    # Every locally demanded decoded frame fans out to MLX/object processing
    # and the dynamic human detector before the UI-only change notification is
    # posted. Capture time must survive the raw-JPEG coalescing boundary.
    frame_delivery = braced_declaration(
        CAMERA_SERVICE, "private func scheduleLatestFrameDelivery()"
    )
    require(
        "geminiFrameConsumer" not in frame_delivery
        and "consumeInsta360JPEGFrame" not in frame_delivery,
        "Optional UI frame delivery still owns or delays the Gemini consumer",
    )
    fanout = (
        "self.latestFrame = image",
        "ROBInsta360PerceptionService.shared.offer(",
        "ROBDynamicDetectorRegistry.shared.offer(",
        "NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange",
    )
    for token in fanout:
        require(token in frame_delivery, f"Decoded-frame fan-out lost: {token}")
    require(
        [frame_delivery.index(token) for token in fanout]
        == sorted(frame_delivery.index(token) for token in fanout),
        "Perception consumers must receive a frame before the display notification",
    )
    require(
        frame_delivery.count("capturedAt: frame.capturedAt") >= 2,
        "Decoded Insta360 capture time no longer reaches its frame consumers",
    )

    perception_offer = braced_declaration(
        PERCEPTION_SERVICE, "public func offer(_ image: NSImage, capturedAt: Date)"
    )
    require(
        "ROBMLXRuntime.shared.insta360DetectionEnabled" in perception_offer
        and 'source: "insta360-preview"' in perception_offer
        and 'enabled("generic-objects", source: .insta360)' in perception_offer
        and "ROBSceneSnapshotStore.shared.updateObjects(objects)" in perception_offer,
        "The panoramic perception consumer no longer supplies robot scene context",
    )

    # Six-sector mode must detect full-body rectangles and map their bounds
    # from each crop back into stitched-panorama coordinates.
    geometry = braced_declaration(
        DETECTOR_REGISTRY, "public var insta360AnalysisGeometry: ROBInsta360AnalysisGeometry"
    )
    require(
        "else { return .sixSectors }" in geometry
        and "?? .sixSectors" in geometry,
        "Six-sector human analysis is no longer the deterministic default",
    )
    process = braced_declaration(DETECTOR_REGISTRY, "private func process(")
    for token in (
        "if geometry == .sixSectors",
        "inputs = (0..<6).compactMap",
        "image.cropping(",
        "VNDetectHumanRectanglesRequest",
        "VNDetectHumanRectanglesRequestRevision2",
        "humanRectangles.upperBodyOnly = false",
        "input.xOffset + Double(bounds.origin.x) * input.xScale",
        "Double(bounds.width) * input.xScale",
        'id: "person-\\(index)"',
        "publishInsta360PeopleIfCurrent(people, generation: generation)",
    ):
        require(token in process, f"Six-sector human processing lost: {token}")
    require(
        "$0.bounds.x == $1.bounds.x" in process
        and "$0.bounds.y < $1.bounds.y" in process,
        "Detected people no longer receive deterministic panorama-order IDs",
    )

    publish_people = braced_declaration(
        DETECTOR_REGISTRY, "private func publishInsta360PeopleIfCurrent("
    )
    require(
        "ROBSceneSnapshotStore.shared.updatePeople(" in publish_people
        and "source: ROBDetectorSource.insta360.rawValue" in publish_people
        and "generation == resultGeneration[.insta360" in publish_people,
        "Insta360 people are no longer generation-safe, source-owned scene facts",
    )
    update_people = braced_declaration(SCENE_STORE, "public func updatePeople(")
    make_snapshot = braced_declaration(
        SCENE_STORE, "private func makeSnapshotLocked(nowUptime: TimeInterval)"
    )
    require(
        'let requestedID = "\\(sourceID)-\\(person.id)"' in update_people
        and "supplementalPeopleBySource[sourceID]" in update_people,
        "Supplemental person IDs are no longer scoped to their perception source",
    )
    require(
        "stalePeopleSources" in make_snapshot
        and "supplementalPeopleBySource.keys.sorted()" in make_snapshot
        and "let currentPeople = cameraPeople + supplementalPeople" in make_snapshot,
        "Fresh source-owned Insta360 people no longer merge into robot scene snapshots",
    )

    print("Headless Insta360 lifecycle and automatic perception static checks passed")


if __name__ == "__main__":
    main()
