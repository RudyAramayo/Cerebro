#!/usr/bin/env python3
"""Static regression checks for the cached system-health card grid."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
COORDINATOR = (ROOT / "Cerebro" / "ROBSystemStatusCoordinator.swift").read_text(
    encoding="utf-8"
)
STATUS_WINDOW = (
    ROOT / "Cerebro" / "ROBSystemStatusWindowController.swift"
).read_text(encoding="utf-8")
AUTO_NET = (
    ROOT / "Cerebro" / "AutoNet" / "AutoNetServer" / "AutoNetServer.swift"
).read_text(encoding="utf-8")
AUTO_NET_CONNECTION = (
    ROOT
    / "Cerebro"
    / "AutoNet"
    / "AutoNetServer"
    / "AutoNetServerConnection.swift"
).read_text(encoding="utf-8")
VIDEO_SERVER = (ROOT / "Cerebro" / "ROBVideoServer.swift").read_text(
    encoding="utf-8"
)
CAMERA = (ROOT / "Cerebro" / "CameraViewController.swift").read_text(
    encoding="utf-8"
)
INSTA360 = (ROOT / "Cerebro" / "ROBInsta360CameraService.swift").read_text(
    encoding="utf-8"
)
MAIN_CONTROLLER = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)
MAIN_WINDOW = (ROOT / "Cerebro" / "ROBMainWindowController.m").read_text(
    encoding="utf-8"
)
APP_DELEGATE = (ROOT / "Cerebro" / "AppDelegate.m").read_text(encoding="utf-8")


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


def assert_observational(name: str, declaration: str) -> None:
    forbidden_calls = (
        r"(?<![A-Za-z])start\s*\(",
        r"(?<![A-Za-z])restart\s*\(",
        r"checkHealth\s*\(",
        r"requestAccess\s*\(",
        r"prepareVisionModel\s*\(",
        r"ensure(?:LLM|VLM)Ready\s*\(",
        r"(?:Gemini|Insta360)DiagnosticsWindowController\s*\(",
    )
    for pattern in forbidden_calls:
        require(
            re.search(pattern, declaration) is None,
            f"{name} performs a prohibited health-panel side effect: {pattern}",
        )


def main() -> None:
    # Main-window actions are consolidated in the content header. The brain is
    # the graphical Services control, Show Mode has a stage symbol, and the old
    # titlebar copies of 360° and Settings stay removed.
    main_implementation = MAIN_CONTROLLER[
        MAIN_CONTROLLER.index("@implementation ROBMainViewController") :
    ]
    configure_workspace = braced_declaration(
        main_implementation, "- (void)configureMainWorkspace"
    )
    require(
        "NSTitlebarAccessoryViewController" not in MAIN_WINDOW
        and 'buttonWithTitle:@"360°…"' not in MAIN_WINDOW
        and 'buttonWithTitle:@"Settings…"' not in MAIN_WINDOW,
        "The cleared titlebar regained duplicate workspace actions",
    )
    require(
        'symbolName:@"brain.head.profile"' in configure_workspace
        and "action:@selector(showSystemStatus:)" in configure_workspace
        and 'setAccessibilityLabel:@"System Services"' in configure_workspace,
        "The graphical brain no longer opens the accessible Services panel",
    )
    require(
        'initWithTitle:@"Show Mode"' in configure_workspace
        and 'symbolName:@"theatermasks.fill"' in configure_workspace
        and "action:@selector(showStageShow:)" in configure_workspace,
        "The main workspace lost its graphical Show Mode action",
    )
    require(
        configure_workspace.count('initWithTitle:@"360° Live View"') == 1
        and configure_workspace.count('initWithTitle:@"Settings"') == 1,
        "The content header no longer has exactly one 360° and one Settings action",
    )
    update_settings = braced_declaration(
        main_implementation, "- (void)updateWorkspaceSettingsButton"
    )
    require(
        "ROBPythonRuntime sharedRuntime" in update_settings
        and "ROBSystemDependencyManager sharedManager" in update_settings
        and 'Settings  ⚠' in update_settings,
        "Consolidating Settings discarded its dependency-attention indicator",
    )
    show_window = braced_declaration(STATUS_WINDOW, "public override func showWindow")
    require(
        "if window == nil" in show_window and "loadWindow()" in show_window,
        "The programmatic Services panel must create its window before presenting it",
    )
    require(
        "if !isWindowLoaded" not in show_window,
        "The Services panel cannot trust isWindowLoaded after init(window: nil)",
    )
    require(
        show_window.index("loadWindow()") < show_window.index("super.showWindow(sender)"),
        "The Services panel must load its window before calling NSWindowController.showWindow",
    )
    app_show_status = braced_declaration(APP_DELEGATE, "- (IBAction)showSystemStatus:")
    require(
        "for (NSWindow *window in NSApp.windows)" in app_show_status
        and "[self mainViewControllerInViewController:window.contentViewController]"
        in app_show_status
        and "[mainViewController showSystemStatus:sender]" in app_show_status,
        "AppDelegate no longer resolves and opens Services through the live view hierarchy",
    )

    snapshot = braced_declaration(COORDINATOR, "private func snapshot()")
    expected_cards = (
        ("private func geminiCard(", "gemini-live", "Gemini Live"),
        (
            "private func appleFoundationModelsCard()",
            "apple-foundation-models",
            "Apple Foundation Models",
        ),
        ("private func mlxCard()", "mlx-local-models", "MLX Local Models"),
        (
            "private func localStageModelCard()",
            "stage-local-llm",
            "Stage Local LLM",
        ),
        (
            "private func messagesBridgeCard(",
            "messages-ai-bridge",
            "Messages AI Bridge",
        ),
        ("private func mainCameraCard(", "main-camera", "Main Camera Feed"),
        ("private func insta360Card(", "insta360", "Insta360 360° Feed"),
        (
            "private func mediaCard(",
            "controller-media",
            "Vision Pro / Controller Media",
        ),
        (
            "private func controllerListenerCard(",
            "robcontroller-listener",
            "ROBController Listener",
        ),
    )

    # Each builder may have several availability branches, but every branch
    # must retain exactly the same stable ID/name pair.
    builder_bodies: list[str] = []
    for signature, expected_id, expected_name in expected_cards:
        builder = braced_declaration(COORDINATOR, signature)
        builder_bodies.append(builder)
        ids = set(re.findall(r'id:\s*"([^"]+)"', builder))
        names = set(re.findall(r'displayName:\s*"([^"]+)"', builder))
        require(
            ids == {expected_id},
            f"Fixed service builder {signature} changed stable ID: {ids}",
        )
        require(
            names == {expected_name},
            f"Fixed service builder {signature} changed display name: {names}",
        )

    fixed_builder_calls = (
        "geminiCard(now: now)",
        "appleFoundationModelsCard()",
        "mlxCard()",
        "localStageModelCard()",
        "messagesBridgeCard(now: now)",
        "mainCameraCard(camera, now: now)",
        "insta360Card(now: now)",
        "mediaCard(media, startupError: camera?.videoServerStartupError)",
        "controllerListenerCard(control)",
    )
    for call in fixed_builder_calls:
        require(
            snapshot.count(call) == 1,
            f"System snapshot must contain one fixed card call: {call}",
        )
    fixed_array_match = re.search(
        r"(?:let|var) services: \[ROBSystemServiceCardSnapshot\] = \[", snapshot
    )
    require(fixed_array_match is not None, "System snapshot lost its fixed service array")
    fixed_array_start = fixed_array_match.start()
    fixed_array_end = snapshot.index("\n        ]", fixed_array_start)
    fixed_array = snapshot[fixed_array_start:fixed_array_end]
    require(
        len(re.findall(r"\b[a-z][A-Za-z0-9]*Card\(", fixed_array))
        == len(expected_cards),
        "System snapshot fixed-card inventory changed without updating its contract",
    )

    # The coordinator reads real cached runtime sources. MLX refreshes its
    # diagnostics cache asynchronously; no model preparation is triggered.
    for token in (
        "cameraViewController?.serviceStatusSnapshot()",
        "autoNetServer?.statusSnapshot()",
        "let media = camera?.videoServer",
        "robAI.diagnosticsSnapshot()",
        "stageShowCoordinator?.localImprovisationDiagnosticsSnapshot()",
        "ROBInsta360CameraService.shared",
        "service.statusSnapshot()",
        "ROBSceneSnapshotStore.shared.snapshot()",
        "ROBMessagesBridge.shared.statusSnapshot()",
    ):
        require(
            token in snapshot + "\n" + "\n".join(builder_bodies),
            f"Health grid lost its cached production source: {token}",
        )
    mlx_refresh = braced_declaration(COORDINATOR, "private func refreshMLXCache()")
    require(
        "await ROBMLXEngine.shared.diagnostics()" in mlx_refresh
        and "latestMLXDiagnostics = diagnostics" in mlx_refresh,
        "MLX health no longer refreshes from its diagnostics snapshot",
    )

    # A control connection always maps to one dynamic card; zero connections
    # render an explicit empty state, while one or many use the same stable-ID
    # map and deterministic name/ID ordering.
    require(
        "let controllers = control?.connections.map { connection in" in snapshot
        and "controllerCard(connection, media: media)" in snapshot,
        "Typed ROBController connections no longer map one-for-one to cards",
    )
    require(
        "} ?? []" in snapshot,
        "A missing controller owner must produce an empty dynamic-card collection",
    )
    control_snapshot = braced_declaration(AUTO_NET, "@nonobjc func statusSnapshot()")
    for token in (
        "connectionsByID.values.map { connection in",
        'stableID: "robcontrol-\\(connection.id)"',
        "role: connection.authenticatedRole?.rawValue",
        "deviceID: connection.authenticatedDeviceID?.uuidString.lowercased()",
        "deviceName: connection.authenticatedDeviceName",
        "sessionID: connection.authenticatedSessionUUID?.uuidString.lowercased()",
        "let lhsName = $0.deviceName ?? $0.deviceID ?? $0.stableID",
        "let rhsName = $1.deviceName ?? $1.deviceID ?? $1.stableID",
        "if order == .orderedSame { return $0.stableID < $1.stableID }",
    ):
        require(token in control_snapshot, f"Controller status mapping/sort lost: {token}")

    # Each authenticated session reports a passive rolling traffic meter and
    # an opt-in, low-rate echo test. Reserved probe traffic is consumed before
    # command dispatch and never reaches or relays through the legacy parser.
    for token in (
        'Data("ROBNET-PROBE-CAP-V1".utf8)',
        'Data("ROBNET-PROBE-V1:".utf8)',
        "receivedApplicationBytes",
        "sentApplicationBytes",
        "receivedMessagesPerSecond",
        "roundTripMilliseconds",
        "consecutiveProbeMisses",
        "scheduleNextNetworkProbe(after: 0.25)",
    ):
        require(token in AUTO_NET_CONNECTION, f"Controller network telemetry lost: {token}")
    receive_application = braced_declaration(AUTO_NET, "func receiveApplicationMessage(")
    require(
        "sendingConnection.consumeNetworkProbeMessage(data)" in receive_application
        and receive_application.index("sendingConnection.consumeNetworkProbeMessage(data)")
        < receive_application.index("dataDelegate?.didReceiveData(data)"),
        "Reserved network probes can leak into command dispatch",
    )
    for token in (
        "network: connection.networkStatusSnapshot()",
        'label: "RX"',
        'label: "TX"',
        'label: "Round trip"',
        'label: "Traffic total"',
    ):
        require(
            token in control_snapshot + "\n" + COORDINATOR,
            f"Services lost controller network metric: {token}",
        )

    rebuild = braced_declaration(STATUS_WINDOW, "private func rebuildCards(")
    require(
        "if controllers.isEmpty" in rebuild
        and "ROBSystemStatusEmptyControllersView()" in rebuild
        and 'addSection(title: "Controllers", count: cards.count, cards: cards)'
        in rebuild
        and 'cardViews["controller:\\(controller.stableID)"] = card' in rebuild,
        "Controller grid no longer handles zero/one/many dynamic sessions",
    )
    require(
        "ROBSystemStatusRowListView(rows: cards)" in STATUS_WINDOW
        and "private final class ROBSystemStatusRowListView" in STATUS_WINDOW
        and "private static let cardHeight" not in STATUS_WINDOW
        and "@objc private func toggleExpanded" in STATUS_WINDOW
        and "summaryLabel.stringValue = metrics.prefix(3)" in STATUS_WINDOW,
        "Services no longer uses compact full-width expandable rows",
    )
    require(
        'labelWithString: "No active controller connections"' in STATUS_WINDOW,
        "Zero-controller state no longer explicitly says there are no active controllers",
    )
    sorted_controllers = braced_declaration(
        STATUS_WINDOW, "private func sortedControllers("
    )
    require(
        "$0.displayName.localizedCaseInsensitiveCompare($1.displayName)"
        in sorted_controllers
        and "$0.stableID.localizedCaseInsensitiveCompare($1.stableID)"
        in sorted_controllers,
        "Dynamic controller cards are no longer deterministically sorted by name then ID",
    )

    # Media is attached only when both authenticated controller and session IDs
    # match. A controller-only match could conflate reconnects or devices.
    controller_card = braced_declaration(COORDINATOR, "private func controllerCard(")
    require(
        re.search(
            r"\$0\.controllerID\s*==\s*connection\.deviceID\s*&&\s*"
            r"\$0\.sessionID\s*==\s*connection\.sessionID",
            controller_card,
        )
        is not None,
        "Controller media must correlate on the exact controller+session pair",
    )
    require(
        "exactMedia.profile" in controller_card
        and "Control and media sessions are both active." in controller_card,
        "Exact media correlation is no longer reflected on its controller card",
    )
    video_publish = braced_declaration(VIDEO_SERVER, "private func publishStatus()")
    for token in (
        "connection.authenticatedControllerID",
        "readySubscriptionIDs.contains(stream.id)",
        "controllerID: controllerID.uuidString.lowercased()",
        "sessionID: stream.sessionID.uuidString.lowercased()",
        "}.sorted { $0.stableID < $1.stableID }",
    ):
        require(token in video_publish, f"Typed media subscription snapshot lost: {token}")

    # Refresh is live while the panel is visible, but every refresh only pulls
    # the cached provider and rebuilds keyed cards when the structure changes.
    start_timer = braced_declaration(STATUS_WINDOW, "private func startRefreshTimer()")
    timer_fired = braced_declaration(
        STATUS_WINDOW, "@objc private func refreshTimerFired("
    )
    refresh = braced_declaration(
        STATUS_WINDOW, "private func refreshFromCachedState()"
    )
    require(
        "timeInterval: 1.0" in start_timer
        and "repeats: true" in start_timer
        and "RunLoop.main.add(timer, forMode: .common)" in start_timer
        and "refreshFromCachedState()" in timer_fired,
        "The status grid no longer refreshes live from cached state",
    )
    require(
        "let snapshot = snapshotProvider()" in refresh
        and "sortedServices(snapshot.services)" in refresh
        and "sortedControllers(snapshot.controllers)" in refresh
        and 'cardViews["service:\\(service.id)"]?.update' in refresh
        and 'cardViews["controller:\\(controller.stableID)"]?.update' in refresh,
        "Live refresh no longer updates stable service/controller cards",
    )

    # The top-level panel receives the real runtime owners. It never constructs
    # either debug/diagnostics window as a source of status.
    show_status = braced_declaration(MAIN_CONTROLLER, "- (IBAction)showSystemStatus:")
    require(
        "NSBeep()" not in show_status and "return;" not in show_status,
        "The Services action must present its panel even when a runtime owner is unavailable",
    )
    for token in (
        "initWithRobAI:self.robAI",
        "cameraViewController:self.cameraViewController",
        "autoNetServer:self.autoNetServer",
        "stageShowCoordinator:self.stageShowCoordinator",
    ):
        require(token in show_status, f"System status lost live owner injection: {token}")

    coordinator_init = braced_declaration(COORDINATOR, "init(\n")
    for optional_owner in (
        "robAI: ROBAI?",
        "cameraViewController: CameraViewController?",
        "autoNetServer: AutoNetServer?",
        "stageShowCoordinator: ROBStageShowCoordinator?",
    ):
        require(
            optional_owner in coordinator_init,
            f"Services presentation can still be blocked by a missing owner: {optional_owner}",
        )

    gemini_card = braced_declaration(COORDINATOR, "private func geminiCard(")
    require(
        "guard let robAI else" in gemini_card
        and "state: .unavailable" in gemini_card
        and "Gemini runtime owner has not been created" in gemini_card,
        "A missing Gemini owner must render an explicit unavailable service card",
    )
    messages_card = braced_declaration(
        COORDINATOR, "private func messagesBridgeCard("
    )
    for count in (
        "snapshot.allowedSenderCount",
        "snapshot.pendingReplyCount",
        "snapshot.activeAIChatCount",
    ):
        require(count in messages_card, f"Messages status lost safe count: {count}")
    require(
        "snapshot.configuredAccount" not in messages_card
        and "snapshot.detail" not in messages_card,
        "Messages status must not expose account handles or provider/message error payloads",
    )
    require(
        "snapshot.lastDeliveryError" in messages_card
        and 'label: "Last delivery error"' in messages_card,
        "Messages status must expose a bounded delivery-stage diagnostic",
    )
    for state in (
        'normalized == "disabled"',
        'normalized.contains("configuration required")',
        'normalized.contains("full disk access")',
        'normalized == "listening"',
        'normalized == "processing"',
        'normalized.contains("rate limited")',
        'normalized.contains("automation permission")',
        'normalized.contains("error")',
    ):
        require(state in messages_card, f"Messages health mapping lost state: {state}")
    controller_listener_card = braced_declaration(
        COORDINATOR, "private func controllerListenerCard("
    )
    require(
        "guard let control else" in controller_listener_card
        and "state: .unavailable" in controller_listener_card
        and "controller listener has not been created" in controller_listener_card,
        "A missing controller owner must render an explicit unavailable service card",
    )
    require(
        "DiagnosticsWindowController" not in show_status
        and "ROBGeminiDiagnosticsWindowController" not in COORDINATOR
        and "ROBInsta360DiagnosticsWindowController" not in COORDINATOR,
        "System health must not construct or depend on diagnostics windows",
    )

    camera_snapshot = braced_declaration(CAMERA, "@nonobjc func serviceStatusSnapshot()")
    insta_snapshot = braced_declaration(INSTA360, "@nonobjc func statusSnapshot()")
    video_snapshot = braced_declaration(VIDEO_SERVER, "func statusSnapshot()")
    require(
        "videoServer: videoServer?.statusSnapshot()" in camera_snapshot,
        "Main-camera status no longer embeds the cached controller-media snapshot",
    )
    require(
        "return cachedStatus" in video_snapshot
        and "statusLock.lock()" in video_snapshot,
        "Video status accessor no longer returns its lock-protected cached snapshot",
    )

    observational_declarations = [
        ("coordinator snapshot", snapshot),
        ("MLX cache refresh", mlx_refresh),
        ("controller statusSnapshot", control_snapshot),
        ("camera serviceStatusSnapshot", camera_snapshot),
        ("Insta360 statusSnapshot", insta_snapshot),
        ("video statusSnapshot", video_snapshot),
        ("status-window cached refresh", refresh),
    ] + [
        (f"fixed service builder {signature}", body)
        for (signature, _, _), body in zip(expected_cards, builder_bodies)
    ]
    for name, declaration in observational_declarations:
        assert_observational(name, declaration)

    print("System health grid cached-source and dynamic-card static checks passed")


if __name__ == "__main__":
    main()
