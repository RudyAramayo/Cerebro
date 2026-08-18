#!/usr/bin/env python3
"""Static regressions for headless main-camera ownership and diagnostics UI."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)
CAMERA = (ROOT / "Cerebro" / "CameraViewController.swift").read_text(
    encoding="utf-8"
)
MANAGER = (ROOT / "Cerebro" / "CameraManager.swift").read_text(
    encoding="utf-8"
)
PERCEPTION_SETTINGS = (
    ROOT / "Cerebro" / "ROBInsta360ProcessingSettingsViewController.swift"
).read_text(encoding="utf-8")
SETTINGS_HOST = (
    ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
).read_text(encoding="utf-8")
SYSTEM_STATUS = (
    ROOT / "Cerebro" / "ROBSystemStatusCoordinator.swift"
).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_from(source: str, declaration_start: int) -> str:
    """Return one declaration while ignoring braces in comments and strings."""
    body_start = source.index("{", declaration_start)
    depth = 0
    in_string = False
    in_character = False
    in_line_comment = False
    in_block_comment = False
    escaped = False
    index = body_start
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if in_line_comment:
            if character == "\n":
                in_line_comment = False
        elif in_block_comment:
            if character == "*" and following == "/":
                in_block_comment = False
                index += 1
        elif in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif in_character:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == "'":
                in_character = False
        elif character == "/" and following == "/":
            in_line_comment = True
            index += 1
        elif character == "/" and following == "*":
            in_block_comment = True
            index += 1
        elif character == '"':
            in_string = True
        elif character == "'":
            in_character = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[declaration_start : index + 1]
        index += 1
    raise AssertionError("Unterminated braced declaration")


def braced_declaration(source: str, signature: str) -> str:
    try:
        declaration_start = source.index(signature)
    except ValueError as error:
        raise AssertionError(f"Missing declaration: {signature}") from error
    return braced_from(source, declaration_start)


def objc_methods(source: str) -> dict[str, str]:
    methods: dict[str, str] = {}
    pattern = re.compile(
        r"(?m)^\s*-\s*\([^\n)]+\)\s*([A-Za-z_][A-Za-z0-9_]*)[^\n{]*\n?\s*\{"
    )
    for match in pattern.finditer(source):
        methods[match.group(1)] = braced_from(source, match.start())
    return methods


def swift_bool_property(source: str, name: str) -> str:
    pattern = re.compile(
        rf"(?:private\s+)?var\s+{re.escape(name)}\s*:\s*Bool\s*\{{"
    )
    match = pattern.search(source)
    require(match is not None, f"Missing computed camera demand property: {name}")
    return braced_from(source, match.start())


def called_self_methods(body: str) -> set[str]:
    return set(re.findall(r"\[self\s+([A-Za-z_][A-Za-z0-9_]*)", body))


def related_objc_bodies(
    methods: dict[str, str], roots: list[str], name_pattern: str
) -> str:
    """Follow small Objective-C helper chains used to synchronize diagnostics."""
    pending = list(roots)
    visited: set[str] = set()
    bodies: list[str] = []
    while pending:
        name = pending.pop()
        if name in visited or name not in methods:
            continue
        visited.add(name)
        body = methods[name]
        bodies.append(body)
        for called in called_self_methods(body):
            if re.search(name_pattern, called, re.IGNORECASE):
                pending.append(called)
    return "\n".join(bodies)


def main() -> None:
    # Runtime creation is a startup responsibility. Presenting the diagnostic
    # window is deliberately separate and development-mode-only.
    methods = objc_methods(MAIN)
    startup = methods.get("viewDidLoad", "")
    require(startup, "ROBMainViewController.viewDidLoad is missing")

    runtime_candidates = [
        (name, body)
        for name, body in methods.items()
        if "CameraWindowController" in body
        and "cameraViewController" in body
        and "showWindow" not in body
    ]
    require(
        len(runtime_candidates) == 1,
        "Main-camera runtime creation must have one idempotent, non-presenting owner",
    )
    ensure_name, ensure_runtime = runtime_candidates[0]
    require(
        re.search(r"(?:ensure|prepare|create|load).*(?:main|rob)?.*camera", ensure_name, re.I)
        is not None,
        f"The non-presenting camera owner has an unclear lifecycle name: {ensure_name}",
    )
    require(
        f"[self {ensure_name}]" in startup,
        "Cerebro startup no longer ensures the headless main-camera runtime",
    )
    require(
        'instantiateControllerWithIdentifier:@"CameraWindowController"'
        in ensure_runtime
        and (
            "self.cameraWindowController == nil" in ensure_runtime
            or "!self.cameraWindowController" in ensure_runtime
            or (
                "self.cameraWindowController != nil" in ensure_runtime
                and "return;" in ensure_runtime
            )
        )
        and "self.cameraViewController" in ensure_runtime
        and "updateGeminiCameraDemand" in ensure_runtime + startup,
        "Main-camera runtime setup is no longer idempotent or fully wired",
    )
    for forbidden in ("showWindow", "makeKeyAndOrderFront", "orderFront"):
        require(
            forbidden not in ensure_runtime,
            f"Headless main-camera runtime creation presents UI: {forbidden}",
        )

    show_name = next(
        (
            name
            for name, body in methods.items()
            if "cameraWindowController" in body
            and "showWindow" in body
            and name != ensure_name
        ),
        None,
    )
    require(show_name is not None, "Main-camera diagnostics has no presentation method")
    show_main = methods[show_name]
    require(
        f"[self {ensure_name}]" in show_main
        and "[self.cameraWindowController showWindow:" in show_main,
        "Main-camera diagnostics must ensure its runtime before showing the window",
    )
    require(
        "instantiateControllerWithIdentifier" not in show_main,
        "Main-camera diagnostics presentation duplicated runtime construction",
    )

    debug = related_objc_bodies(
        methods,
        ["developmentModeDidChange"],
        r"development|debug|diagnostic",
    )
    require(
        "ROBDevelopmentModeDefaultsKey" in debug,
        "The diagnostics lifecycle no longer reads ROBDevelopmentMode",
    )
    require(
        f"[self {show_name}" in debug and "[self showInsta360Diagnostics:" in debug,
        "Enabling development mode must show both main and Insta360 diagnostics",
    )
    require(
        re.search(
            r"\[self\.cameraWindowController(?:\.window)?\s+(?:close|orderOut:)",
            debug,
        )
        is not None
        and re.search(
            r"\[self\.insta360DiagnosticsWindowController(?:\.window)?\s+(?:close|orderOut:)",
            debug,
        )
        is not None,
        "Disabling development mode must close both camera diagnostics windows",
    )

    debug_helpers = {
        name
        for name in called_self_methods(methods["developmentModeDidChange"])
        if re.search(r"development|debug|diagnostic", name, re.I)
    }
    startup_handles_debug = "ROBDevelopmentModeDefaultsKey" in startup or any(
        f"[self {name}" in startup for name in debug_helpers
    )
    require(
        startup_handles_debug,
        "Startup does not honor an already-enabled ROBDevelopmentMode setting",
    )
    if f"[self {show_name}" in startup:
        require(
            "ROBDevelopmentModeDefaultsKey" in startup,
            "Startup still presents main-camera diagnostics outside development mode",
        )

    # The controller exists headlessly, so automatic local processing must be
    # an explicit capture consumer alongside preview, remote media, and Gemini.
    reconcile = braced_declaration(CAMERA, "private func reconcileCameraSession()")
    should_run = re.search(
        r"let\s+shouldRun\s*=\s*(.*?)(?=\n\s*guard\b)", reconcile, re.S
    )
    require(should_run is not None, "Camera session demand no longer has one shouldRun gate")
    demand_expression = should_run.group(1)
    for token in (
        "cameraViewIsVisible",
        "remoteVideoIsActive",
        "geminiVideoIsActive",
    ):
        require(token in demand_expression, f"Main-camera demand lost consumer: {token}")
    demand_names = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", demand_expression))
    automatic_names = sorted(
        name
        for name in demand_names
        if re.search(r"analysis|automatic|perception|processing", name, re.I)
    )
    require(
        len(automatic_names) == 1,
        f"Main-camera demand needs one explicit local-analysis consumer: {automatic_names}",
    )
    automatic_name = automatic_names[0]
    automatic_demand = swift_bool_property(CAMERA, automatic_name)
    require(
        "ROBMLXRuntime.shared.mainCameraDetectionEnabled" in automatic_demand
        and "ROBDynamicDetectorRegistry.shared" in automatic_demand
        and "processingFramesPerSecond(for: .mainCamera)" in automatic_demand,
        "Local main-camera demand no longer reflects automatic MLX and detector analysis",
    )

    view_did_load = braced_declaration(CAMERA, "override func viewDidLoad()")
    for notification in (
        ".robMLXRuntimeDidChange",
        ".robDetectorSettingsDidChange",
        ".robMainCameraProcessingSettingsDidChange",
    ):
        require(
            notification in view_did_load,
            f"Headless main-camera demand no longer observes {notification}",
        )
    require(
        "manager.setPreviewVisible(false)" in view_did_load,
        "A newly-created hidden main-camera runtime does not disable its preview",
    )
    require(
        "reconcileCameraSession()" in view_did_load,
        "The hidden camera runtime never evaluates its automatic startup demand",
    )
    settings_handler = next(
        (
            braced_from(CAMERA, match.start())
            for match in re.finditer(
                r"(?:@objc\s+)?private\s+func\s+[A-Za-z_][A-Za-z0-9_]*\([^)]*(?:Notification|NSNotification)[^)]*\)\s*\{",
                CAMERA,
            )
            if "reconcileCameraSession()" in braced_from(CAMERA, match.start())
        ),
        "",
    )
    require(
        settings_handler,
        "Automatic-analysis setting changes no longer reconcile main-camera demand",
    )

    # Preview visibility changes display work only. Capture continues for the
    # other demand sources and still fans out to media, Gemini, and perception.
    manager_protocol = braced_declaration(MANAGER, "protocol CameraManagerProtocol")
    require(
        "func setPreviewVisible(_ visible: Bool)" in manager_protocol,
        "CameraManagerProtocol lost independent preview visibility",
    )
    view_did_appear = braced_declaration(CAMERA, "override func viewDidAppear()")
    view_did_disappear = braced_declaration(CAMERA, "override func viewDidDisappear()")
    require(
        "cameraManager?.setPreviewVisible(true)" in view_did_appear,
        "Showing main-camera diagnostics no longer attaches the local preview",
    )
    require(
        "cameraManager?.setPreviewVisible(false)" in view_did_disappear,
        "Hiding main-camera diagnostics no longer detaches the local preview",
    )

    preview_visibility = braced_declaration(
        MANAGER, "func setPreviewVisible(_ visible: Bool)"
    )
    for token in (
        "previewVisible = visible",
        "sessionQueue.async",
        "previewLayer.session = nil",
        "removePreviewLayers",
    ):
        require(token in preview_visibility, f"Preview teardown lost: {token}")
    preview_enqueue = braced_declaration(
        MANAGER, "private func enqueueLatestPreview("
    )
    require(
        "guard previewVisible" in preview_enqueue
        and "previewVisibilityIsCurrent" in preview_enqueue,
        "Hidden DepthAI frames can still enqueue local preview rendering",
    )
    fallback_configuration = braced_declaration(
        MANAGER, "private func configureAVFoundationFallbackOnSessionQueue()"
    )
    require(
        "if currentPreviewVisibility().visible" in fallback_configuration,
        "AVFoundation still creates a hidden preview connection",
    )
    install_av_preview = braced_declaration(
        MANAGER, "private func installAVFoundationPreviewLayer("
    )
    install_depth_preview = braced_declaration(
        MANAGER, "private func installDepthPreviewLayer("
    )
    require(
        "guard preview.visible" in install_av_preview
        and "guard preview.visible" in install_depth_preview,
        "A hidden diagnostics window can still install a camera preview layer",
    )
    remove_preview = braced_declaration(MANAGER, "private func removePreviewLayers(")
    removes_displayed_depth_image = (
        "depthPreviewLayer?.flushAndRemoveImage()" in remove_preview
        or (
            "depthPreviewLayer?.sampleBufferRenderer.flush(" in remove_preview
            and "removingDisplayedImage: true" in remove_preview
        )
    )
    require(
        "previewLayer.removeFromSuperlayer()" in remove_preview
        and removes_displayed_depth_image
        and "depthPreviewLayer?.removeFromSuperlayer()" in remove_preview,
        "Hidden-preview teardown no longer removes both RGB and RGB-D renderers",
    )

    deliver = braced_declaration(MANAGER, "private func deliverLatest(")
    require(
        "videoSampleHandler?(frameSet.rgbSampleBuffer)" in deliver
        and "delegate?.cameraManager(self, didOutput: frameSet)" in deliver,
        "Disabling the local preview also disconnected capture consumers",
    )
    frame_fanout = braced_declaration(
        CAMERA,
        "func cameraManager(_ manager: CameraManagerProtocol, didOutput frameSet: CameraFrameSet)",
    )
    for token in (
        "didCaptureCameraSampleBuffer(sampleBuffer)",
        "ROBMLXRuntime.shared.offerCameraSampleBuffer(sampleBuffer)",
        "ROBDynamicDetectorRegistry.shared.offer(sampleBuffer, source: .mainCamera)",
    ):
        require(token in frame_fanout, f"Headless main-camera frame fan-out lost: {token}")
    require(
        "if cameraViewIsVisible" in frame_fanout
        and "depthOverlayRenderer.offer" in frame_fanout,
        "Depth overlay rendering is no longer gated by diagnostics visibility",
    )

    # Pose/sword/depth preferences belong to the Perception Settings tab, not
    # to the optional camera diagnostic view. The processing facade may remain
    # in this source; only user-facing controls are prohibited here.
    camera_ui_tokens = (
        "pose3DToggle",
        "pose3DFPSPopup",
        "swordTrackerToggle",
        "swordTrackerFPSPopup",
        "depthOpacitySlider",
        "setup3DPoseControls",
        "setupSwordTrackerControls",
        "pose3DSettingChanged",
        "swordTrackerSettingChanged",
        "depthOpacityChanged",
    )
    for token in camera_ui_tokens:
        require(
            token not in CAMERA,
            f"Main-camera diagnostics still owns a Settings control: {token}",
        )
    setup_depth_overlay = braced_declaration(CAMERA, "private func setupDepthOverlay()")
    require(
        "processingSettings.depthOverlayOpacity" in setup_depth_overlay,
        "The diagnostics depth overlay does not consume its Perception Settings value",
    )
    require(
        "self.insta360SettingsTab.label = @\"Perception\"" in SETTINGS_HOST
        and "ROBInsta360ProcessingSettingsViewController" in SETTINGS_HOST,
        "Camera processing controls are no longer hosted by Perception Settings",
    )
    for token in (
        "ROBMainCameraProcessingSettings.shared",
        'checkboxWithTitle: "Render 3D pose"',
        "pose3DFPSPopup",
        'checkboxWithTitle: "Track training sword"',
        "swordTrackerFPSPopup",
        'NSTextField(labelWithString: "Depth overlay opacity:")',
        "depthOpacitySlider",
        'mainCameraBox.title = "Main Camera Processing"',
    ):
        require(
            token in PERCEPTION_SETTINGS,
            f"Perception Settings lost main-camera control: {token}",
        )
    feature_changed = braced_declaration(
        PERCEPTION_SETTINGS, "private func mainCameraFeatureChanged("
    )
    rate_changed = braced_declaration(
        PERCEPTION_SETTINGS, "private func mainCameraRateChanged("
    )
    opacity_changed = braced_declaration(
        PERCEPTION_SETTINGS, "private func depthOverlayOpacityChanged("
    )
    require(
        "mainCameraSettings.pose3DEnabled" in feature_changed
        and "mainCameraSettings.swordTrackerEnabled" in feature_changed,
        "Perception Settings toggles do not persist both main-camera features",
    )
    require(
        "mainCameraSettings.pose3DFramesPerSecond" in rate_changed
        and "mainCameraSettings.swordTrackerFramesPerSecond" in rate_changed,
        "Perception Settings does not persist both main-camera analysis rates",
    )
    require(
        "mainCameraSettings.depthOverlayOpacity" in opacity_changed,
        "Perception Settings does not persist depth-overlay opacity",
    )

    # The process grid reports why a headless camera is running instead of
    # presenting a mysterious active service with no visible consumers.
    status_snapshot = braced_declaration(CAMERA, "struct ROBCameraServiceStatusSnapshot")
    status_fields = [
        name
        for name in re.findall(
            r"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Bool", status_snapshot
        )
        if name.lower().endswith("consumer")
        and any(
            term in name.lower()
            for term in ("automatic", "perception", "analysis", "processing")
        )
    ]
    require(
        len(status_fields) == 1,
        "Main-camera status snapshot lost its perception-demand consumer",
    )
    status_field = status_fields[0]
    service_snapshot = braced_declaration(CAMERA, "func serviceStatusSnapshot()")
    require(
        f"{status_field}: {automatic_name}" in service_snapshot,
        "Main-camera status does not report the effective automatic-analysis demand",
    )
    camera_card = braced_declaration(SYSTEM_STATUS, "private func mainCameraCard(")
    require(
        f"camera.{status_field}" in camera_card
        and re.search(
            rf"camera\.{re.escape(status_field)}\s*\?\s*\"[^\"]*(?:perception|automatic|analysis)",
            camera_card,
            re.I,
        )
        is not None,
        "Services does not identify headless perception as a main-camera consumer",
    )

    print("Main-camera headless static checks passed.")


if __name__ == "__main__":
    main()
