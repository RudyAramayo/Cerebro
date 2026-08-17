#!/usr/bin/env python3
"""Structural checks for the news-tool/robot-permission boundary."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROB_AI = (ROOT / "Cerebro" / "ROBAI.swift").read_text(encoding="utf-8")
MAIN_CONTROLLER = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


tool_start = ROB_AI.index("case .toolCalls(let calls):")
tool_end = ROB_AI.index("case .cancelledToolCalls", tool_start)
tool_dispatch = ROB_AI[tool_start:tool_end]

require(
    "GeminiRoboticsToolPolicy.dispatchRoute(for: call)" in tool_dispatch,
    "Tool calls are no longer routed through the explicit policy",
)
require(
    tool_dispatch.index("case .localNews:")
    < tool_dispatch.index("ROBAIRobotToolCall("),
    "News is not intercepted before Objective-C robot-action bridging",
)
require(
    "configuration?.enablesNewsSearch == true" in tool_dispatch,
    "Disabled news search could still execute",
)
require(
    "handleLocalNewsToolCall(call)" in tool_dispatch,
    "News calls are not executed by the local read-only service",
)

local_handler_start = ROB_AI.index("private func handleLocalNewsToolCall")
local_handler_end = ROB_AI.index("private func notifyConnectionState", local_handler_start)
local_handler = ROB_AI[local_handler_start:local_handler_end]
require(
    "service.execute(arguments: call.arguments)" in local_handler
    and "session?.sendToolResponse(" in local_handler,
    "News results are not correlated back to the Gemini tool call",
)

cancel_start = ROB_AI.index("private func handleToolCallCancellations")
cancel_end = ROB_AI.index("private func dispatchNextToolCallIfPossible", cancel_start)
cancel_handler = ROB_AI[cancel_start:cancel_end]
require(
    'if name == "robot_action"' in cancel_handler
    and "activeToolCallID = nil" in cancel_handler,
    "Read-only cancellation no longer releases without robot confirmation",
)

controller_start = MAIN_CONTROLLER.index(
    "didReceiveToolCall:(ROBAIRobotToolCall *)call"
)
controller_end = MAIN_CONTROLLER.index(
    "didCancelToolCallIDs:(NSArray<NSString *> *)callIDs", controller_start
)
controller_handler = MAIN_CONTROLLER[controller_start:controller_end]
require(
    'if (![call.name isEqualToString:@"robot_action"])' in controller_handler,
    "The Objective-C permission boundary no longer rejects non-robot tools",
)
require(
    "search_news" not in controller_handler,
    "News was coupled to the ROBController permission handler",
)

print("ROB news tool dispatch static checks passed")
