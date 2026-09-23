"""Replay and assess camera/encoder startup calibration; no actuator access.

The arm starts hanging, presents itself to the camera, then exercises one
joint at a time. Commanded positions prove intent, never measured pose.
Only independent camera observations and measured encoder positions enter
the fitted mapping. Saved reports retain the frames and fit/validation split.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np

JOINTS = 7
SIDES = {"right": {"core": "L-10", "gatewayArm": "left", "udpPort": 26001},
         "left": {"core": "R-11", "gatewayArm": "right", "udpPort": 26002}}
LIMITS = np.array([2.4435, 2.3213, 2.2863, 2.2863, 2.2863, 2.2863, 3.05])
MAX_SAMPLE_SKEW_MS = 100
MAX_SIGMA_RAD = math.radians(1)
MAX_OFFSET_ERROR_RAD = math.radians(2)
MAX_TRACKING_ERROR_RAD = math.radians(.75)
MAX_STATIONARY_SPREAD_RAD = math.radians(.5)
MIN_WIGGLE_RAD = math.radians(1)
MAX_WIGGLE_RAD = math.radians(5)


def vector(value, name):
    if (not isinstance(value, list) or len(value) != JOINTS
            or any(isinstance(x, bool) or not isinstance(x, (int, float))
                   or not math.isfinite(x) for x in value)):
        raise ValueError(f"{name} must contain seven finite numbers")
    return np.asarray(value, float)


def finite(value, name, lower=0, upper=math.inf):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or not lower <= value <= upper):
        raise ValueError(f"Invalid {name}")
    return float(value)


def preview_steps(hanging_vendor, presentation_waypoints, wiggle_rad=math.radians(3)):
    """Preview an explicit staged route; never infer a path from an endpoint.

    At least one clearance waypoint must precede the inspection endpoint.
    Small steps alone do not establish tread clearance. This function neither
    certifies clearance/visibility nor dispatches its output.
    """
    hanging = vector(hanging_vendor, "hangingVendor")
    finite(wiggle_rad, "wiggleRadians", MIN_WIGGLE_RAD, MAX_WIGGLE_RAD)
    if not isinstance(presentation_waypoints, list) or len(presentation_waypoints) < 2:
        raise ValueError("Provide an ordered clearance waypoint and inspection endpoint; a final pose alone is insufficient")
    route, names = [], set()
    for waypoint in presentation_waypoints:
        if not isinstance(waypoint, dict):
            raise ValueError("Each route waypoint needs a name and seven positions")
        name = waypoint.get("name")
        if not isinstance(name, str) or not name.strip() or name in names:
            raise ValueError("Route waypoint names must be nonempty and unique")
        names.add(name)
        target = vector(waypoint.get("positions"), f"{name} positions")
        if np.any(abs(target) > LIMITS):
            raise ValueError("Route waypoint exceeds vendor joint bounds")
        route.append((name, target))
    presentation = route[-1][1]
    if np.any(abs(hanging) > LIMITS) or np.any(abs(presentation) + wiggle_rad > LIMITS):
        raise ValueError("Presentation/wiggles exceed vendor joint bounds")
    steps = [dict(phase="hanging", positions=hanging.tolist(), motion=False)]
    previous = hanging
    for index, (name, target) in enumerate(route):
        segments = max(1, math.ceil(float(max(abs(target - previous))) / math.radians(3)))
        for step in range(1, segments + 1):
            steps.append(dict(phase="present", waypoint=index + 1, waypointName=name,
                              positions=(previous + (target - previous) * step / segments).tolist(),
                              durationSeconds=1.0, motion=True, stopAndVerify=step == segments))
        previous = target
    steps.append(dict(phase="baseline", positions=presentation.tolist(), motion=False))
    for joint in range(JOINTS):
        for phase, delta in (("plus", wiggle_rad), ("minus", -wiggle_rad), ("return", 0)):
            target = presentation.copy(); target[joint] += delta
            steps.append(dict(phase=phase, joint=joint + 1, positions=target.tolist(),
                              durationSeconds=1.5, motion=True))
    # A separate, unused pose must test the fitted offsets before acceptance.
    steps.append(dict(phase="validation", positions=None, motion=False,
                      detail="Acquire a separately reviewed held-out pose; do not reuse fitting frames"))
    return dict(schemaVersion=1, hardwareOutputEnabled=False, clearanceVerified=False,
                requiresSegmentValidation=True,
                startPose="hanging", destination="camera-visible inspection pose",
                returnToB1Zero=False, wiggleRadians=wiggle_rad, steps=steps)


def endpoint(samples, identity, seen_frames, seen_telemetry):
    if not isinstance(samples, list) or len(samples) < 3:
        raise ValueError("Each endpoint needs at least three distinct synchronized samples")
    encoders, camera, uncertainty, targets, times = [], [], [], [], []
    last_time = -math.inf
    camera_key = None
    command_id = None
    for sample in samples:
        if any(sample.get(key) != value for key, value in identity.items()):
            raise ValueError("Sample arm, model, reference, or controller session changed")
        if sample.get("source") != "markerless_rgbd" or sample.get("status") != "confirmed":
            raise ValueError("Unconfirmed camera pose cannot calibrate offsets")
        frame = (sample.get("camera"), sample.get("streamID"), sample.get("frameSequence"))
        telemetry = sample.get("telemetrySequence")
        if (frame[0] not in ("face", "belly") or not isinstance(frame[1], str) or not frame[1]
                or not isinstance(frame[2], int) or isinstance(frame[2], bool) or frame[2] <= 0
                or not isinstance(telemetry, int) or isinstance(telemetry, bool) or telemetry <= 0
                or frame in seen_frames or telemetry in seen_telemetry):
            raise ValueError("Missing, repeated, or reused frame/telemetry identity")
        if camera_key is not None and frame[:2] != camera_key:
            raise ValueError("An endpoint cannot combine different camera streams")
        camera_key = frame[:2]
        seen_frames.add(frame); seen_telemetry.add(telemetry)
        capture = finite(sample.get("cameraCapturedAtMilliseconds"), "camera capture time")
        encoder_time = finite(sample.get("telemetrySampledAtMilliseconds"), "encoder sample time")
        command_time = finite(sample.get("commandAcknowledgedAtMilliseconds"), "command acknowledgement time")
        received = finite(sample.get("receivedAtMilliseconds"), "receipt time")
        current_command = sample.get("commandID")
        if (sample.get("commandAccepted") is not True
                or not isinstance(current_command, int) or isinstance(current_command, bool)
                or not 0 < current_command <= 0xFFFFFFFF
                or command_id is not None and current_command != command_id):
            raise ValueError("Endpoint needs one correlated accepted command")
        command_id = current_command
        if not 0 <= received - capture <= 750 or not 0 <= received - encoder_time <= 250:
            raise ValueError("Stale camera or encoder data was received during the trial")
        if (abs(capture - encoder_time) > MAX_SAMPLE_SKEW_MS or capture <= command_time
                or encoder_time <= command_time or capture <= last_time):
            raise ValueError("Frames must follow the acknowledged command and be synchronized/in order")
        last_time = capture
        finite(sample.get("cameraRegistrationRMS"), "camera registration residual", 0, .01)
        finite(sample.get("residualMeters"), "arm surface residual", 0, .012)
        q_vendor = vector(sample.get("measuredVendorRadians"), "measuredVendorRadians")
        q_camera = vector(sample.get("observedModelRadians"), "observedModelRadians")
        sigma = vector(sample.get("standardDeviationRadians"), "standardDeviationRadians")
        target = vector(sample.get("commandedVendorRadians"), "commandedVendorRadians")
        if np.any(abs(q_vendor) > LIMITS) or np.any(abs(target) > LIMITS):
            raise ValueError("Vendor position is outside joint bounds")
        if np.any(sigma < 0) or np.any(sigma > MAX_SIGMA_RAD):
            raise ValueError("Camera uncertainty is too large for an offset correction")
        if max(abs(q_vendor - target)) > MAX_TRACKING_ERROR_RAD:
            raise ValueError("Commanded endpoint was not reached in measured encoder feedback")
        encoders.append(q_vendor); camera.append(q_camera); uncertainty.append(sigma)
        targets.append(target); times.append(capture)
    encoders, camera, uncertainty, targets = map(np.array, (encoders, camera, uncertainty, targets))
    if times[-1] - times[0] < 500:
        raise ValueError("Endpoint needs at least 500 ms of stationary evidence")
    if np.max(np.ptp(encoders, axis=0)) > MAX_STATIONARY_SPREAD_RAD:
        raise ValueError("Encoders have not settled")
    if np.max(np.ptp(camera, axis=0)) > MAX_STATIONARY_SPREAD_RAD:
        raise ValueError("Camera pose has not settled")
    if np.max(np.ptp(targets, axis=0)) > 1e-9:
        raise ValueError("Endpoint combined different targets")
    return dict(vendor=np.median(encoders, axis=0), model=np.median(camera, axis=0),
                sigma=np.max(uncertainty, axis=0), target=targets[0], count=len(samples),
                commandID=command_id, firstCapturedAt=times[0], lastCapturedAt=times[-1])


def assess(record, previous=None):
    """Fit direction/offset and validate on held-out measured poses.

    Failures return a rejected report with no installable offset. Existing
    calibration must not be overwritten by an unobservable or failed trial.
    """
    report = dict(schemaVersion=1, accepted=False, hardwareOutputEnabled=False,
                  mapping="q_model = direction * (q_vendor - vendorAtModelZero)", joints=[])
    try:
        if record.get("schemaVersion") != 1 or record.get("arm") not in SIDES:
            raise ValueError("Invalid calibration record or physical arm")
        identity = {key: record.get(key) for key in ("arm", "modelID", "referenceID", "controllerSession")}
        if any(not isinstance(value, str) or not value for value in identity.values()):
            raise ValueError("Calibration requires explicit model/reference/session identity")
        if record.get("binding") != SIDES[record["arm"]]:
            raise ValueError("Physical arm and gateway binding disagree")
        report.update(identity, binding=record["binding"])
        frames, telemetry = set(), set()
        command_ids, last_endpoint_time = set(), -math.inf
        def observed_endpoint(samples):
            nonlocal last_endpoint_time
            observed = endpoint(samples, identity, frames, telemetry)
            if observed["commandID"] in command_ids or observed["firstCapturedAt"] <= last_endpoint_time:
                raise ValueError("Endpoints must follow distinct commands in capture-time order")
            command_ids.add(observed["commandID"])
            last_endpoint_time = observed["lastCapturedAt"]
            return observed
        baseline = observed_endpoint(record.get("baseline"))
        wiggles = record.get("wiggles")
        if not isinstance(wiggles, list) or len(wiggles) != JOINTS:
            raise ValueError("Exactly one independent wiggle trial per joint is required")
        zeros, directions = [], []
        for joint, trial in enumerate(wiggles):
            if trial.get("joint") != joint + 1:
                raise ValueError("Wiggles must identify servo 1 through servo 7 in order")
            plus, minus, returned = [observed_endpoint(trial.get(name))
                                     for name in ("plus", "minus", "return")]
            plus_step = plus["target"] - baseline["target"]
            minus_step = minus["target"] - baseline["target"]
            other = [i for i in range(JOINTS) if i != joint]
            if (max(abs(plus_step[other])) > 1e-9 or max(abs(minus_step[other])) > 1e-9
                    or max(abs(returned["target"] - baseline["target"])) > 1e-9
                    or not MIN_WIGGLE_RAD <= plus_step[joint] <= MAX_WIGGLE_RAD
                    or not -MAX_WIGGLE_RAD <= minus_step[joint] <= -MIN_WIGGLE_RAD):
                raise ValueError(f"J{joint + 1} trial must wiggle only that joint within configured bounds")
            vendor_span = plus["vendor"][joint] - minus["vendor"][joint]
            visual_span = plus["model"][joint] - minus["model"][joint]
            sigma = math.hypot(plus["sigma"][joint], minus["sigma"][joint])
            if vendor_span < MIN_WIGGLE_RAD or abs(visual_span) <= max(3 * sigma, MIN_WIGGLE_RAD):
                raise ValueError(f"J{joint + 1} movement is missing or below camera uncertainty")
            gain = visual_span / vendor_span
            if not .85 <= abs(gain) <= 1.15:
                raise ValueError(f"J{joint + 1} camera/encoder response scale disagrees ({gain:.3f})")
            direction = 1 if gain > 0 else -1
            fits = (baseline, plus, minus, returned)
            estimates = np.array([sample["vendor"][joint] - direction * sample["model"][joint]
                                  for sample in fits])
            zero = float(np.median(estimates))
            fit_error = float(max(abs(estimates - zero)))
            # Independent joints must not move when only this servo was asked to move.
            for sample in fits[1:]:
                if max(abs(sample["vendor"][other] - baseline["vendor"][other])) > MAX_TRACKING_ERROR_RAD:
                    raise ValueError(f"J{joint + 1} trial moved another encoder")
                allowed = MAX_OFFSET_ERROR_RAD + 3 * np.hypot(sample["sigma"][other], baseline["sigma"][other])
                if np.any(abs(sample["model"][other] - baseline["model"][other]) > allowed):
                    raise ValueError(f"J{joint + 1} trial produced inconsistent motion in another visual joint")
            closure = float(abs(returned["model"][joint] - baseline["model"][joint]))
            if fit_error > MAX_OFFSET_ERROR_RAD or closure > MAX_OFFSET_ERROR_RAD:
                raise ValueError(f"J{joint + 1} offset is inconsistent or return motion has excessive error")
            zeros.append(zero); directions.append(direction)
            report["joints"].append(dict(joint=joint + 1, direction=direction, gain=gain,
                                          fitErrorRadians=fit_error, returnErrorRadians=closure,
                                          cameraSigmaRadians=float(max(s["sigma"][joint] for s in fits))))
        validation = observed_endpoint(record.get("validation"))
        if max(abs(validation["vendor"] - baseline["vendor"])) < MIN_WIGGLE_RAD:
            raise ValueError("Validation must use a different pose, not the fitting baseline")
        predicted = np.array(directions) * (validation["vendor"] - np.array(zeros))
        error = abs(predicted - validation["model"])
        if max(error) > MAX_OFFSET_ERROR_RAD:
            raise ValueError("Held-out camera frame disagrees with the fitted offsets")
        report.update(accepted=True, vendorAtModelZeroRadians=zeros, direction=directions,
                      validationErrorRadians=error.tolist(), distinctCameraFrames=len(frames),
                      baselineModelRadians=baseline["model"].tolist(),
                      validationModelRadians=validation["model"].tolist())
        if previous is not None:
            if (previous.get("accepted") is not True
                    or any(previous.get(k) != record.get(k) for k in ("arm", "modelID", "referenceID", "binding"))):
                raise ValueError("Previous calibration belongs to different geometry or arm identity")
            old = vector(previous.get("vendorAtModelZeroRadians"), "previous offset")
            report["offsetChangeRadians"] = (np.array(zeros) - old).tolist()
            report["previousControllerSession"] = previous.get("controllerSession")
        canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        report["evidenceSHA256"] = hashlib.sha256(canonical).hexdigest()
        report["detail"] = "Camera/encoder fit passed independent pose validation; no movement was dispatched"
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        report["accepted"] = False
        report.pop("vendorAtModelZeroRadians", None)
        report.pop("direction", None)
        report["detail"] = str(error)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path, required=True,
                        help="New report path; never overwrite the previous calibration")
    args = parser.parse_args()
    record = json.loads(args.record.read_text())
    previous = json.loads(args.previous.read_text()) if args.previous else None
    report = assess(record, previous)
    with args.output.open("x") as handle:
        json.dump(report, handle, indent=2, allow_nan=False); handle.write("\n")
    print(report["detail"])
    raise SystemExit(0 if report["accepted"] else 1)


if __name__ == "__main__":
    main()
