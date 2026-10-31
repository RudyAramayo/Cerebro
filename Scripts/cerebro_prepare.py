#!/usr/bin/env python3
"""Overlap one explicit arm preparation with bounded, local RGB-D processing.

Input is a freshly reviewed arm-only target, never a saved calibration pose.
This does not choose targets, certify clearance, close jaws or chain motions.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import re
import statistics
import struct
import time
import uuid

import cerebroctl


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_plan(plan):
    require(set(plan) == {"baseline", "values", "seconds"}, "Expected baseline, values and seconds")
    baseline, values = plan["baseline"], plan["values"]
    keys = {f"arm.{a}.j{j}" for a in ("left", "right") for j in range(1, 8)}
    require(isinstance(baseline, dict) and set(baseline) == keys, "Supply both measured arm baselines")
    require(isinstance(values, dict) and values and set(values) <= keys, "Preparation accepts arm channels only")
    require(all(number(v) for v in [*baseline.values(), *values.values(), plan["seconds"]]), "Non-finite target")
    require(.65 <= plan["seconds"] <= 600, "Transition outside native range")


def validate_rois(rois):
    require(isinstance(rois, dict) and 0 < len(rois) <= 16, "Supply 1-16 named pixel regions")
    for name, box in rois.items():
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name), "Invalid region name")
        require(isinstance(box, list) and len(box) == 4 and all(type(v) is int for v in box), "Regions are [x0,y0,x1,y1] integer pixels")
        require(0 <= box[0] < box[2] and 0 <= box[1] < box[3], "Empty or negative region")


def depth_regions(frame, rois):
    """Optical-frame range summaries only; no object identity or robot transform."""
    depth = frame.get("depth", {})
    require(depth.get("format") == "uint16_little_endian_millimeters", "Unsupported depth raster")
    width, height = depth["width"], depth["height"]
    require(width == frame["width"] and height == frame["height"], "RGB/depth dimensions differ")
    raw = base64.b64decode(depth["base64"], validate=True)
    require(len(raw) == 2 * width * height, "Truncated depth raster")
    k = frame["intrinsics"]
    require(all(number(k[v]) for v in ("fx", "fy", "cx", "cy")) and min(k["fx"], k["fy"]) > 0, "Invalid intrinsics")
    output = {}
    for name, (x0, y0, x1, y1) in rois.items():
        require(x1 <= width and y1 <= height, "Region outside image")
        samples = [struct.unpack_from("<H", raw, (y * width + x) * 2)[0]
                   for y in range(y0, y1) for x in range(x0, x1)]
        good = sorted(v for v in samples if v > 0)
        item = {"pixels": [x0, y0, x1, y1], "valid_fraction": len(good) / len(samples),
                "object_identity_verified": False}
        if len(good) >= 5 and item["valid_fraction"] >= .5:
            median = statistics.median(good)
            item.update(median_m=median / 1000,
                        p10_m=good[int((len(good)-1)*.1)] / 1000,
                        p90_m=good[int((len(good)-1)*.9)] / 1000,
                        median_absolute_deviation_m=statistics.median(abs(x-median) for x in good) / 1000,
                        optical_xyz_m=[((x0+x1-1)/2-k["cx"])*median/1000/k["fx"],
                                       ((y0+y1-1)/2-k["cy"])*median/1000/k["fy"], median/1000])
        else:
            item["unavailable"] = "Insufficient valid depth; no substituted distance"
        output[name] = item
    return output


def body_context(status):
    neck, torso, nav = status["neck"], status["torso"], status["navigation"]
    require(neck.get("known") and torso.get("has_software_reference"), "Body observation unavailable")
    return {"neck": [neck[k] for k in ("pan", "lower", "upper")],
            "torso_count": torso["count"], "front_count": torso["front_count"],
            "pose": [nav[k] for k in ("x_m", "y_m", "yaw_radians")],
            "pose_fresh":nav.get("pose_fresh", False),
            "gateway_generation": status["gateway"]["sessionGeneration"]}


def same_context(a, b):
    # Optical-frame statistics do not use the SLAM transform. A localization
    # update is logged, not misclassified as measured physical body motion.
    return (a["neck"] == b["neck"] and a["front_count"] == b["front_count"]
            and a["gateway_generation"] == b["gateway_generation"]
            and abs(a["torso_count"]-b["torso_count"]) <= 2)


def arm_check(status, plan, maximum_age_ms, initial=False):
    for side in ("left", "right"):
        arm = status["arms"][side]
        require(arm["available"] and 0 <= arm["age_ms"] <= maximum_age_ms
                and arm["modes"] == [2]*7, f"{side} feedback or position hold unavailable")
        require(len(arm["q_radians"]) == 7 and all(number(q) for q in arm["q_radians"]), "Invalid joint feedback")
        for j, q in enumerate(arm["q_radians"], 1):
            key = f"arm.{side}.j{j}"
            start, end = plan["baseline"][key], plan["values"].get(key, plan["baseline"][key])
            if initial:
                require(abs(q-start) <= .02, "Reviewed starting pose changed")
            else:
                require(min(start, end)-.04 <= q <= max(start, end)+.04, f"{key} left reviewed interval")


def prepare(plan, rois, output, *, request=cerebroctl.request, maximum_age_ms=350,
            frame_interval=.5, final_timeout=3):
    validate_plan(plan); validate_rois(rois)
    require(50 <= maximum_age_ms <= 1200, "Observation budget outside 50-1200 ms")
    require(.25 <= frame_interval <= 2, "Depth rate outside 0.5-4 Hz")
    output = Path(output).expanduser()
    output.mkdir(parents=True, exist_ok=False)
    start = time.monotonic()
    log = output / "events.jsonl"

    def event(kind, **values):
        with log.open("a") as f:
            f.write(json.dumps(dict(kind=kind, unix_ms=time.time()*1000,
                                   elapsed_s=time.monotonic()-start, **values), allow_nan=False)+"\n")

    def rpc(op, params=None, **kwargs):
        reply = request(op, params, **kwargs)
        require(reply.get("ok"), f"{op}: {reply.get('error')}")
        return reply

    first = rpc("status")
    session, state = first["session"], first["result"]
    require(not state["motion"]["running"] and not state["mission"]["active"], "Motion or mission already active")
    require(state["gateway"].get("exclusiveControllerSession"), "Gateway ownership unavailable")
    arm_check(state, plan, maximum_age_ms, initial=True)
    context = body_context(state)
    event("context", session=session, body=context, baseline=plan["baseline"])

    def observe():
        began = time.monotonic()
        while True:
            reply = request("camera.frame", {"camera":"front", "depth":True, "maximum_age_ms":maximum_age_ms}, timeout=2)
            if reply.get("ok"):
                break
            # A shared video recorder can be encoding a JPEG. Retry this
            # read-only observation within a bound; never replay a motor RPC.
            require("Snapshot encoder busy" in str(reply.get("error")) and time.monotonic()-began < 1.2,
                    f"camera.frame: {reply.get('error')}")
            time.sleep(.03)
        fetched = time.monotonic()
        require(reply["session"] == session, "Camera app session changed")
        frame = reply["result"]
        require(frame["timestamp_kind"] == "sensor_capture" and 0 <= frame["age_ms"] <= maximum_age_ms, "Camera exposure stale")
        result = {"captured_at_ms":frame["captured_at_ms"], "stream_id":frame["stream_id"],
                  "age_ms":frame["age_ms"], "received_at_ms":time.time()*1000,
                  "regions":depth_regions(frame, rois),
                  "fetch_s":fetched-began, "depth_processing_s":time.monotonic()-fetched,
                  "processing_s":time.monotonic()-began, "robot_registration_verified":False}
        return reply, result

    # Check the selected view once before moving. Subsequent encoding and depth
    # statistics overlap the controller's trajectory, not another arm command.
    _, initial = observe()
    latest = rpc("status")
    require(latest["session"] == session and same_context(context, body_context(latest["result"])), "Preparation context changed")
    require(not latest["result"]["motion"]["running"] and not latest["result"]["mission"]["active"], "Control became busy")
    arm_check(latest["result"], plan, maximum_age_ms, initial=True)
    operation = str(uuid.uuid4())
    worker = ThreadPoolExecutor(max_workers=1)
    future = None
    final = None
    final_at = None
    next_frame = 0
    measured_complete = False
    try:
        event("dispatch", operation="motion.move", parameters={k:plan[k] for k in ("values", "seconds")})
        accepted = rpc("motion.move", {k:plan[k] for k in ("values", "seconds")},
                       session=session, request_id=operation)
        require(accepted["result"]["operation_id"].lower() == operation.lower(), "Operation ID mismatch")
        deadline = time.monotonic()+plan["seconds"]+12
        while True:
            now = time.monotonic()
            reply = rpc("status", timeout=2)
            require(reply["session"] == session, "App session changed; old target not replayed")
            state = reply["result"]
            require(state["motion"]["id"].lower() == operation.lower(), "Motion ownership changed")
            current_context = body_context(state)
            require(same_context(context, current_context), "Neck, torso reference or gateway changed; discard depth")
            require(state["gateway"].get("exclusiveControllerSession"), "Gateway ownership lost")
            arm_check(state, plan, maximum_age_ms)
            event("feedback", motion=state["motion"], arms=state["arms"], body=current_context)
            if not state["motion"]["running"] and final_at is None:
                require(state["motion"]["detail"].startswith("Sequence complete"), state["motion"]["detail"])
                for key, target in plan["values"].items():
                    _, side, joint = key.split(".")
                    require(abs(state["arms"][side]["q_radians"][int(joint[1:])-1]-target) <= .04, "Endpoint did not arrive")
                measured_complete = True
                final_at = time.time()*1000
                deadline = now+final_timeout
                event("motion_complete", operation_id=operation)
            if future is not None and future.done():
                frame_reply, sample = future.result()
                require(sample["stream_id"] == initial["stream_id"], "Camera stream changed; discard depth")
                require(sample["age_ms"]+max(0, time.time()*1000-sample["received_at_ms"]) <= maximum_age_ms,
                        "Depth result expired while processing")
                event("depth", during_motion=final_at is None, **sample)
                # Moving-arm depth remains provisional: a gripper may occlude a
                # can. A fresh exposure after measured arrival is the handoff.
                if final_at is not None and sample["captured_at_ms"] >= final_at:
                    final = (frame_reply, sample)
                    break
                future = None
            require(now <= deadline, "Preparation or post-arrival observation timed out")
            if future is None and now >= next_frame:
                future = worker.submit(observe)
                next_frame = now+frame_interval
            time.sleep(.1)
        saved = cerebroctl.save_frame(final[0], output / "final-frame")
        result = {"motion_complete":True, "operation_id":operation, "elapsed_s":time.monotonic()-start,
                  "context":context, "final_context":current_context,
                  "final_observation":final[1], "frame":saved["result"],
                  "next_motion_dispatched":False, "grasp_verified":False}
        (output/"result.json").write_text(json.dumps(result, indent=2, allow_nan=False)+"\n")
        event("complete", operation_id=operation)
        return result
    except BaseException as error:
        def emergency_event(kind, **values):
            try:
                event(kind, **values)
            except OSError:
                pass  # A full disk must not prevent the best-effort Stop.
        emergency_event("failed", reason=str(error), command_retried=False, motion_complete=measured_complete)
        # Stop only our still-active operation. A human takeover must not be
        # replaced by an old task's Stop, and an uncertain reply is never replayed.
        try:
            current = request("status", timeout=2)
            motion = current.get("result", {}).get("motion", {})
            if current.get("session") == session and motion.get("running") and (
                    str(motion.get("id")).lower() == operation.lower()):
                emergency_event("stop", reply=request("stop", session=session, timeout=2))
        except Exception as stop_error:
            emergency_event("stop_unconfirmed", reason=str(stop_error))
        raise
    finally:
        worker.shutdown(wait=True, cancel_futures=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--regions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--maximum-age-ms", type=float, default=350)
    args = parser.parse_args()
    try:
        result = prepare(json.loads(args.plan.read_text()), json.loads(args.regions.read_text()),
                         args.output, maximum_age_ms=args.maximum_age_ms)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0
    except Exception as error:
        print(json.dumps({"ok":False, "error":str(error), "command_retried":False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
