#!/usr/bin/env python3
"""Structural checks for the Apple Music tool's local dispatch boundary."""

import plistlib
import re
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = (ROOT / "Cerebro" / "GeminiRoboticsProtocol.swift").read_text(
    encoding="utf-8"
)
ROB_AI = (ROOT / "Cerebro" / "ROBAI.swift").read_text(encoding="utf-8")
MAIN_CONTROLLER = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)
MESSAGES_RESPONDER = (
    ROOT / "Cerebro" / "ROBMessagesAIResponder.swift"
).read_text(encoding="utf-8")
INFO_PATH = ROOT / "Cerebro" / "Info.plist"
PROJECT = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(
    encoding="utf-8"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def section(source: str, start: str, end: Optional[str] = None) -> str:
    """Return a named source section without depending on line numbers."""
    start_index = source.index(start)
    if end is None:
        return source[start_index:]
    end_index = source.index(end, start_index + len(start))
    return source[start_index:end_index]


def main() -> None:
    service_path = ROOT / "Cerebro" / "ROBAppleMusicService.swift"
    require(service_path.is_file(), "The local Apple Music service source is missing")

    policy = section(
        PROTOCOL,
        "enum GeminiRoboticsToolPolicy",
        "struct GeminiRoboticsServerEvent",
    )
    require(
        "case localAppleMusic" in policy,
        "Apple Music no longer has an explicit local tool-dispatch route",
    )
    require(
        re.search(
            r"ROBAppleMusicService\.toolName.{0,400}\.localAppleMusic"
            r"|\.localAppleMusic.{0,400}ROBAppleMusicService\.toolName",
            policy,
            flags=re.DOTALL,
        )
        is not None,
        "The Apple Music tool name is no longer routed to local Apple Music execution",
    )

    tool_dispatch = section(
        ROB_AI,
        "case .toolCalls(let calls):",
        "case .cancelledToolCalls(let callIDs):",
    )
    music_route_index = tool_dispatch.find("case .localAppleMusic:")
    robot_bridge_index = tool_dispatch.find("ROBAIRobotToolCall(")
    require(
        music_route_index >= 0
        and robot_bridge_index >= 0
        and music_route_index < robot_bridge_index,
        "Apple Music is not intercepted before Objective-C robot-action bridging",
    )
    require(
        "configuration?.enablesAppleMusic == true" in tool_dispatch,
        "Disabled Apple Music access could still execute",
    )
    require(
        "handleLocalAppleMusicToolCall(call)" in tool_dispatch,
        "Apple Music calls are not executed by their local service handler",
    )

    music_handler_start = ROB_AI.index("private func handleLocalAppleMusicToolCall")
    next_handler_start = ROB_AI.find("\n    private func ", music_handler_start + 1)
    require(next_handler_start >= 0, "Could not isolate the Apple Music tool handler")
    music_handler = ROB_AI[music_handler_start:next_handler_start]
    require(
        "session?.sendToolResponse(" in music_handler
        and "callID: call.id" in music_handler
        and "name: call.name" in music_handler
        and "result:" in music_handler,
        "Apple Music results are not correlated back to the originating Gemini call",
    )

    cancellation_start = ROB_AI.index(
        "case .cancelledToolCalls(let callIDs):", music_route_index
    )
    cancellation_end = ROB_AI.find("\n    private func ", cancellation_start)
    require(cancellation_end >= 0, "Could not isolate local tool cancellation handling")
    cancellation_handler = ROB_AI[cancellation_start:cancellation_end]
    tracked_task_names = {
        match.group(0)
        for match in re.finditer(
            r"\b[A-Za-z_][A-Za-z0-9_]*appleMusic[A-Za-z0-9_]*task[A-Za-z0-9_]*\b",
            ROB_AI,
            flags=re.IGNORECASE,
        )
    }
    shared_task_names = {
        name
        for name in tracked_task_names
        if name in music_handler and name in cancellation_handler
    }
    task_registry = section(
        ROB_AI,
        "private final class ROBAppleMusicToolTaskRegistry",
        "@objc public protocol ROBAIDelegate",
    )
    require(
        bool(shared_task_names)
        and "call.id" in music_handler
        and any(
            f"{name}.cancel(callIDs: callIDs)" in cancellation_handler
            for name in shared_task_names
        )
        and "func cancel(callIDs: [String])" in task_registry
        and "for callID in callIDs" in task_registry
        and "entries[callID]" in task_registry
        and "task?.cancel()" in task_registry,
        "Cancelled Gemini call IDs no longer cancel their tracked Apple Music tasks",
    )

    controller_handler = section(
        MAIN_CONTROLLER,
        "didReceiveToolCall:(ROBAIRobotToolCall *)call",
        "didCancelToolCallIDs:(NSArray<NSString *> *)callIDs",
    )
    require(
        'if (![call.name isEqualToString:@"robot_action"])' in controller_handler,
        "The Objective-C permission boundary no longer rejects non-robot tools",
    )
    require(
        "apple_music" not in controller_handler.lower(),
        "Apple Music was coupled to the Objective-C robot-action permission handler",
    )

    messages_profile = section(
        MESSAGES_RESPONDER,
        "configuration = GeminiRoboticsConfiguration(",
        "isolatedDefaults = UserDefaults(",
    )
    require(
        "enablesAppleMusic: false" in messages_profile,
        "The isolated Messages AI profile can expose Apple Music automation",
    )

    with INFO_PATH.open("rb") as info_file:
        info = plistlib.load(info_file)
    apple_events_purpose = info.get("NSAppleEventsUsageDescription", "")
    require(
        re.search(r"\bMessages\b", apple_events_purpose, flags=re.IGNORECASE)
        is not None
        and re.search(r"\bMusic\b", apple_events_purpose, flags=re.IGNORECASE)
        is not None,
        "The Apple Events purpose string must explain both Messages and Music automation",
    )
    require(
        info.get("NSAppleMusicUsageDescription", "") != "",
        "Cerebro must include an NSAppleMusicUsageDescription for Music control",
    )

    filename = service_path.name
    require(
        PROJECT.count(f"/* {filename} */") >= 2
        and f"/* {filename} in Sources */" in PROJECT,
        f"{filename} is not part of the Cerebro application target",
    )

    print("ROB Apple Music tool dispatch static checks passed")


if __name__ == "__main__":
    main()
