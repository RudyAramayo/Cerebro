#!/usr/bin/env python3
"""Static regression checks for the Maestro neck-safety command boundary."""

from collections import Counter
from pathlib import Path
import re
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
POLICY_HEADER_PATH = ROOT / "Cerebro" / "ROBNeckSafetyPolicy.h"
POLICY_SOURCE_PATH = ROOT / "Cerebro" / "ROBNeckSafetyPolicy.c"
SERIAL_HEADER_PATH = ROOT / "Cerebro" / "ROBSerialBox.h"
SERIAL_SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"
TORSO_SOURCE_PATH = ROOT / "Cerebro" / "ROBTorsoControlsViewController.m"
PROJECT_PATH = ROOT / "Cerebro.xcodeproj" / "project.pbxproj"
STORYBOARD_PATH = ROOT / "Cerebro" / "Base.lproj" / "Main.storyboard"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def mask_c_comments_and_literals(source: str) -> str:
    """Mask comments and quoted literals while preserving offsets and newlines."""
    masked = list(source)
    index = 0
    state = "code"
    quote = ""
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if character == "/" and following == "/":
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "line_comment"
                continue
            if character == "/" and following == "*":
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "block_comment"
                continue
            if character in ('"', "'"):
                quote = character
                masked[index] = " "
                index += 1
                state = "literal"
                continue
            index += 1
            continue

        if state == "line_comment":
            if character == "\n":
                state = "code"
            else:
                masked[index] = " "
            index += 1
            continue

        if state == "block_comment":
            if character == "*" and following == "/":
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "code"
                continue
            if character != "\n":
                masked[index] = " "
            index += 1
            continue

        # Quoted C/Objective-C string or character literal.
        if character == "\\" and following:
            masked[index] = " "
            if following != "\n":
                masked[index + 1] = " "
            index += 2
            continue
        if character == quote:
            masked[index] = " "
            index += 1
            state = "code"
            continue
        if character != "\n":
            masked[index] = " "
        index += 1

    return "".join(masked)


def objective_c_method_span(source: str, selector: str) -> tuple[int, int]:
    """Return the implementation span for an Objective-C selector."""
    masked = mask_c_comments_and_literals(source)
    declaration = re.compile(
        rf"(?m)^[ \t]*[-+]\s*\([^\n)]+\)\s*{re.escape(selector)}"
    )
    for match in declaration.finditer(masked):
        body_start = masked.find("{", match.end())
        semicolon = masked.find(";", match.end())
        if body_start < 0 or (semicolon >= 0 and semicolon < body_start):
            continue

        depth = 0
        for index in range(body_start, len(masked)):
            character = masked[index]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return match.start(), index + 1
        raise AssertionError(f"Unterminated Objective-C method: {selector}")
    raise AssertionError(f"Objective-C method implementation not found: {selector}")


def objective_c_method(source: str, selector: str) -> str:
    start, end = objective_c_method_span(source, selector)
    return source[start:end]


def braced_declaration(source: str, signature: str) -> str:
    """Return a C-family declaration with its complete balanced body."""
    masked = mask_c_comments_and_literals(source)
    declaration_start = masked.index(signature)
    body_start = masked.index("{", declaration_start + len(signature))
    depth = 0
    for index in range(body_start, len(masked)):
        character = masked[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[declaration_start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


def maestro_send_calls(source: str) -> list[tuple[int, Optional[int], str]]:
    """Return balanced `[self sendMaestroTarget:... channel:...]` messages."""
    masked = mask_c_comments_and_literals(source)
    start_pattern = re.compile(r"\[\s*self\s+sendMaestroTarget\s*:")
    calls: list[tuple[int, Optional[int], str]] = []
    for match in start_pattern.finditer(masked):
        depth = 0
        message_end = None
        for index in range(match.start(), len(masked)):
            character = masked[index]
            if character == "[":
                depth += 1
            elif character == "]":
                depth -= 1
                if depth == 0:
                    message_end = index + 1
                    break
        require(message_end is not None, "Unterminated sendMaestroTarget message")
        message = masked[match.start() : message_end]
        channel_match = re.search(r"\bchannel\s*:\s*(\d+)\b", message)
        channel = int(channel_match.group(1)) if channel_match else None
        calls.append((match.start(), channel, source[match.start() : message_end]))
    return calls


def coupled_neck_send_positions(source: str) -> list[int]:
    """Return calls to the fixed channel-1/2 multiple-target helper."""
    masked = mask_c_comments_and_literals(source)
    return [
        match.start()
        for match in re.finditer(
            r"\[\s*self\s+sendMaestroLowerTarget\s*:", masked
        )
    ]


def compact(source: str) -> str:
    return re.sub(r"\s+", " ", source).strip()


def check_pure_c_policy_and_project() -> None:
    require(POLICY_HEADER_PATH.is_file(), "Missing ROBNeckSafetyPolicy.h")
    require(POLICY_SOURCE_PATH.is_file(), "Missing ROBNeckSafetyPolicy.c")
    policy_header = POLICY_HEADER_PATH.read_text(encoding="utf-8")
    policy_source = POLICY_SOURCE_PATH.read_text(encoding="utf-8")
    project = PROJECT_PATH.read_text(encoding="utf-8")

    require(
        '#include <stdbool.h>' in policy_header
        and '#include <stdint.h>' in policy_header,
        "The neck policy header lost its dependency-light C types",
    )
    require(
        'extern "C"' in policy_header,
        "The C neck policy is no longer safe to include from C++/Objective-C++",
    )
    for forbidden in (
        "#import",
        "Foundation",
        "AppKit",
        "Cocoa",
        "NSObject",
        "NSString",
        "NSView",
    ):
        require(
            forbidden not in policy_header and forbidden not in policy_source,
            f"The pure C neck policy gained a framework dependency: {forbidden}",
        )

    require(
        re.search(
            r"PBXFileReference;[^\n]*sourcecode\.c\.h;[^\n]*path = ROBNeckSafetyPolicy\.h;",
            project,
        )
        is not None,
        "The Xcode project lost the neck-policy header reference",
    )
    require(
        re.search(
            r"PBXFileReference;[^\n]*sourcecode\.c\.c;[^\n]*path = ROBNeckSafetyPolicy\.c;",
            project,
        )
        is not None,
        "The Xcode project no longer treats the neck policy as C source",
    )
    require(
        project.count("ROBNeckSafetyPolicy.c in Sources") >= 2,
        "The neck policy is not present in the app target's Sources phase",
    )


def check_lower_clearance_threshold(
    policy_header: str,
    policy_source: str,
    serial_source: str,
    torso_source: str,
    storyboard: str,
) -> None:
    require(
        re.search(
            r"ROBNeckSafetyFullPanLowerThresholdTarget\s*=\s*5000\b",
            policy_header,
        )
        is not None,
        "The Maestro 24 full-pan lower-neck threshold is no longer exactly 5000",
    )
    require(
        re.search(
            r"ROBNeckSafetyFullPanLowerMaximumTarget\s*=\s*6495\b",
            policy_header,
        )
        is not None,
        "The Maestro 24 full-pan lower-neck maximum is no longer exactly 6495",
    )
    require(
        re.search(r"ROBNeckSafetyUprightLowerTarget\s*=\s*6011\b", policy_header)
            is not None
        and re.search(r"ROBNeckSafetyUprightUpperTarget\s*=\s*6073\b", policy_header)
            is not None,
        "The calibrated lower/upper upright targets must remain 6011/6073",
    )
    require(
        re.search(
            r"ROBNeckSafetyDefaultForwardPanTarget\s*=\s*5799\b",
            policy_header,
        )
        is not None
        and re.search(
            r"ROBNeckSafetyDefaultLowerTarget\s*=\s*7014\b", policy_header
        )
        is not None
        and re.search(
            r"ROBNeckSafetyDefaultUpperTarget\s*=\s*"
            r"ROBNeckSafetyUprightUpperTarget\b",
            policy_header,
        ) is not None,
        "The calibrated forward/resting startup defaults must remain "
        "5799/7014/6073",
    )
    bounds = compact(braced_declaration(
        policy_source, "bool ROBNeckSafetyAllowedPanBounds("
    ))
    clearance = compact(braced_declaration(
        policy_source, "bool ROBNeckSafetyLowerTargetHasFullPanClearance("
    ))
    require(
        "boundedLowerTarget = ROBNeckSafetyClampTarget(" in clearance
        and "boundedLowerTarget >= "
            "ROBNeckSafetyFullPanLowerThresholdTarget" in clearance
        and "boundedLowerTarget <= "
            "ROBNeckSafetyFullPanLowerMaximumTarget" in clearance
        and "boundedLowerTarget < "
            "ROBNeckSafetyFullPanLowerThresholdTarget" in bounds
        and "!ROBNeckSafetyLowerTargetHasFullPanClearance(" in bounds
        and "minimumDegrees = -config->restrictedPanDegrees;" in bounds
        and "maximumDegrees = config->restrictedPanDegrees;" in bounds
        and "minimumDegrees = config->forwardPanMinimumDegrees;" in bounds
        and "maximumDegrees = config->forwardPanMaximumDegrees;" in bounds
        and "minimumDegrees = -full;" in bounds
        and "maximumDegrees = full;" in bounds
        and "lowerForwardRestrictedTarget" not in bounds,
        "Known lower-neck pan bounds no longer use symmetric restriction below "
        "5000, full pan from 5000 through 6495, and the asymmetric envelope above",
    )
    follow = compact(objective_c_method(serial_source, "prepareNeckForPersonFollow"))
    require(
        follow.count("ROBNeckSafetyLowerTargetHasFullPanClearance(") == 2
        and "ROBNeckSafetyFullPanLowerThresholdTarget" not in follow
        and "lowerFullPanHighTarget" not in follow
        and "neckSafetyCalibrationConfirmed" not in follow.split(
            "ROBNeckSafetyConfig configuration", 1
        )[0]
        and "kROBFollowTrackingClearanceSource" in follow
        and "ROBNeckSafetyUprightUpperTarget" in follow
        and "fullPanEnvelopeIsSettled" in follow
        and "pendingPanEnvelopeLowerTarget == ROBNeckSafetyTargetOff" in follow,
        "Person-follow pose preparation no longer uses the complete fixed "
        "5000-through-6495 clearance predicate and waits for its envelope",
    )
    gateway = objective_c_method(serial_source, "applySafeNeckPanTarget:")
    compact_gateway = compact(gateway)
    require(
        "reviewedFollowClearanceCommand" in gateway
        and "&& !reviewedFollowClearanceCommand" in compact_gateway
        and "panTarget == configuration.panCenterTarget" in gateway
        and "lowerTiltTarget == ROBNeckSafetyUprightLowerTarget" in gateway
        and "desiredUpperTarget == ROBNeckSafetyUprightUpperTarget" in gateway,
        "Unconfirmed tracking clearance must be limited to the reviewed "
        "center/6011/6073 tuple",
    )
    require(
        "lastVisionNeckTiltTarget = ROBNeckSafetyUprightUpperTarget;"
            in serial_source
        and "uprightUpper = (double)ROBNeckSafetyUprightUpperTarget" in serial_source
        and "configuration.upperMinimumTarget" in serial_source
        and "configuration.upperMaximumTarget" in serial_source
        and "6045" not in serial_source,
        "Vision tracking no longer uses 6073 as its neutral upper-neck target",
    )
    require(
        "ROBNeckSafetyUprightLowerTarget" in torso_source
        and "ROBNeckSafetyUprightUpperTarget" in torso_source
        and "ROBNeckSafetyDefaultForwardPanTarget" in torso_source
        and "ROBNeckSafetyDefaultLowerTarget" in torso_source
        and "ROBNeckSafetyDefaultUpperTarget" in torso_source
        and 'doubleValue="5798.9583333333339"' in storyboard
        and 'doubleValue="7014"' in storyboard
        and 'id="Bud-rf-B0V"' in storyboard
        and 'doubleValue="6073"' in storyboard
        and 'id="UIa-yF-izD"' in storyboard,
        "The torso controls no longer start at the safe resting defaults",
    )


def check_single_physical_neck_gateway(serial_source: str) -> None:
    gateway_start, gateway_end = objective_c_method_span(
        serial_source, "applySafeNeckPanTarget:"
    )
    all_calls = maestro_send_calls(serial_source)
    for position, channel, message in all_calls:
        if gateway_start <= position < gateway_end:
            continue
        require(
            channel is not None,
            "A dynamic Maestro channel outside the neck gateway cannot be proven "
            f"not to bypass neck safety: {compact(message)}",
        )

    neck_calls = [call for call in all_calls if call[1] in (0, 1, 2)]
    channels = Counter(call[1] for call in neck_calls)
    require(
        set(channels) == {0, 2},
        "Pan and staged upper writes must remain in the gateway, while lower "
        f"uses the coupled channel-1/2 command; found {dict(channels)}",
    )
    for position, channel, message in neck_calls:
        require(
            gateway_start <= position < gateway_end,
            f"Physical neck channel {channel} bypasses applySafeNeckPanTarget: {compact(message)}",
        )

    coupled_helper_source = objective_c_method(
        serial_source, "sendMaestroLowerTarget:"
    )
    coupled_helper = compact(coupled_helper_source)
    command_match = re.search(
        r"unsigned\s+char\s+command\[\]\s*=\s*\{(.*?)\};",
        mask_c_comments_and_literals(coupled_helper_source),
        flags=re.DOTALL,
    )
    coupled_tokens = (
        [compact(token) for token in command_match.group(1).split(",") if compact(token)]
        if command_match is not None
        else []
    )
    require(
        coupled_tokens
        == [
            "0x9F",
            "2",
            "1",
            "lowerTarget & 0x7F",
            "(lowerTarget >> 7) & 0x7F",
            "upperTarget & 0x7F",
            "(upperTarget >> 7) & 0x7F",
        ]
        and "writeMaestroBytes:command length:sizeof(command)" in coupled_helper,
        "The lower/upper helper no longer emits the exact seven-byte "
        "channel-1/2 Maestro multiple-target command",
    )
    coupled_calls = coupled_neck_send_positions(serial_source)
    require(
        len(coupled_calls) == 1
        and gateway_start <= coupled_calls[0] < gateway_end,
        "The coupled lower/upper physical write must occur exactly once and "
        "only inside applySafeNeckPanTarget",
    )

    torso = objective_c_method(
        serial_source, "torso_controllerPassthrough_head_pan:"
    )
    compact_torso = compact(torso)
    vision = objective_c_method(serial_source, "applyVisionNeckPan:")
    require(
        torso.count("applySafeNeckPanTarget:") == 1,
        "Torso servo passthrough no longer submits neck motion through the safe gateway",
    )
    require(
        "applySafeNeckPanTarget:[head_pan intValue] "
        "lowerTiltTarget:[head_tilt intValue] "
        "desiredUpperTarget:[head_upperNeckTilt intValue] "
        "includeLower:YES "
        "allowSupervisedLowerRecovery:lowerTiltOperatorInitiated"
        in compact_torso,
        "Torso pan/lower/upper inputs are no longer mapped exactly to the "
        "corresponding safe-gateway arguments",
    )
    require(
        vision.count("applySafeNeckPanTarget:") == 1,
        "Vision neck control no longer submits motion through the safe gateway",
    )
    compact_vision = compact(vision)
    require(
        "applySafeNeckPanTarget:self.lastVisionNeckPanTarget "
        "lowerTiltTarget:ROBNeckSafetyTargetOff "
        "desiredUpperTarget:self.lastVisionNeckTiltTarget "
        "includeLower:NO allowSupervisedLowerRecovery:NO "
        'source:@"Vision controller"'
        in compact_vision,
        "Vision no longer maps pan/upper demands exactly while keeping lower "
        "motion and supervised recovery disabled",
    )


def check_safe_startup_sequence(
    serial_header: str,
    serial_source: str,
    torso_source: str,
    storyboard: str,
) -> None:
    require(
        "isSafeNeckStartupInProgress" in serial_header
        and "startSafeNeckStartup" in serial_header
        and "cancelSafeNeckStartup" in serial_header
        and "ROBSafeNeckStartupCommandDidChangeNotification"
            in serial_header,
        "The typed safe-neck startup API is missing",
    )

    startup = compact(objective_c_method(serial_source, "startSafeNeckStartup"))
    advance = compact(objective_c_method(
        serial_source, "advanceSafeNeckStartupForGeneration:"
    ))
    gateway = compact(objective_c_method(
        serial_source, "applySafeNeckPanTarget:"
    ))
    invalidate = compact(objective_c_method(
        serial_source, "invalidateNeckCommandStateWithStatus:"
    ))
    require(
        "ROBServoControlStore *store = [ROBServoControlStore shared];" in startup
        and "startupPhaseAtIndex:0" in startup
        and "startupPhaseAtIndex:1" in startup
        and "startupPhaseAtIndex:2" in startup
        and "safeNeckStartupPhaseOne = phaseOne;" in startup
        and "safeNeckStartupPhaseTwo = phaseTwo;" in startup
        and "safeNeckStartupPhaseThree = phaseThree;" in startup
        and "applySafeNeckPanTarget:(int)phaseOne.panTarget "
        "lowerTiltTarget:(int)phaseOne.lowerTarget "
        "desiredUpperTarget:(int)phaseOne.upperTarget "
        "includeLower:YES allowSupervisedLowerRecovery:YES "
        "source:kROBSafeNeckStartupLiftSource" in startup
        and "sendMaestro" not in startup,
        "Startup phase 1 must freeze the validated Servo Control snapshot and "
        "submit its OFF-pan coupled lift only through the shared gateway",
    )
    require(
        "applySafeNeckPanTarget:(int)phaseTwo.panTarget "
        "lowerTiltTarget:(int)phaseTwo.lowerTarget "
        "desiredUpperTarget:(int)phaseTwo.upperTarget "
        "includeLower:YES allowSupervisedLowerRecovery:NO "
        "source:kROBSafeNeckStartupRestSource" in advance
        and "applySafeNeckPanTarget:(int)phaseThree.panTarget "
        "lowerTiltTarget:(int)phaseThree.lowerTarget "
        "desiredUpperTarget:(int)phaseThree.upperTarget "
        "includeLower:YES allowSupervisedLowerRecovery:NO "
        "source:kROBSafeNeckStartupRestSource" in advance
        and "commandedLowerNeckTargetReadyAt" in advance
        and "centeringCommandIsExact" in advance
        and "loweringCommandIsExact" in advance
        and "finalCommandIsExact" in advance
        and "manual controls are available" in advance
        and "ROBSafeNeckStartupPhaseLowering" in advance
        and "sendMaestro" not in advance,
        "Startup must fully settle a separate forward-pan command before "
        "lowering, and must release manual controls on an unexpected hold",
    )
    require(
        "safeStartupLiftCommand" in gateway
        and "safeNeckStartupPhaseOne" in gateway
        and "effectiveConfiguration.cameraLevelingEnabled = false;" in gateway
        and "&& !safeStartupLiftCommand" in gateway
        and "|| safeStartupLiftCommand" in gateway,
        "The gateway lost the narrowly-scoped OFF-pan clearance-lift recovery",
    )
    require(
        "safeNeckStartupGeneration += 1;" in invalidate
        and "safeNeckStartupInProgress = NO;" in invalidate
        and "ROBSafeNeckStartupPhaseInactive" in invalidate,
        "A Maestro disconnect no longer invalidates the asynchronous startup sequence",
    )
    startup_notification_handler = compact(objective_c_method(
        torso_source, "safeNeckStartupCommandDidChange:"
    ))
    require(
        serial_source.count(
            "postNotificationName:"
            "ROBSafeNeckStartupCommandDidChangeNotification"
        ) >= 4
        and "ROBSafeNeckStartupCommandDidChangeNotification" in torso_source
        and "[self refreshNeckCommandReadouts]"
            in startup_notification_handler,
        "Each accepted startup phase must immediately refresh its commanded "
        "targets in the Torso UI",
    )

    servo_action = compact(objective_c_method(torso_source, "applyServoCommand:"))
    servo_timer = compact(objective_c_method(torso_source, "renderServoCommands"))
    require(
        "allNeckAxesEnabled" in servo_action
        and "neckNeedsSafeStartup" in servo_action
        and "neckActivationAction" in servo_action
        and "neckDeactivationAction" in servo_action
        and "self.headPan_enabled.state = NSControlStateValueOn;" in servo_action
        and "self.headTilt_enabled.state = NSControlStateValueOn;" in servo_action
        and "self.headUpperNeckTilt_enabled.state = NSControlStateValueOn;"
            in servo_action
        and servo_action.count(
            "self.headPan_enabled.state = NSControlStateValueOff;"
        ) == 1
        and servo_action.count(
            "self.headTilt_enabled.state = NSControlStateValueOff;"
        ) == 1
        and servo_action.count(
            "self.headUpperNeckTilt_enabled.state = NSControlStateValueOff;"
        ) == 1
        and "self.headPan.integerValue = ROBNeckSafetyDefaultForwardPanTarget;"
            in servo_action
        and "self.headTilt.integerValue = ROBNeckSafetyDefaultLowerTarget;"
            in servo_action
        and "self.headUpperNeckTilt.integerValue = "
            "ROBNeckSafetyDefaultUpperTarget;" in servo_action
        and "[serialBox startSafeNeckStartup]" in servo_action
        and "[serialBox cancelSafeNeckStartup]" in servo_action,
        "A deliberate neck action no longer starts/cancels the safe recovery sequence",
    )
    require(
        "neckSliderAction" in servo_action
        and "self.pendingNeckOperatorCommandAfterStartup = YES;"
            in servo_action
        and "self.pendingLowerTiltOperatorCommandAfterStartup ="
            in servo_action
        and "neckNeedsSafeStartup || serialBox.isSafeNeckStartupInProgress"
            not in servo_action
        and "self.pendingNeckOperatorCommandAfterStartup"
            in servo_timer
        and "!serialBox.isSafeNeckStartupInProgress" in servo_timer
        and "renderServoCommandsOperatorInitiated:YES"
            in servo_timer
        and "lowerTiltOperatorInitiated:lowerTiltOperatorInitiated"
            in servo_timer,
        "Slider requests made during safe startup must remain editable and replay "
        "with operator authority after the sequence completes",
    )
    for button_id in ("wbx-6Z-lzo", "CSn-jc-2oR", "AMM-Oa-PLc"):
        button = re.search(
            rf'<button\b[^>]*\bid="{re.escape(button_id)}"[^>]*>'
            r".*?</button>",
            storyboard,
            flags=re.DOTALL,
        )
        require(button is not None, f"Missing neck enable checkbox {button_id}")
        require(
            'action selector="applyServoCommand:"' in button.group(0),
            f"Neck enable checkbox {button_id} is not wired as an operator action",
        )


def check_operator_authority(
    serial_header: str, serial_source: str, torso_source: str
) -> None:
    require(
        "operatorInitiated:(BOOL)operatorInitiated" in serial_header,
        "The public torso passthrough lost its explicit operator-authority argument",
    )
    require(
        "lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated"
            in serial_header,
        "The public torso passthrough lost lower-axis-specific recovery authority",
    )
    torso_passthrough = objective_c_method(
        serial_source, "torso_controllerPassthrough_head_pan:"
    )
    require(
        "operatorInitiated:(BOOL)operatorInitiated" in torso_passthrough
        and "lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated"
            in torso_passthrough
        and "if (operatorInitiated)" in torso_passthrough
        and "allowSupervisedLowerRecovery:lowerTiltOperatorInitiated"
            in torso_passthrough,
        "The torso passthrough no longer distinguishes operator commands",
    )

    operator_renderer = objective_c_method(
        torso_source, "renderServoCommandsOperatorInitiated:"
    )
    require(
        "operatorInitiated:operatorInitiated" in operator_renderer,
        "The torso view no longer forwards operator authority with its servo command",
    )
    require(
        "lowerTiltOperatorInitiated:lowerTiltOperatorInitiated"
            in operator_renderer,
        "The torso view no longer forwards lower-axis-specific recovery authority",
    )

    timer_renderer = objective_c_method(torso_source, "renderServoCommands")
    require(
        "renderServoCommandsOperatorInitiated:NO" in timer_renderer,
        "The passive one-second renderer must not claim manual neck authority",
    )

    servo_action = objective_c_method(torso_source, "applyServoCommand:")
    require(
        "BOOL neckOperatorAction" in servo_action
        and "BOOL panRequestsSafeLowerRecovery" in servo_action
        and "BOOL lowerTiltOperatorAction" in servo_action
        and "slider == self.headTilt" in servo_action
        and "slider == (id)self.headTilt_enabled" in servo_action
        and "slider == self.headPan" in servo_action
        and "self.headTilt_enabled.state == NSControlStateValueOn" in servo_action
        and "ROBNeckSafetyLowerTargetHasFullPanClearance(" in servo_action
        and "|| panRequestsSafeLowerRecovery;" in compact(servo_action)
        and "renderServoCommandsOperatorInitiated:neckOperatorAction" in servo_action,
        "Servo actions no longer let an explicit pan action safely establish an "
        "enabled lower target in the 5000-through-6495 clearance band",
    )
    for control in (
        "self.headPan",
        "self.headTilt",
        "self.headUpperNeckTilt",
        "self.headPan_enabled",
        "self.headTilt_enabled",
        "self.headUpperNeckTilt_enabled",
    ):
        require(
            control in servo_action,
            f"Neck operator detection no longer includes {control}",
        )


def check_command_readouts(torso_source: str) -> None:
    readout_names = (
        "headPanCommandLabel",
        "lowerNeckCommandLabel",
        "upperNeckCommandLabel",
    )
    setup = objective_c_method(torso_source, "setupNeckCommandReadouts")
    refresh = objective_c_method(torso_source, "refreshNeckCommandReadouts")
    for name in readout_names:
        require(
            re.search(rf"NSTextField\s*\*{name}\s*;", torso_source) is not None,
            f"The torso view lost the {name} command readout property",
        )
        require(
            f"self.{name} = ROBNeckLabel(" in setup
            and f"self.{name}" in refresh,
            f"The torso view no longer creates and refreshes {name}",
        )
    for commanded_value in (
        "commandedNeckPanTarget",
        "commandedLowerNeckTiltTarget",
        "commandedUpperNeckTiltTarget",
    ):
        require(
            commanded_value in refresh,
            f"Command readouts no longer display {commanded_value}",
        )
    for known_value in (
        "neckPanCommandKnown",
        "lowerNeckTiltCommandKnown",
        "upperNeckTiltCommandKnown",
    ):
        require(
            known_value in refresh,
            f"Command readouts no longer distinguish UNKNOWN via {known_value}",
        )
    require(
        refresh.count("UNKNOWN") >= 3,
        "All three neck readouts must visibly distinguish unknown from OFF",
    )
    require(
        "isNeckPanEnvelopeRestricted" in refresh
        and "panNeedsAttention" in refresh
        and 'panNeedsAttention ? @" !" : @""' in refresh
        and 'panEnvelopeRestricted ? @"RESTRICTED" : @"FULL"' in refresh,
        "The pan readout must retain its warning marker for the entire time a "
        "lower-neck-dependent restricted envelope is active",
    )
    require(
        "startupOwnsSliderPresentation" in refresh
        and "isSafeNeckStartupInProgress" in refresh
        and 'isEqualToString:@"Torso safe startup"' in refresh
        and "!self.pendingNeckOperatorCommandAfterStartup" in refresh
        and "self.headPan.integerValue = serialBox.commandedNeckPanTarget;"
            in refresh
        and "self.headTilt.integerValue = "
            "serialBox.commandedLowerNeckTiltTarget;" in compact(refresh)
        and "self.headUpperNeckTilt.integerValue = "
            "serialBox.commandedUpperNeckTiltTarget;" in compact(refresh),
        "Startup command targets must remain synchronized into the sliders "
        "without overwriting an operator request queued during startup",
    )


def check_camera_leveling_control(serial_header: str, torso_source: str) -> None:
    setup = objective_c_method(torso_source, "setupNeckCommandReadouts")
    refresh_control = objective_c_method(
        torso_source, "refreshNeckCameraLevelingControl"
    )
    toggle = objective_c_method(torso_source, "toggleNeckCameraLeveling:")
    refresh_readouts = objective_c_method(torso_source, "refreshNeckCommandReadouts")
    bind = objective_c_method(torso_source, "bindArm_controls")
    compact_setup = compact(setup)
    compact_toggle = compact(toggle)

    require(
        "neckCameraLevelingEnabled" in serial_header
        and "setNeckCameraLevelingEnabled:" in serial_header,
        "The serial gateway no longer exposes the camera-leveling mode to the torso UI",
    )
    require(
        re.search(r"NSButton\s*\*neckCameraLevelingButton\s*;", torso_source)
            is not None
        and 'checkboxWithTitle:@"Keep upright"' in compact_setup
        and "action:@selector(toggleNeckCameraLeveling:)" in compact_setup
        and "NSMakeRect(64, 153, 75, 18)" in compact_setup
        and "controlSize = NSControlSizeMini" in compact_setup
        and "systemFontOfSize:9.0" in compact_setup
        and '@"Keep camera upright"' in setup
        and "[headPanel addSubview:self.neckCameraLevelingButton]" in compact_setup,
        "The Head panel lost its compact, accessible Keep upright checkbox",
    )
    require(
        "[self refreshNeckCameraLevelingControl]" in setup
        and "[self refreshNeckCameraLevelingControl]" in refresh_readouts
        and "[self refreshNeckCommandReadouts]" in bind
        and "serialBox.neckCameraLevelingEnabled" in refresh_control
        and '@"Camera leveling is ON;' in refresh_control
        and '@"Camera leveling is OFF;' in refresh_control,
        "The Keep upright checkbox no longer initializes and refreshes from gateway state",
    )

    seed_index = compact_toggle.find(
        "self.headUpperNeckTilt.integerValue = "
        "serialBox.commandedUpperNeckTiltTarget;"
    )
    setter_index = compact_toggle.find(
        "[serialBox setNeckCameraLevelingEnabled:levelingEnabled]"
    )
    refresh_index = compact_toggle.find(
        "[self refreshNeckCommandReadouts]"
    )
    require(
        "serialBox.upperNeckTiltCommandKnown" in compact_toggle
        and "serialBox.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff"
            in compact_toggle
        and 0 <= seed_index < setter_index < refresh_index
        and "renderServoCommands" not in toggle
        and "torso_controllerPassthrough" not in toggle,
        "Leveling transitions must seed the desired slider from a known active "
        "applied upper target before rebasing and refreshing, without rewriting "
        "unrelated torso channels",
    )
    require(
        "LEVEL %@" in refresh_readouts
        and "serialBox.neckCameraLevelingEnabled ? @\"ON\" : @\"OFF\""
            in compact(refresh_readouts),
        "Neck command status no longer identifies camera leveling as ON or OFF",
    )


def check_stateful_safety_gateway(serial_source: str, torso_source: str) -> None:
    gateway = objective_c_method(serial_source, "applySafeNeckPanTarget:")
    masked_gateway = mask_c_comments_and_literals(gateway)
    compact_gateway = compact(gateway)
    refresh_envelope = compact(
        objective_c_method(serial_source, "refreshSettledNeckEnvelopeAtTime:")
    )
    invalidate = objective_c_method(
        serial_source, "invalidateNeckCommandStateWithStatus:"
    )
    serial_apply = objective_c_method(
        serial_source, "applyNeckSafetyConfiguration:"
    )
    ui_apply = objective_c_method(torso_source, "applyNeckSafetyConfiguration:")

    require(
        gateway.count("ROBNeckSafetySettleGateShouldHold(") >= 1
        and "panRecenterSettleGate" in gateway
        and "stagedPan.panTarget" in gateway
        and "commandedNeckPanTargetReadyAt" in gateway
        and "priorPanTargetIsStillSettling" in gateway
        and "requestedPanWillChange" in gateway,
        "Pan/lower-move staging must use the tested monotonic settle latch",
    )
    require(
        "ROBNeckSafetyPanBounds currentEnvelopeBounds = {" in compact_gateway
        and "ROBNeckSafetyPanBounds requestedEnvelopeBounds = "
            "conservativeUnknownBounds;" in compact_gateway
        and "ROBNeckPanBoundsIntersect( currentEnvelopeBounds, "
            "requestedEnvelopeBounds, &activeEnvelopeBounds" in compact_gateway
        and "ROBNeckClampPanResultToBounds( &effectiveConfiguration, "
            "activeEnvelopeBounds, &stagedPan" in compact_gateway
        and "ROBNeckClampPanResultToBounds( &effectiveConfiguration, "
            "activeEnvelopeBounds, &panResult" in compact_gateway
        and "self.currentNeckPanMinimumDegrees = "
            "panResult.allowedPanMinimumDegrees;" in compact_gateway
        and "self.currentNeckPanMaximumDegrees = "
            "panResult.allowedPanMaximumDegrees;" in compact_gateway,
        "Lower transitions must persist the current/destination intersection "
        "and clamp both staged and final pan commands to both asymmetric edges",
    )
    require(
        "!requestedEnvelopeIsContained" in compact_gateway
        and "self.currentNeckPanMinimumDegrees = settledBounds.minimumDegrees;"
            in refresh_envelope
        and "self.currentNeckPanMaximumDegrees = settledBounds.maximumDegrees;"
            in refresh_envelope,
        "An asymmetric pan edge may widen before the commanded lower target has "
        "completed its settle latch",
    )
    require(
        "establishedEnvelopeMatchesCurrentLower" in gateway
        and "self.panEnvelopeLowerTargetIsKnown" in gateway
        and "self.panEnvelopeLowerTarget == "
            "self.commandedLowerNeckTiltTarget" in compact_gateway
        and "self.pendingPanEnvelopeLowerTarget == "
            "ROBNeckSafetyTargetOff" in compact_gateway
        and "currentEnvelopeBounds = establishedBounds;" in gateway,
        "An established lower-envelope target may retain stale prior pan limits",
    )
    require(
        "if (boundedLower != ROBNeckSafetyTargetOff "
            "&& !ROBNeckSafetyAllowedPanBounds(" in compact_gateway
        and "if (!ROBNeckPanBoundsAreValid(currentEnvelopeBounds))"
            in compact_gateway
        and "if (!self.panEnvelopeLowerTargetIsKnown)" in gateway
        and "int envelopeLower = self.panEnvelopeLowerTargetIsKnown"
            in compact_gateway
        and "calibrationConfirmed ? boundedLower" not in gateway
        and "if (!calibrationConfirmed) { "
            "self.panEnvelopeLowerTargetIsKnown = NO;" not in compact_gateway,
        "An unconfirmed camera calibration may again override the pan envelope "
        "after an operator-supervised lower target is established",
    )
    require(
        "pendingPanEnvelopeLowerTarget != boundedLower" in gateway
        and "pendingPanEnvelopeReadyAt <= 0" in gateway,
        "Repeated identical lower demands may again postpone clearance "
        "expansion forever",
    )
    require(
        "maestroMotionDurationFromTarget:" in gateway
        and "panMotionDuration" in gateway
        and "upperMotionDuration" in gateway
        and "lowerMotionDuration" in gateway
        and "commandedUpperNeckTargetReadyAt" in gateway
        and "now < self.commandedUpperNeckTargetReadyAt" in gateway
        and "pendingPanEnvelopeReadyAt = now + lowerMotionDuration "
            "+ kROBNeckClearanceSettleSeconds;" in compact_gateway,
        "Servo ramp time is no longer included in neck recenter, coupled-upper, "
        "and lower-clearance gates",
    )
    apply_smoothing = objective_c_method(
        serial_source, "applyMaestroServoSmoothingEnabled:"
    )
    require(
        "fmax(" in apply_smoothing
        and "worstLowerDuration" in apply_smoothing
        and "worstPanDuration" in apply_smoothing
        and "worstUpperDuration" in apply_smoothing,
        "Changing the Maestro ramp profile may shorten an in-flight neck safety gate",
    )
    require(
        "NSProcessInfo.processInfo.systemUptime" in gateway
        and "NSDate" not in gateway,
        "The neck settle gateway must use a monotonic clock",
    )
    require(
        "lowerTurningOff" in gateway
        and "effectiveConfiguration.panCenterTarget" in gateway
        and "PAN OFF HELD: LOWER SERVO ACTIVE" in gateway,
        "Lower/Pan OFF transitions no longer preserve the collision envelope",
    )
    require(
        "effectiveDesiredUpperTarget = self.lastDesiredUpperNeckTarget" in gateway
        and "prior uncompensated camera demand is unknown" in gateway
        and "effectiveDesiredUpperTarget = (int)self.commandedUpperNeckTiltTarget"
            not in gateway,
        "An upper-OFF hold may feed the compensated applied target back into "
        "camera leveling",
    )
    require(
        "cameraLimitMoveImprovesRecovery" in gateway
        and "lowerHeldForCameraLimit" in gateway,
        "Camera saturation must hold worsening moves while allowing recovery",
    )
    require(
        re.search(
            r"if\s*\(\s*mayMoveLower\s*\)\s*\{.*?"
            r"sendMaestroLowerTarget\s*:",
            masked_gateway,
            flags=re.DOTALL,
        )
        is not None,
        "The coupled lower/upper packet is no longer confined to the "
        "mayMoveLower branch",
    )
    require(
        "sendMaestroLowerTarget:(unsigned short)boundedLower "
        "upperTarget:(unsigned short)leveledResult.upperTarget"
        in compact_gateway,
        "The coupled packet no longer maps bounded lower to channel 1 and "
        "the leveled upper target to channel 2",
    )
    require(
        "lowerHeldForCalibration" in gateway
        and "lowerHeldForRecovery" in gateway
        and "supervisedManualCommand" in gateway,
        "Uncalibrated/unknown lower motion lost its supervised-recovery gate",
    )
    require(
        "directSupervisedLowerRecovery = supervisedManualCommand" in gateway
        and "&& allowSupervisedLowerRecovery" in gateway,
        "Any neck-axis action may again authorize a supervised lower recovery",
    )
    require(
        "supervisedLowerRecoveryUntil" in gateway
        and "supervisedLowerRecoveryPanTarget" in gateway
        and "supervisedLowerRecoveryTarget" in gateway
        and "supervisedLowerRecoveryUpperTarget" in gateway
        and "kROBNeckSupervisedRecoverySeconds" in gateway,
        "A direct lower-axis recovery authorization no longer survives its "
        "required pan staging interval as an exact-demand latch",
    )
    require(
        "supervisedRecoveryMotionDuration = fmax(" in compact_gateway
        and "effectiveConfiguration.panMinimumTarget" in gateway
        and "effectiveConfiguration.panMaximumTarget" in gateway
        and "effectiveConfiguration.upperMinimumTarget" in gateway
        and "effectiveConfiguration.upperMaximumTarget" in gateway
        and "+ supervisedRecoveryMotionDuration "
            "+ kROBNeckSupervisedRecoverySeconds;" in compact_gateway,
        "A slower Maestro profile may again let supervised lower recovery "
        "expire before pan/upper staging completes",
    )
    for flag in (
        "neckPanCommandKnown = NO",
        "lowerNeckTiltCommandKnown = NO",
        "upperNeckTiltCommandKnown = NO",
    ):
        require(flag in invalidate, f"Invalidation no longer clears {flag}")
    require(
        "neckCommandStateKnown" in serial_apply
        and "neckCommandStateKnown" in ui_apply,
        "Unknown command state may again be accepted as known OFF calibration state",
    )
    require(
        "renderServoCommands" not in ui_apply,
        "Saving neck calibration must not actuate neck or arm controls",
    )
    require(
        "@synchronized (self)" in gateway
        and "@synchronized (self)" in invalidate,
        "Neck gateway/invalidation are no longer serialized against reconnect",
    )


def check_typed_gesture_ingress(serial_header: str, serial_source: str) -> None:
    require(
        "requestNeckGesturePanDegrees:" in serial_header
        and "ROBNeckCommandDisposition" in serial_header,
        "The typed autonomous neck-gesture ingress/result contract is missing",
    )
    gesture = objective_c_method(serial_source, "requestNeckGesturePanDegrees:")
    compact_gesture = compact(gesture)
    require(
        gesture.count("applySafeNeckPanTarget:") == 1
        and "neckSafetyCalibrationConfirmed" in gesture
        and "neckCommandStateKnown" in gesture
        and "gestureNeckAuthorityUntil" in gesture
        and "lowerMinimumTarget" in gesture
        and "upperMinimumTarget" in gesture,
        "Typed gestures no longer validate state/calibration/ranges and use the gateway lease",
    )
    require(
        "applySafeNeckPanTarget:panTarget "
        "lowerTiltTarget:(int)lowerTiltRawTarget "
        "desiredUpperTarget:(int)cameraTiltRawTarget "
        "includeLower:YES allowSupervisedLowerRecovery:NO "
        "source:commandSource"
        in compact_gesture,
        "Typed gestures no longer map calibrated pan and the corresponding "
        "lower/upper targets exactly into the gateway",
    )
    cancel = objective_c_method(serial_source, "cancelNeckGestureAuthority")
    require(
        "gestureNeckAuthorityUntil = 0" in cancel,
        "Gesture cancellation no longer releases authority without a stale fallback",
    )


def check_configurable_surface(serial_source: str, torso_source: str) -> None:
    setup = objective_c_method(torso_source, "setupNeckSafetyConfigurationControls")
    compact_setup = compact(setup)
    show = objective_c_method(torso_source, "showNeckSafetyConfiguration:")
    load = objective_c_method(torso_source, "loadNeckSafetyConfigurationControls")
    apply = objective_c_method(torso_source, "applyNeckSafetyConfiguration:")
    serial_apply = objective_c_method(serial_source, "applyNeckSafetyConfiguration:")

    require(
        '@"Safety…"' in setup
        and "[headPanel addSubview:safetyButton]" in setup
        and "NSPopoverBehaviorTransient" in setup
        and "showRelativeToRect:anchor.bounds" in show,
        "Neck safety configuration is no longer reachable from the Head panel "
        "through its width-independent popover",
    )
    require(
        "initWithFrame:NSMakeRect(0, 0, 307, 143)" in compact_setup
        and '@"Below 5000 pan ±"' in setup
        and '@"Symmetric pan limit below lower tilt target 5000"' in setup
        and '@"Upright targets"' in setup
        and "ROBNeckSafetyUprightLowerTarget" in setup
        and "ROBNeckSafetyUprightUpperTarget" in setup
        and '@"Unknown/off pan"' in setup
        and "forwardLabel, self.forwardPanMinimumDegreesField, "
            "forwardRangeSeparator, self.forwardPanMaximumDegreesField, "
            "forwardDegreesLabel" in compact_setup,
        "The lower-clearance and unknown/off controls no longer fit inside "
        "the Safety popover or are not attached to its content box",
    )

    field_mapping = {
        "restrictedPanDegreesField": (
            "restrictedPanDegrees", "doubleValue", "restrictedPanDegrees"
        ),
        "forwardPanMinimumDegreesField": (
            "forwardPanMinimumDegrees", "doubleValue", "forwardPanMinimumDegrees"
        ),
        "forwardPanMaximumDegreesField": (
            "forwardPanMaximumDegrees", "doubleValue", "forwardPanMaximumDegrees"
        ),
        "panCenterTargetField": (
            "panCenterTarget", "integerValue", "panCenterTarget"
        ),
        "panTargetsPerDegreeField": (
            "panTargetsPerDegree", "doubleValue", "panTargetsPerDegree"
        ),
        "cameraCounterRotationGainField": (
            "upperCounterRotationGain",
            "doubleValue",
            "cameraCounterRotationGain",
        ),
    }
    compact_load = compact(load)
    compact_apply = compact(apply)
    for ui_field, (config_field, value_accessor, parsed_variable) in field_mapping.items():
        require(
            re.search(rf"NSTextField\s*\*{ui_field}\s*;", torso_source) is not None,
            f"The torso UI no longer exposes {ui_field}",
        )
        require(
            f"self.{ui_field} = ROBNeckNumberField(" in setup,
            f"The torso UI no longer creates {ui_field}",
        )
        require(
            f"self.{ui_field}.{value_accessor} = configuration.{config_field};"
            in compact_load,
            f"The torso UI no longer loads {config_field}",
        )
        require(
            f"configuration.{config_field} =" in compact_apply
            and f"ROBNeckReadFiniteNumber(self.{ui_field}, &{parsed_variable})"
            in compact_apply,
            f"The torso UI no longer applies {config_field}",
        )

    require(
        "applyNeckSafetyConfiguration:configuration" in apply
        and 'stringValue = @"Invalid"' in apply,
        "The torso UI no longer applies and reports validation of neck settings",
    )
    require(
        "forwardPanLowerAnchorField" not in torso_source
        and "fullPanLowerMinimumField" not in torso_source
        and "fullPanLowerMaximumField" not in torso_source,
        "Obsolete editable envelope/reference anchors must not remain in the UI",
    )
    require(
        "currentNeckPanMinimumDegrees" in torso_source
        and "currentNeckPanMaximumDegrees" in torso_source
        and "pan envelope %@ %+.1f°…%+.1f°" in torso_source,
        "The command readout no longer reports the asymmetric applied pan envelope",
    )
    require(
        "renderServoCommands" not in apply,
        "Applying neck configuration must not submit unrelated servo commands",
    )
    validation_index = serial_apply.find("ROBNeckSafetyConfigIsValid(&configuration)")
    persistence_index = serial_apply.find("persistNeckSafetyConfiguration:configuration")
    require(
        validation_index >= 0
        and persistence_index > validation_index,
        "Neck settings must validate before their atomic persistence",
    )
    require(
        re.search(
            r'@"[^"\n]*no position feedback[^"\n]*"',
            torso_source,
            flags=re.IGNORECASE,
        )
        is not None,
        "The torso UI must explicitly disclose that command readouts are not position feedback",
    )


def check_versioned_dictionary_persistence(
    policy_header: str,
    policy_source: str,
    serial_header: str,
    serial_source: str,
) -> None:
    key_declarations = re.findall(
        r'static\s+NSString\s*\*\s*const\s+'
        r'(kROBNeckSafety\w*ConfigurationDefaultsKey)\s*=\s*'
        r'@"(ROBNeckSafetyConfigurationV\d+)"\s*;',
        serial_source,
    )
    require(
        dict(key_declarations)
        == {
            "kROBNeckSafetyConfigurationDefaultsKey":
                "ROBNeckSafetyConfigurationV3",
            "kROBNeckSafetyV2ConfigurationDefaultsKey":
                "ROBNeckSafetyConfigurationV2",
            "kROBNeckSafetyLegacyConfigurationDefaultsKey":
                "ROBNeckSafetyConfigurationV1",
        },
        "Neck safety settings must use an active V3 dictionary and read-only "
        "V2/V1 migration dictionaries",
    )
    active_key = "kROBNeckSafetyConfigurationDefaultsKey"
    v2_key = "kROBNeckSafetyV2ConfigurationDefaultsKey"
    legacy_key = "kROBNeckSafetyLegacyConfigurationDefaultsKey"
    require(
        serial_source.count(active_key) == 3
        and serial_source.count(v2_key) == 2
        and serial_source.count(legacy_key) == 2,
        "V3 must have exactly one declaration, read, and write; V2/V1 must "
        "each have exactly one declaration and read",
    )

    load = compact(objective_c_method(serial_source, "loadNeckSafetyConfiguration"))
    persist = compact(
        objective_c_method(serial_source, "persistNeckSafetyConfiguration:")
    )
    require(
        f"dictionaryForKey:{active_key}" in load
        and f"dictionaryForKey:{v2_key}" in load
        and f"dictionaryForKey:{legacy_key}" in load
        and "NSInteger storedVersion = 3;" in load
        and "storedVersion = 2;" in load
        and "storedVersion = 1;" in load
        and "NSNumber *expectedVersion = @(storedVersion);" in load
        and 'saved[@"version"]' in load
        and "isEqual:expectedVersion" in load,
        "Neck settings no longer prefer V3 and verify explicitly versioned "
        "V2/V1 fallbacks",
    )
    require(
        "NSDictionary *saved = @{" in persist
        and '@"version": @3' in persist
        and '@"calibrationConfirmed": '
            "@(self.neckSafetyCalibrationConfirmed)" in persist
        and f"setObject:saved forKey:{active_key}" in persist
        and v2_key not in persist
        and legacy_key not in persist,
        "Neck settings no longer persist atomically as V3 while preserving "
        "confirmation state, or may write a migration source",
    )
    require(
        "self.neckSafetyCalibrationConfirmed = storedVersion == 3" in load
        and '&& [saved[@"calibrationConfirmed"] boolValue];' in load,
        "Migrating V2/V1 settings must force an unconfirmed V3 safety "
        "calibration",
    )
    require(
        "const int32_t shippedFullPanLowTarget = 5300;" in load
        and "const int32_t shippedFullPanHighTarget = 6822;" in load
        and "shippedFullPanLowTarget > configuration.lowerMinimumTarget" in load
        and "shippedFullPanHighTarget < configuration.lowerMaximumTarget" in load
        and "if (shippedFullPanBandFits) {" in load
        and "configuration.lowerFullPanLowTarget = "
            "shippedFullPanLowTarget;" in load
        and "configuration.lowerFullPanHighTarget = "
            "shippedFullPanHighTarget;" in load,
        "V2/V1 migration must preserve the wider shipped legacy band "
        "only when it fits the preserved lower hard stops",
    )
    require(
        "const int32_t shippedForwardAnchor = 6823;" in load
        and "shippedForwardAnchor > "
            "configuration.lowerFullPanHighTarget" in load
        and "shippedForwardAnchor <= configuration.lowerMaximumTarget" in load
        and "? shippedForwardAnchor : configuration.lowerMaximumTarget;" in load
        and "configuration.cameraLevelingEnabled = true;" in load,
        "Migrated settings must preserve the legacy V3 anchor when compatible "
        "and default the new leveling switch on",
    )
    require(
        "if (storedVersion >= 2) {" in load
        and "-fmin(15.0, configuration.restrictedPanDegrees);" in load
        and "fmin(2.1, configuration.restrictedPanDegrees);" in load,
        "V1 migration must derive an in-range forward anchor and clip both "
        "shipped asymmetric bounds to the legacy restricted-pan magnitude",
    )
    for field, accessor in (
        ("panMinimumTarget", "intValue"),
        ("panCenterTarget", "intValue"),
        ("panMaximumTarget", "intValue"),
        ("panTargetsPerDegree", "doubleValue"),
        ("lowerMinimumTarget", "intValue"),
        ("lowerFullPanLowTarget", "intValue"),
        ("lowerFullPanHighTarget", "intValue"),
        ("lowerMaximumTarget", "intValue"),
        ("upperMinimumTarget", "intValue"),
        ("upperMaximumTarget", "intValue"),
        ("restrictedPanDegrees", "doubleValue"),
        ("upperCounterRotationGain", "doubleValue"),
    ):
        require(
            f'configuration.{field} = [saved[@"{field}"] {accessor}];'
            in load,
            f"V1 migration no longer preserves the calibrated common field {field}",
        )
    for key in (
        "calibrationConfirmed",
        "panMinimumTarget",
        "panCenterTarget",
        "panMaximumTarget",
        "panTargetsPerDegree",
        "lowerMinimumTarget",
        "lowerFullPanLowTarget",
        "lowerFullPanHighTarget",
        "lowerForwardRestrictedTarget",
        "lowerMaximumTarget",
        "upperMinimumTarget",
        "upperMaximumTarget",
        "restrictedPanDegrees",
        "forwardPanMinimumDegrees",
        "forwardPanMaximumDegrees",
        "cameraLevelingEnabled",
        "upperCounterRotationGain",
    ):
        require(
            f'@"{key}"' in load and f'@"{key}"' in persist,
            f"The versioned neck configuration dictionary lost {key}",
        )

    require(
        "bool cameraLevelingEnabled;" in policy_header
        and "config->cameraLevelingEnabled" in
            braced_declaration(policy_source, "bool ROBNeckSafetyApply("),
        "The pure-C policy no longer exposes or enforces the persisted camera "
        "leveling switch",
    )
    require(
        re.search(
            r"@property\s*\(readonly,\s*assign,\s*"
            r"getter=isNeckCameraLevelingEnabled\)\s*BOOL\s+"
            r"neckCameraLevelingEnabled\s*;",
            serial_header,
        ) is not None
        and "- (BOOL)setNeckCameraLevelingEnabled:(BOOL)enabled;"
            in serial_header,
        "ROBSerialBox no longer exposes the coordinated persisted camera "
        "leveling getter/setter API",
    )
    toggle_setter = compact(objective_c_method(
        serial_source, "setNeckCameraLevelingEnabled:"
    ))
    require(
        "configuration.cameraLevelingEnabled = enabled;" in toggle_setter
        and "persistNeckSafetyConfiguration:configuration" in toggle_setter
        and "neckLevelingReferenceIsValid" in toggle_setter
        and "BOOL activePoseIsKnown = self.neckCommandStateKnown" in toggle_setter
        and "self.manualNeckOverrideUntil = now + "
            "kROBNeckManualOverrideSeconds;" in toggle_setter
        and "self.visionNeckAuthorityUntil = 0;" in toggle_setter
        and "self.gestureNeckAuthorityUntil = 0;" in toggle_setter
        and "self.torsoNeckAuthorityRequiresOperatorAction = YES;"
            in toggle_setter
        and "applySafeNeckPanTarget:(int)self.commandedNeckPanTarget"
            in toggle_setter
        and "lowerTiltTarget:(int)self.commandedLowerNeckTiltTarget"
            in toggle_setter
        and "desiredUpperTarget:(int)self.commandedUpperNeckTiltTarget"
            in toggle_setter
        and "includeLower:YES" in toggle_setter
        and "allowSupervisedLowerRecovery:NO" in toggle_setter
        and "sendMaestro" not in toggle_setter,
        "The camera leveling toggle must persist, claim manual authority, and "
        "reapply only a known active neck pose through the shared gateway",
    )
    gateway = compact(objective_c_method(
        serial_source, "applySafeNeckPanTarget:"
    ))
    require(
        "BOOL levelingRequired = "
            "effectiveConfiguration.cameraLevelingEnabled" in gateway
        and gateway.count("&& levelingRequired") >= 4
        and "double runtimeAdjustment = levelingRequired" in gateway,
        "Disabling camera leveling may still indirectly counter-rotate or "
        "report compensation in the serial gateway",
    )


def check_off_sentinel(policy_header: str, policy_source: str) -> None:
    require(
        re.search(r"ROBNeckSafetyTargetOff\s*=\s*0\b", policy_header) is not None,
        "The Maestro-off sentinel is no longer target 0",
    )
    apply = braced_declaration(policy_source, "bool ROBNeckSafetyApply(")
    compact_apply = compact(apply)
    require(
        "*resultOut = (ROBNeckSafetyResult){0};" in compact_apply,
        "The neck policy no longer starts from an all-off result",
    )
    for requested_target in (
        "requestedPanTarget",
        "requestedLowerTarget",
        "desiredUpperTarget",
    ):
        require(
            f"if ({requested_target} != ROBNeckSafetyTargetOff)" in compact_apply,
            f"Target 0 may no longer remain off for {requested_target}",
        )


def main() -> None:
    check_pure_c_policy_and_project()

    policy_header = POLICY_HEADER_PATH.read_text(encoding="utf-8")
    policy_source = POLICY_SOURCE_PATH.read_text(encoding="utf-8")
    serial_header = SERIAL_HEADER_PATH.read_text(encoding="utf-8")
    serial_source = SERIAL_SOURCE_PATH.read_text(encoding="utf-8")
    torso_source = TORSO_SOURCE_PATH.read_text(encoding="utf-8")
    storyboard = STORYBOARD_PATH.read_text(encoding="utf-8")

    check_lower_clearance_threshold(
        policy_header,
        policy_source,
        serial_source,
        torso_source,
        storyboard,
    )
    check_single_physical_neck_gateway(serial_source)
    check_safe_startup_sequence(
        serial_header,
        serial_source,
        torso_source,
        storyboard,
    )
    check_operator_authority(serial_header, serial_source, torso_source)
    check_command_readouts(torso_source)
    check_camera_leveling_control(serial_header, torso_source)
    check_stateful_safety_gateway(serial_source, torso_source)
    check_typed_gesture_ingress(serial_header, serial_source)
    check_configurable_surface(serial_source, torso_source)
    check_versioned_dictionary_persistence(
        policy_header,
        policy_source,
        serial_header,
        serial_source,
    )
    check_off_sentinel(policy_header, policy_source)

    print("ROB neck safety structural checks passed")


if __name__ == "__main__":
    main()
