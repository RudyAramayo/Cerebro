#!/usr/bin/env python3
"""Supervised Luxonis RGB-D service for Cerebro.

The service intentionally runs outside the Cerebro process.  It owns the
DepthAI device connection, aligns depth to the RGB stream, and sends framed
RGB-D messages to one local Unix-domain-socket client at a time.  Device and
SDK failures are reported and retried instead of terminating the service.
"""

import argparse
from contextlib import contextmanager
from collections import deque
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import math
import time
import os
import select
import signal
import socket
import stat
import struct
import sys
import threading
import tempfile


def verified_running_service_source_sha256(running_module_code, source_path):
    """Hash source only if it compiles to this executing module's code.

    Read once at startup. An atomic app replacement after startup cannot stamp
    its newer source hash onto frames from an older, still-running worker.
    """
    with open(source_path, "rb") as source_file:
        source = source_file.read()
    compiled = compile(source, running_module_code.co_filename, "exec",
                       dont_inherit=True, optimize=sys.flags.optimize)
    if compiled != running_module_code:
        raise RuntimeError("Camera service source changed before running-code provenance was verified")
    return hashlib.sha256(source).hexdigest()


RUNNING_SERVICE_SOURCE_SHA256 = verified_running_service_source_sha256(
    sys._getframe().f_code, __file__)
RGB_OUTPUT_UNDISTORTED = True
PROTOCOL_MAGIC = b"CDP1"
PROTOCOL_VERSION = 2
FRAME_SIZE = (640, 400)
FRAME_RATE = 30.0
DEVICE_RECONNECT_ATTEMPTS = 3
INITIAL_RETRY_DELAY_SECONDS = 0.5
MAX_RETRY_DELAY_SECONDS = 8.0
QUEUE_WAIT = timedelta(milliseconds=500)
SYNC_THRESHOLD = timedelta(milliseconds=20)
CLIENT_SEND_TIMEOUT_SECONDS = 5.0
IMU_DISABLED_AFTER_START_FAILURE = set()
RUNTIME_STEREO_PROFILE_CACHE = {}


def calibration_json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("utf-8")


def calibration_semantic_value(value):
    """Camera table order is not significant in SDK CalibrationHandler JSON."""
    result = json.loads(json.dumps(value, allow_nan=False))
    rows = result.get("cameraData")
    if (not isinstance(rows, list) or any(not isinstance(row, list) or len(row) != 2 or type(row[0]) is not int for row in rows)
            or len({row[0] for row in rows}) != len(rows)):
        raise ValueError("invalid calibration camera socket table")
    result["cameraData"] = {str(row[0]): row[1] for row in rows}
    return result


def calibration_semantic_sha256(value):
    return hashlib.sha256(calibration_json_bytes(calibration_semantic_value(value))).hexdigest()


def calibration_changed_leaves(before, after, path=""):
    if isinstance(before, dict) and isinstance(after, dict):
        return [p for key in sorted(set(before) | set(after))
                for p in calibration_changed_leaves(before.get(key), after.get(key), path + "/" + key)]
    if isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        return [p for index, (a, b) in enumerate(zip(before, after))
                for p in calibration_changed_leaves(a, b, path + "/" + str(index))]
    return [] if before == after else [path]


def checked_sha256(value):
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError("expected lowercase SHA256")
    return value


def read_pinned_runtime_json(path, expected_hash, maximum_bytes=1024 * 1024):
    checked_sha256(expected_hash)
    if not isinstance(path, str) or not os.path.isabs(path):
        raise ValueError("runtime calibration evidence path must be absolute")
    with open(path, "rb") as source:
        encoded = source.read(maximum_bytes + 1)
    if len(encoded) > maximum_bytes or hashlib.sha256(encoded).hexdigest() != expected_hash:
        raise ValueError("runtime calibration evidence size/hash mismatch")
    value = json.loads(encoded)
    if not isinstance(value, dict):
        raise ValueError("runtime calibration evidence must be a JSON object")
    return value


def load_runtime_stereo_profile(role, activation_path=None):
    """Freeze activation bytes once per worker; changing a pointer needs restart."""
    path = activation_path or os.path.join(ir_status_directory(), "RuntimeStereoCalibration", role + "-active.json")
    cache_key = (role, path)
    if cache_key in RUNTIME_STEREO_PROFILE_CACHE:
        return RUNTIME_STEREO_PROFILE_CACHE[cache_key]
    result = {"status": "missing", "detail": "no runtime stereo profile override", "profile": None}
    try:
        with open(path, "rb") as source:
            encoded = source.read(8193)
        if len(encoded) > 8192:
            raise ValueError("runtime activation exceeds size bound")
        activation = json.loads(encoded)
        if (not isinstance(activation, dict) or type(activation.get("schemaVersion")) is not int or activation.get("schemaVersion") != 1 or activation.get("kind") != "runtime_stereo_calibration_activation"
                or activation.get("cameraRole") != role or role not in ("face", "belly")):
            raise ValueError("runtime activation schema/role mismatch")
        profile_hash = checked_sha256(activation.get("profileSHA256"))
        profile = read_pinned_runtime_json(activation.get("profilePath"), profile_hash, 65536)
        if (type(profile.get("schemaVersion")) is not int or profile.get("schemaVersion") != 1 or profile.get("kind") != "runtime_stereo_calibration_profile"
                or profile.get("cameraRole") != role or profile.get("platform") != "RVC2"
                or profile.get("sdkVersion") != "3.8.0"):
            raise ValueError("runtime stereo profile schema/platform/SDK mismatch")
        mxid = profile.get("actualDeviceMXID")
        if not isinstance(mxid, str) or not mxid or mxid.strip() != mxid or any(c in mxid for c in "\r\n"):
            raise ValueError("runtime stereo profile device identity missing")
        for key in ("factoryEEPROMSHA256", "requestedCalibrationSHA256", "requestedCalibrationSemanticSHA256", "candidateSHA256", "validationEvidenceSHA256"):
            checked_sha256(profile.get(key))
        requested = read_pinned_runtime_json(profile.get("requestedCalibrationPath"), profile["requestedCalibrationSHA256"])
        if calibration_semantic_sha256(requested) != profile["requestedCalibrationSemanticSHA256"]:
            raise ValueError("requested runtime calibration semantic hash mismatch")
        # Pin commissioning evidence bytes without promoting its local metrics to
        # global camera registration or arm authority.
        read_pinned_runtime_json(profile.get("validationEvidencePath"), profile["validationEvidenceSHA256"])
        result = {"status": "candidate", "detail": "pinned runtime stereo profile loaded", "profile": profile,
                  "profileSHA256": profile_hash, "requestedCalibration": requested}
    except FileNotFoundError:
        if os.path.lexists(path):
            result = {"status": "invalid", "detail": "runtime profile evidence missing; no profile override", "profile": None}
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {"status": "invalid", "detail": "runtime profile rejected; no profile override: " + str(error)[:400], "profile": None}
    RUNTIME_STEREO_PROFILE_CACHE[cache_key] = result
    return result


def checked_rotation(value):
    if not isinstance(value, list) or len(value) != 3 or any(not isinstance(row, list) or len(row) != 3 for row in value):
        raise ValueError("runtime rotation must be 3x3")
    if any(type(x) not in (int, float) or not math.isfinite(x) for row in value for x in row):
        raise ValueError("runtime rotation must be finite")
    for a in range(3):
        for b in range(3):
            if abs(sum(value[k][a] * value[k][b] for k in range(3)) - (1 if a == b else 0)) > 1e-4:
                raise ValueError("runtime rotation is not orthonormal")
    a, b, c = value
    determinant = a[0]*(b[1]*c[2]-b[2]*c[1]) - a[1]*(b[0]*c[2]-b[2]*c[0]) + a[2]*(b[0]*c[1]-b[1]*c[0])
    if abs(determinant - 1) > 1e-4:
        raise ValueError("runtime rotation must be proper")
    return value


def checked_rotation_delta(before, after):
    checked_rotation(before); checked_rotation(after)
    cosine = (sum(before[r][c] * after[r][c] for r in range(3) for c in range(3)) - 1) / 2
    if math.acos(max(-1.0, min(1.0, cosine))) > math.radians(5):
        raise ValueError("runtime rotation correction exceeds commissioning bound")


def validate_runtime_calibration_changes(factory, requested):
    before, after = calibration_semantic_value(factory), calibration_semantic_value(requested)
    for value in (before, after):
        cameras = value["cameraData"]
        if (set(cameras) != {"0", "1", "2"} or cameras["1"]["extrinsics"]["toCameraSocket"] != 2
                or cameras["2"]["extrinsics"]["toCameraSocket"] != 0
                or cameras["0"]["extrinsics"]["toCameraSocket"] != -1
                or value["stereoRectificationData"]["leftCameraSocket"] != 1
                or value["stereoRectificationData"]["rightCameraSocket"] != 2):
            raise ValueError("runtime calibration requires the original B→C→A graph")
    changes = calibration_changed_leaves(before, after)
    prefixes = ("/cameraData/1/extrinsics/rotationMatrix/", "/cameraData/1/extrinsics/translation/",
                "/stereoRectificationData/rectifiedRotationLeft/", "/stereoRectificationData/rectifiedRotationRight/")
    if (not changes or len(changes) > 30 or any(not any(p.startswith(prefix) for prefix in prefixes) for p in changes)
            or any(not any(p.startswith(prefix) for p in changes) for prefix in prefixes)):
        raise ValueError("runtime calibration changes fields outside approved B→C R/T and R1/R2")
    old, new = before["cameraData"]["1"]["extrinsics"], after["cameraData"]["1"]["extrinsics"]
    checked_rotation_delta(old["rotationMatrix"], new["rotationMatrix"])
    for key in ("rectifiedRotationLeft", "rectifiedRotationRight"):
        checked_rotation_delta(before["stereoRectificationData"][key], after["stereoRectificationData"][key])
    if new["lengthUnit"] != 1 or old["lengthUnit"] != 1:
        raise ValueError("runtime calibration translation must remain centimeters")
    old_t, new_t = ([v["translation"][axis] for axis in ("x", "y", "z")] for v in (old, new))
    if any(type(x) not in (int, float) or not math.isfinite(x) for x in old_t + new_t):
        raise ValueError("runtime translation must be finite")
    if not 3 < math.sqrt(sum(x*x for x in new_t)) < 20 or math.sqrt(sum((a-b)**2 for a,b in zip(old_t,new_t))) > .5:
        raise ValueError("runtime translation correction exceeds commissioning bound")
    # The stored rotations must rectify this same raw pair, rather than an
    # unrelated proper rotation that happened to pass the numeric bounds.
    r1 = after["stereoRectificationData"]["rectifiedRotationLeft"]
    r2 = after["stereoRectificationData"]["rectifiedRotationRight"]
    rectified_r = [[sum(r2[r][k] * new["rotationMatrix"][k][j] * r1[c][j]
                       for k in range(3) for j in range(3)) for c in range(3)] for r in range(3)]
    rectified_t = [sum(r2[r][k] * new_t[k] for k in range(3)) for r in range(3)]
    if (any(abs(rectified_r[r][c] - (1 if r == c else 0)) > .001 for r in range(3) for c in range(3))
            or rectified_t[0] >= -3 or any(abs(x) > .01 for x in rectified_t[1:])):
        raise ValueError("runtime R1/R2 do not rectify the approved raw stereo pair")
    return changes


def clone_runtime_calibration(factory, requested, dai):
    changes = validate_runtime_calibration_changes(factory, requested)
    values = calibration_semantic_value(requested)
    edge = values["cameraData"]["1"]["extrinsics"]
    clone = dai.CalibrationHandler.fromJson(factory, validateExtrinsics=True)
    clone.setCameraExtrinsics(dai.CameraBoardSocket.CAM_B, dai.CameraBoardSocket.CAM_C,
        edge["rotationMatrix"], [edge["translation"][key] for key in ("x", "y", "z")],
        [edge["specTranslation"][key] for key in ("x", "y", "z")])
    clone.setStereoLeft(dai.CameraBoardSocket.CAM_B, values["stereoRectificationData"]["rectifiedRotationLeft"])
    clone.setStereoRight(dai.CameraBoardSocket.CAM_C, values["stereoRectificationData"]["rectifiedRotationRight"])
    if calibration_semantic_value(clone.eepromToJson()) != values:
        raise ValueError("SDK runtime clone differs from pinned requested calibration")
    dai.CalibrationHandler.fromJson(clone.eepromToJson(), validateExtrinsics=True)
    return clone, changes


@contextmanager
def runtime_stereo_calibration_session(device, pipeline, dai, role, factory, loaded):
    """RAM-only override and verified restoration BEFORE Pipeline closes Device."""
    factory_json = factory.eepromToJson()
    factory_hash = hashlib.sha256(calibration_json_bytes(factory_json)).hexdigest()
    prior = device.getCalibration()
    prior_json = prior.eepromToJson()
    state = {"factoryEEPROMSHA256": factory_hash, "factorySemanticSHA256": calibration_semantic_sha256(factory_json), "priorEffectiveCalibration": prior_json,
             "attempted": False, "applied": False, "profile": None, "status": loaded["status"], "detail": loaded["detail"]}
    state["calibrationSource"] = ("FACTORY" if calibration_semantic_value(prior_json) == calibration_semantic_value(factory_json)
                                  else "OBSERVED_EXISTING_RUNTIME")
    clone = None
    try:
        if loaded["profile"] is not None:
            try:
                profile = loaded["profile"]
                if (profile["actualDeviceMXID"] != device.getMxId() or profile["cameraRole"] != role
                        or str(device.getPlatform()) != "Platform.RVC2" or str(dai.__version__) != profile["sdkVersion"]
                        or factory_hash != profile["factoryEEPROMSHA256"]):
                    raise ValueError("runtime profile does not match actual device/role/SDK/factory EEPROM")
                if calibration_semantic_value(prior_json) != calibration_semantic_value(factory_json):
                    raise ValueError("prior effective RAM calibration differs from profile factory scope")
                clone, changes = clone_runtime_calibration(factory_json, loaded["requestedCalibration"], dai)
                state.update(profile=profile, profileSHA256=loaded["profileSHA256"], intendedDiffPaths=changes)
            except (ValueError, TypeError, KeyError, RuntimeError) as error:
                state.update(status="invalid", detail="runtime profile rejected before apply; existing runtime preserved: " + str(error)[:400], profile=None)
        emit("CEREBRO_DEPTHCAM_RUNTIME_PROFILE " + json.dumps({"role": role, "status": state["status"],
            "calibrationSource": state["calibrationSource"], "detail": state["detail"]}, separators=(",", ":")))
        if clone is not None:
            state["attempted"] = True  # A partially failing apply must also restore.
            pipeline.setCalibrationData(clone)
        yield state
    finally:
        if state["attempted"]:
            errors = []
            try:
                device.setCalibration(prior)
            except BaseException as error:
                errors.append("setCalibration: " + str(error)[:300])
            try:
                restored = device.getCalibration().eepromToJson()
                state["restoredEffectiveRuntimeCalibrationSHA256"] = calibration_semantic_sha256(restored)
                if calibration_semantic_value(restored) != calibration_semantic_value(prior_json):
                    errors.append("restored effective RAM calibration differs from prior effective RAM")
            except BaseException as error:
                errors.append("restored getCalibration: " + str(error)[:300])
            try:
                after = device.readCalibration2().eepromToJson()
                state["restoredFactoryEEPROMSHA256"] = hashlib.sha256(calibration_json_bytes(after)).hexdigest()
                if state["restoredFactoryEEPROMSHA256"] != factory_hash:
                    errors.append("EEPROM changed unexpectedly")
            except BaseException as error:
                errors.append("restored readCalibration2: " + str(error)[:300])
            emit("CEREBRO_DEPTHCAM_RUNTIME_RESTORE " + json.dumps({"role": role, "verified": not errors,
                "restoredEffectiveRuntimeCalibrationSHA256": state.get("restoredEffectiveRuntimeCalibrationSHA256"),
                "factoryEEPROMSHA256": state.get("restoredFactoryEEPROMSHA256"), "errors": errors}, separators=(",", ":")))
            if errors:
                raise RuntimeError("runtime calibration restoration failed: " + "; ".join(errors))


def runtime_stereo_policy(pipeline, stereo, dai, profile_applied):
    auto_mode = pipeline.getAutoCalibrationMode()
    if auto_mode != dai.Pipeline.AutoCalibrationMode.OFF:
        raise RuntimeError("camera runtime auto-calibration was not confirmed OFF")
    graph = pipeline.serializeToJson(False)
    if isinstance(graph, str):
        graph = json.loads(graph)
    matches = []
    def visit(value):
        if isinstance(value, dict):
            if "useHomographyRectification" in value and "disparityToDepthUseSpecTranslation" in value:
                matches.append(value)
            for child in value.values(): visit(child)
        elif isinstance(value, list):
            for child in value: visit(child)
    visit(graph)
    if len(matches) != 1:
        raise RuntimeError("actual HOST StereoDepth configuration is unavailable/ambiguous")
    properties = matches[0]
    if profile_applied and any(properties.get(key) is not False for key in
            ("disparityToDepthUseSpecTranslation", "rectificationUseSpecTranslation", "depthAlignmentUseSpecTranslation")):
        raise RuntimeError("runtime profile HOST calibrated-translation policies were not confirmed")
    return {"schemaVersion": 1, "source": "actual_host_configuration_not_firmware_resolved_strategy",
            "autoCalibrationMode": str(auto_mode), "stereoMode": observed_stereo_configuration(stereo),
            "stereoDepthProperties": properties}


def runtime_calibration_identity(value):
    keys = ("actualDeviceMXID", "cameraRole", "sdkVersion", "factoryEEPROMSHA256",
            "effectiveRuntimeCalibrationSHA256", "stereoPolicySHA256", "candidateSHA256", "profileSHA256")
    if not isinstance(value, dict) or set(value) != {"schemaVersion", *keys} or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("runtime calibration provenance schema mismatch")
    for key in keys[:3]:
        item = value[key]
        if not isinstance(item, str) or not item or item.strip() != item or any(c in item for c in "\r\n"):
            raise ValueError("runtime calibration provenance identity missing")
    if value["cameraRole"] not in ("face", "belly"):
        raise ValueError("runtime calibration role invalid")
    for key in keys[3:]:
        if value[key] is None and key in ("candidateSHA256", "profileSHA256"):
            continue
        checked_sha256(value[key])
    if (value["candidateSHA256"] is None) != (value["profileSHA256"] is None):
        raise ValueError("runtime candidate/profile provenance must be present together")
    encoded = "\n".join(["runtime-camera-calibration-v1"] + [value[key] if value[key] is not None else "-" for key in keys])
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def finalize_runtime_calibration(state, device, pipeline, stereo, dai, role):
    effective = device.getCalibration().eepromToJson()
    if state["attempted"]:
        if calibration_semantic_sha256(effective) != state["profile"]["requestedCalibrationSemanticSHA256"]:
            raise RuntimeError("effective RAM readback differs from requested runtime calibration")
        state["applied"] = True
        state["calibrationSource"] = "RUNTIME_PROFILE"
    else:
        state["calibrationSource"] = ("FACTORY" if calibration_semantic_sha256(effective) == state["factorySemanticSHA256"] else "OBSERVED_EXISTING_RUNTIME")
    policy = runtime_stereo_policy(pipeline, stereo, dai, state["applied"])
    value = {"schemaVersion": 1, "actualDeviceMXID": device.getMxId(), "cameraRole": role,
        "sdkVersion": str(dai.__version__), "factoryEEPROMSHA256": state["factoryEEPROMSHA256"],
        "effectiveRuntimeCalibrationSHA256": calibration_semantic_sha256(effective),
        "stereoPolicySHA256": hashlib.sha256(calibration_json_bytes(policy)).hexdigest(),
        "candidateSHA256": state["profile"]["candidateSHA256"] if state["applied"] else None,
        "profileSHA256": state["profileSHA256"] if state["applied"] else None}
    runtime_calibration_identity(value)
    state.update(effectiveRuntimeCalibration=effective, stereoPolicy=policy, provenance=value)
    emit("CEREBRO_DEPTHCAM_RUNTIME_CALIBRATION " + json.dumps({"provenance": value,
        "identity": runtime_calibration_identity(value), "profileApplied": state["applied"],
        "calibrationSource": state["calibrationSource"],
        "metricAccuracyVerified": False, "registrationVerified": False}, separators=(",", ":")))
    return value


def emit(line):
    print(line, flush=True)


def emit_error(message):
    # Status records are line-oriented, so keep SDK messages on one line.
    text = " ".join(str(message).split()) or "unknown error"
    emit("CEREBRO_DEPTHCAM_ERROR " + text)


def normalized_ir_intensity(argument):
    try:
        if isinstance(argument, bool):
            raise ValueError("boolean is not an intensity")
        value = float(argument)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("IR dot intensity must be a finite number from 0 to 1")
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        raise argparse.ArgumentTypeError("IR dot intensity must be a finite number from 0 to 1")
    return value


def ir_dot_intensity_for_role(role, requested=None):
    if role not in ("face", "belly"):
        raise ValueError("IR configuration requires a face or belly camera role")
    value = (0.5 if role == "face" else 0.0) if requested is None else normalized_ir_intensity(requested)
    if role == "belly" and value != 0.0:
        raise ValueError("nonzero --ir-dot-intensity is supported only for the face camera; belly IR remains off")
    return value


def ir_status_directory():
    return os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Cerebro", "DepthCamera")


def write_ir_status(status):
    """Persist only the last SDK configuration result, never image evidence."""
    temporary_path = None
    try:
        role = status["role"]
        if role not in ("face", "belly"):
            raise ValueError("invalid IR status role")
        directory = ir_status_directory()
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        descriptor, temporary_path = tempfile.mkstemp(prefix="." + role + "-ir-status-", suffix=".json", dir=directory)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(status, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, os.path.join(directory, role + "-ir-status.json"))
        temporary_path = None
        return True
    except (OSError, ValueError, TypeError, KeyError) as error:
        emit_error("IR diagnostic status could not be saved: " + str(error))
        return False
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def write_calibration_evidence(device, calibration, dai, role, frame_size, mono_size,
                               requested_mxid=None, requested_stereo_mode="standard", runtime_state=None):
    """Read existing calibration once; never configure or write the device.

    SDK metadata is evidence of what was returned, not physical metric accuracy
    or proof of the firmware's resolved rectification/baseline strategy.
    """
    partial_path = pointer_temporary = None
    try:
        if role not in ("face", "belly"):
            raise ValueError("invalid calibration evidence role")

        def observe(owner, method, *args, _string_result=False, **kwargs):
            getter = getattr(owner, method, None)
            if not callable(getter):
                return {"status": "unavailable", "method": method}
            try:
                value = getter(*args, **kwargs)
                if _string_result:
                    value = str(value)
                value = json.loads(json.dumps(value, allow_nan=False))
                return {"status": "observed", "method": method, "value": value}
            except Exception as error:
                return {"status": "error", "method": method, "detail": " ".join(str(error).split())}

        mxid = observe(device, "getMxId")
        actual_mxid = mxid.get("value")
        if not isinstance(actual_mxid, str) or not actual_mxid:
            actual_mxid = None
        try:
            rgb_socket = color_camera_socket(device, dai)
            rgb_socket_observation = {"status": "observed", "value": str(rgb_socket)}
        except Exception as error:
            rgb_socket = None
            rgb_socket_observation = {"status": "error", "detail": " ".join(str(error).split())}
        sockets = [("rgb", rgb_socket), ("left", getattr(dai.CameraBoardSocket, "CAM_B", None)),
                   ("right", getattr(dai.CameraBoardSocket, "CAM_C", None))]
        cameras = []
        for name, camera_socket in sockets:
            record = {"name": name, "socket": str(camera_socket) if camera_socket is not None else None}
            if camera_socket is not None:
                size = frame_size if name == "rgb" else mono_size
                record.update(defaultIntrinsics=observe(calibration, "getDefaultIntrinsics", camera_socket),
                    eepromIntrinsicsAtRequestedSize={"requestedSize": list(size), "keepAspectRatio": True,
                        **observe(calibration, "getCameraIntrinsics", camera_socket, *size, keepAspectRatio=True)},
                    sourceDistortionCoefficients=observe(calibration, "getDistortionCoefficients", camera_socket),
                    eepromLensPosition=observe(calibration, "getLensPosition", camera_socket),
                    calibratedFovDegrees=observe(calibration, "getFov", camera_socket, False),
                    specificationFovDegrees=observe(calibration, "getFov", camera_socket, True))
                getter = getattr(calibration, "getDistortionModel", None)
                try:
                    record["sourceDistortionModel"] = {"status": "observed", "value": str(getter(camera_socket))} if callable(getter) else {"status": "unavailable"}
                except Exception as error:
                    record["sourceDistortionModel"] = {"status": "error", "detail": " ".join(str(error).split())}
            cameras.append(record)
        unit = getattr(getattr(dai, "LengthUnit", None), "METER", None)
        pairs = []
        for source, destination in [(sockets[1][1], sockets[2][1]), (sockets[1][1], rgb_socket), (sockets[2][1], rgb_socket)]:
            pair = {"fromSocket": str(source), "toSocket": str(destination), "translationUnit": "meter"}
            if unit is None or source is None or destination is None:
                pair.update(status="unavailable", detail="Explicit SDK meter unit or camera socket is unavailable")
            else:
                for label, use_spec in [("calibrated", False), ("specification", True)]:
                    pair[label] = {"useSpecTranslation": use_spec,
                        "baselineDistance": observe(calibration, "getBaselineDistance", source, destination, use_spec, unit),
                        "translationVector": observe(calibration, "getCameraTranslationVector", source, destination, use_spec, unit),
                        "extrinsics": observe(calibration, "getCameraExtrinsics", source, destination, use_spec, unit)}
            pairs.append(pair)
        stored = {}
        try:
            eeprom = calibration.getEepromData()
            for name in ("stereoEnableDistortionCorrection", "stereoUseSpecTranslation", "boardName", "boardRev", "productName", "deviceName"):
                value = getattr(eeprom, name, None)
                stored[name] = {"status": "unavailable"} if value is None else {"status": "observed", "value": value}
        except Exception as error:
            stored["readError"] = " ".join(str(error).split())
        document = {"schemaVersion": 1, "kind": "depth_camera_startup_calibration_evidence", "role": role,
            "timestampUTC": datetime.now(timezone.utc).isoformat(), "timestampUnixMilliseconds": time.time()*1000,
            "processID": os.getpid(), "parentProcessID": os.getppid(), "cameraServiceSourceSHA256": RUNNING_SERVICE_SOURCE_SHA256,
            "depthaiVersion": str(getattr(dai, "__version__", "unavailable")),
            "actualDeviceMXID": actual_mxid, "deviceMXIDObservation": mxid, "requestedDeviceMXID": requested_mxid,
            "rgbSocketSelection": rgb_socket_observation, "eepromExport": observe(calibration, "eepromToJson"),
            "storedEEPROMFields": stored, "cameras": cameras, "cameraPairs": pairs,
            "stereoLeftCameraID": observe(calibration, "getStereoLeftCameraId", _string_result=True),
            "stereoRightCameraID": observe(calibration, "getStereoRightCameraId", _string_result=True),
            "stereoLeftRectificationRotation": observe(calibration, "getStereoLeftRectificationRotation"),
            "stereoRightRectificationRotation": observe(calibration, "getStereoRightRectificationRotation"),
            "requestedPipeline": {"rgbSize": list(frame_size), "monoSize": list(mono_size),
                "rgbUndistortion": RGB_OUTPUT_UNDISTORTED, "monoUndistortion": False,
                "stereoMode": requested_stereo_mode, "rectificationPolicy": "explicit_mesh",
                "disparityToDepthUseSpecTranslation": "UNSET", "depthAlignmentUseSpecTranslation": "UNSET",
                "rectificationUseSpecTranslation": "UNSET", "resolvedStrategyObserved": False},
            "intrinsicsScope": "EEPROM/default and explicit requested-size queries only; actual processed frame K remains in per-frame packet metadata",
            "calibrationWrittenToDevice": False, "metricAccuracyVerified": False, "registrationVerified": False}
        if runtime_state is not None:
            provenance = runtime_state["provenance"]
            document.update(factoryEEPROMSHA256=provenance["factoryEEPROMSHA256"],
                effectiveRuntimeCalibrationExport={"status": "observed", "method": "getCalibration",
                    "value": runtime_state["effectiveRuntimeCalibration"],
                    "semanticSHA256": provenance["effectiveRuntimeCalibrationSHA256"]},
                priorEffectiveRuntimeCalibrationExport={"status": "observed", "method": "getCalibration",
                    "value": runtime_state["priorEffectiveCalibration"]},
                runtimeCalibration=provenance, runtimeCalibrationIdentity=runtime_calibration_identity(provenance),
                runtimeStereoPolicy=runtime_state["stereoPolicy"], runtimeProfileApplied=runtime_state["applied"],
                runtimeProfileStatus="applied" if runtime_state["applied"] else runtime_state["status"],
                runtimeCalibrationSource=runtime_state["calibrationSource"],
                calibrationWrittenToDevice=runtime_state["applied"],
                calibrationWriteScope="nonpersistent_RAM" if runtime_state["applied"] else "none", EEPROMWritten=False)
            properties = runtime_state["stereoPolicy"]["stereoDepthProperties"]
            for key in ("disparityToDepthUseSpecTranslation", "depthAlignmentUseSpecTranslation", "rectificationUseSpecTranslation"):
                document["requestedPipeline"][key] = properties.get(key)
            document["requestedPipeline"]["autoCalibrationMode"] = runtime_state["stereoPolicy"]["autoCalibrationMode"]
        encoded = (json.dumps(document, sort_keys=True, indent=2, allow_nan=False)+"\n").encode("utf-8")
        directory = ir_status_directory()
        evidence_directory = os.path.join(directory, "CalibrationEvidence")
        os.makedirs(evidence_directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700); os.chmod(evidence_directory, 0o700)
        descriptor, partial_path = tempfile.mkstemp(prefix=role+"-calibration-"+str(os.getpid())+"-", suffix=".json", dir=evidence_directory)
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o600); output.write(encoded); output.flush(); os.fsync(output.fileno())
        evidence_path = partial_path
        partial_path = None  # This unique completed evidence file is never replaced.
        pointer = {key: document[key] for key in ("schemaVersion", "role", "timestampUTC", "timestampUnixMilliseconds",
            "processID", "parentProcessID", "cameraServiceSourceSHA256", "depthaiVersion", "actualDeviceMXID")}
        pointer.update(evidencePath=evidence_path, evidenceSHA256=hashlib.sha256(encoded).hexdigest(),
            eepromExportStatus=document["eepromExport"]["status"])
        descriptor, pointer_temporary = tempfile.mkstemp(prefix="."+role+"-calibration-latest-", suffix=".json", dir=directory)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600); json.dump(pointer, output, sort_keys=True, indent=2, allow_nan=False)
            output.write("\n"); output.flush(); os.fsync(output.fileno())
        os.replace(pointer_temporary, os.path.join(directory, role+"-calibration-latest.json"))
        pointer_temporary = None
        emit("CEREBRO_DEPTHCAM_CALIBRATION role={} eeprom_export={} evidence={} sha256={}".format(
            role, pointer["eepromExportStatus"], evidence_path, pointer["evidenceSHA256"]))
        return pointer
    except Exception as error:
        emit_error("Calibration evidence could not be saved: " + str(error))
        return None
    finally:
        for path in (partial_path, pointer_temporary):
            if path is not None:
                try: os.unlink(path)
                except OSError: pass


def configure_ir_projectors(device, role, requested=None):
    """Use the SDK's normalized controls after pipeline.start().

    A successful SDK command is not proof of depth improvement. Non-Pro
    devices or unavailable SDK methods remain usable RGB-D sources and report
    the actual unsupported/rejected result instead of claiming an emitter.
    """
    intensity = ir_dot_intensity_for_role(role, requested)

    def apply(method_name, value):
        setter = getattr(device, method_name, None)
        if not callable(setter):
            return "unsupported_sdk"
        try:
            # DepthAI 3.8.0 documents a Bool return. None/other values must not
            # be mistaken for confirmed driver support or accepted settings.
            return "accepted" if setter(value) is True else "unavailable_or_rejected"
        except Exception as error:
            emit_error("IR {}: {}".format(method_name, error))
            return "error"

    # Keep the flood LED off on both cameras. The face-only dot pattern adds
    # stereo texture without enabling the belly projector/interference.
    flood_result = apply("setIrFloodLightIntensity", 0.0)
    dot_result = apply("setIrLaserDotProjectorIntensity", intensity)
    emit("CEREBRO_DEPTHCAM_IR role={} dot_requested={:.3f} dot_result={} flood_requested=0.000 flood_result={}".format(
        role, intensity, dot_result, flood_result
    ))
    accepted = dot_result == "accepted" and flood_result == "accepted"
    write_ir_status({
        "schemaVersion": 1,
        "timestampUTC": datetime.now(timezone.utc).isoformat(),
        "timestampUnixMilliseconds": time.time() * 1000,
        "processID": os.getpid(),
        "role": role,
        "dotRequested": intensity,
        "floodRequested": 0.0,
        "dotResult": dot_result,
        "floodResult": flood_result,
        "sdkAccepted": accepted,
        "depthImprovementVerified": False,
    })
    return accepted


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(
        description="Stream synchronized Luxonis RGB and aligned depth to Cerebro."
    )
    parser.add_argument(
        "--socket",
        required=True,
        dest="socket_path",
        help="Unix-domain socket path owned by this service.",
    )
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=os.getppid(),
        help="Cerebro process ID; the helper exits if this process disappears.",
    )
    parser.add_argument(
        "--mxid",
        type=str,
        default=None,
        help="Serial number (MxId) of the specific Luxonis device to connect to.",
    )
    parser.add_argument(
        "--role",
        type=str,
        default="face",
        choices=["face", "belly"],
        help="The camera service role (face or belly).",
    )
    parser.add_argument(
        "--model-name",
        type=str,
        default="chess",
        help="The active custom spatial model project name (e.g. chess, monopoly).",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=1280,
        help="Main video stream width.",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=720,
        help="Main video stream height.",
    )
    parser.add_argument(
        "--ir-dot-intensity",
        type=normalized_ir_intensity,
        default=None,
        help="Face-camera IR dot projector intensity, 0–1 (default 0.5); belly remains 0. Flood IR stays off.",
    )
    parser.add_argument(
        "--stereo-mode", choices=["standard", "near_field"], default="standard",
        help="Face calibration only: near_field enables extended disparity and disables subpixel; standard keeps the normal pipeline.",
    )
    args = parser.parse_args(argv)
    try:
        args.ir_dot_intensity = ir_dot_intensity_for_role(args.role, args.ir_dot_intensity)
        if args.stereo_mode=="near_field" and args.role!="face":
            raise ValueError("near_field stereo mode is supported only for face calibration")
    except ValueError as error:
        parser.error(str(error))
    return args


def configure_stereo_mode(stereo, requested):
    if requested not in ("standard", "near_field"):
        raise ValueError("invalid stereo mode")
    # Installed DepthAI3.8 documents these modes as mutually incompatible.
    # Leave the standard preset/extended-disparity behavior unchanged.
    if requested=="near_field":
        stereo.setSubpixel(False)
        stereo.setExtendedDisparity(True)
    else:
        stereo.setSubpixel(True)


def observed_stereo_configuration(stereo):
    """Read the SDK node's actual selected configuration, never the CLI value.

    No dynamic config input is connected. This is SDK initial-config readback,
    not a claim of measured depth improvement or device runtime telemetry.
    """
    result={"stereo_mode":None,"stereo_mode_source":None,
            "stereo_extended_disparity":None,"stereo_subpixel":None}
    try:
        config=getattr(stereo,"initialConfig",None)
        if config is None:
            return result
        for name,key in [("getExtendedDisparity","stereo_extended_disparity"),("getSubpixel","stereo_subpixel")]:
            getter=getattr(config,name,None)
            if not callable(getter):
                return result
            value=getter()
            if type(value) is not bool:
                return result
            result[key]=value
        result["stereo_mode_source"]="sdk_initial_config_readback"
        pair=(result["stereo_extended_disparity"],result["stereo_subpixel"])
        result["stereo_mode"]={(False,True):"standard",(True,False):"near_field"}.get(pair)
    except Exception as error:
        emit_error("Stereo configuration readback unavailable: "+str(error))
    return result


def validated_stereo_configuration(value):
    empty={"stereo_mode":None,"stereo_mode_source":None,
           "stereo_extended_disparity":None,"stereo_subpixel":None}
    if value is None:
        return empty
    if not isinstance(value,dict) or set(value)!=set(empty):
        raise RuntimeError("invalid stereo configuration metadata")
    if any(value[key] is not None and type(value[key]) is not bool for key in ("stereo_extended_disparity","stereo_subpixel")):
        raise RuntimeError("invalid stereo configuration booleans")
    if value["stereo_mode_source"] not in (None,"sdk_initial_config_readback"):
        raise RuntimeError("invalid stereo configuration source")
    pair=(value["stereo_extended_disparity"],value["stereo_subpixel"])
    if value["stereo_mode"] is not None and (value["stereo_mode_source"]!="sdk_initial_config_readback" or
            value["stereo_mode"]!={(False,True):"standard",(True,False):"near_field"}.get(pair)):
        raise RuntimeError("stereo mode lacks matching SDK configuration readback")
    return dict(value)


def normalized_socket_path(argument):
    # Make relative paths unambiguous without resolving macOS aliases such as
    # /tmp -> /private/tmp; the READY record must echo the caller's exact path.
    return os.path.abspath(os.path.expanduser(argument))


def remove_stale_socket(path):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return

    if not stat.S_ISSOCK(metadata.st_mode):
        raise RuntimeError("socket path exists and is not a socket: " + path)
    os.unlink(path)


def acquire_service_lock(socket_path):
    lock_path = socket_path + ".lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)

    # Try up to 5 times with a 0.5s delay to handle startup races with old shutting-down instances
    for attempt in range(6):
        descriptor = os.open(lock_path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except BlockingIOError as error:
            os.close(descriptor)
            if attempt < 5:
                import time
                time.sleep(0.5)
                continue
            raise RuntimeError("another DepthAI service already owns this socket") from error
        except BaseException:
            os.close(descriptor)
            raise


def release_service_lock(descriptor):
    if descriptor is None:
        return
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def create_server(path):
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        raise RuntimeError("socket directory does not exist: " + parent)

    remove_stale_socket(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    identity = None
    try:
        server.bind(path)
        owned = os.lstat(path)
        identity = (owned.st_dev, owned.st_ino)
        os.chmod(path, 0o600)
        server.listen(1)
        server.settimeout(1.0)
        return server, identity
    except BaseException:
        server.close()
        if identity is not None:
            remove_owned_socket(path, identity)
        raise


def remove_owned_socket(path, identity):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    if (
        stat.S_ISSOCK(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
    ):
        os.unlink(path)


def load_depthai():
    import depthai as dai

    if str(getattr(dai, "__version__", "")) != "3.8.0":
        raise RuntimeError(
            "DepthAI 3.8.0 is required; found "
            + str(getattr(dai, "__version__", "unknown"))
        )
    return dai


def color_camera_socket(device, dai):
    for feature in device.getConnectedCameraFeatures():
        if dai.CameraSensorType.COLOR in feature.supportedTypes:
            return feature.socket
    raise RuntimeError("connected Luxonis device has no color camera")


def timestamp_nanoseconds(frame):
    timestamp = frame.getTimestamp()
    return (
        timestamp.days * 86_400_000_000_000
        + timestamp.seconds * 1_000_000_000
        + timestamp.microseconds * 1_000
    )


def capture_time_milliseconds(frames, clock_now, wall_seconds):
    # getTimestamp() is synchronized to the SDK's host Clock. Convert in this
    # process instead of assuming Swift uptime has the same clock epoch.
    oldest = min(frame.getTimestamp() for frame in frames)
    age_seconds = (clock_now - oldest).total_seconds()
    if not math.isfinite(age_seconds) or age_seconds < 0:
        return None
    return (wall_seconds - age_seconds) * 1000


def configure_latest_input(node_input, size=2):
    # Bound every processing input, not only the final host output queue.
    # DepthAI 3.8 Node.Input uses setMaxSize (not the v2 setQueueSize).
    node_input.setMaxSize(size)
    node_input.setBlocking(False)


def stereo_capture_size(frame_size):
    """Bound mono capture to OV9282's1280x800 while preserving exact aspect.

    Keep smaller requests unchanged when hardware-aligned. Rational scaling
    preserves the common16:10 and16:9 modes without stretching either sensor;
    StereoDepth requires an output width divisible by16.
    """
    width, height = frame_size
    if type(width) is not int or type(height) is not int or min(width, height) <= 0:
        raise ValueError("RGB capture dimensions must be positive integers")
    divisor = math.gcd(width, height)
    aspect_width, aspect_height = width // divisor, height // divisor
    multiple = math.lcm(16 // math.gcd(aspect_width, 16), 2 // math.gcd(aspect_height, 2))
    scale = min(divisor, 1280 // aspect_width, 800 // aspect_height)
    scale = scale // multiple * multiple
    if scale < 1:
        raise ValueError("RGB aspect cannot fit a hardware-aligned1280x800 mono capture")
    return aspect_width * scale, aspect_height * scale


def capture_frame_rate_for_bandwidth(usb2, frame_size, mono_size):
    """Scale HD capture rates from the observed USB2 baseline payload budget.

    Each synchronized host packet carries RGB888, aligned RAW16 depth and
    two GRAY8 mono views. SDK timing and original timestamps remain intact.
    USB3 retains the existing rate; USB2 remains bounded to2..10fps.
    """
    if not usb2:
        return FRAME_RATE
    baseline_bytes = FRAME_SIZE[0] * FRAME_SIZE[1] * 7
    packet_bytes = frame_size[0] * frame_size[1] * 5 + mono_size[0] * mono_size[1] * 2
    return max(2.0, min(10.0, 10.0 * baseline_bytes / packet_bytes))


def configure_rgb_depth_alignment(pipeline, dai, platform, stereo, rgb_output, frame_size=FRAME_SIZE):
    """Use the SDK's documented alignment path for each device platform.

    RVC2/RVC3 align in StereoDepth; RVC4 uses ImageAlign. This selects pixel
    correspondence only: it never changes focal length, baseline or depth scale.
    """
    stereo_platforms = [getattr(dai.Platform, name, None) for name in ("RVC2", "RVC3")]
    if platform is not None and platform in [value for value in stereo_platforms if value is not None]:
        # In SDKv3 alignment chooses the camera geometry but does not resize
        # depth to its RGB frame. Set the SDK output explicitly, after presets.
        stereo.setOutputSize(*frame_size)
        configure_latest_input(stereo.inputAlignTo)
        rgb_output.link(stereo.inputAlignTo)
        return stereo.depth, "stereo_input_align_to"
    if platform == getattr(dai.Platform, "RVC4", None) and platform is not None:
        align = pipeline.create(dai.node.ImageAlign)
        output_size = getattr(align, "setOutputSize", None)
        if callable(output_size):
            output_size(*frame_size)
        configure_latest_input(align.input)
        configure_latest_input(align.inputAlignTo)
        stereo.depth.link(align.input)
        rgb_output.link(align.inputAlignTo)
        return align.outputAligned, "image_align"
    raise RuntimeError("unsupported depth alignment platform: " + str(platform))


def validated_imu_rotation(values):
    try:
        if len(values) != 9 or any(isinstance(value, (bool, str, bytes)) for value in values):
            raise ValueError("expected nine numeric rotation values")
        r = [float(value) for value in values]
        if not all(math.isfinite(value) and abs(value) <= 1.01 for value in r):
            raise ValueError("rotation must be finite and bounded")
        for row in range(3):
            for other in range(3):
                dot = sum(r[row*3+k]*r[other*3+k] for k in range(3))
                if abs(dot-(1 if row == other else 0)) > .01:
                    raise ValueError("rotation must be orthonormal")
        determinant = r[0]*(r[4]*r[8]-r[5]*r[7])-r[1]*(r[3]*r[8]-r[5]*r[6])+r[2]*(r[3]*r[7]-r[4]*r[6])
        if abs(determinant-1) > .01:
            raise ValueError("rotation must have determinant +1")
        return r
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid IMU rotation: " + str(error)) from error


def validated_imu_telemetry(value):
    """Validate optional diagnostic sensor evidence, never actuator authority."""
    if value is None:
        return None
    try:
        if not isinstance(value, dict) or not isinstance(value["sensor"], str) or not value["sensor"].startswith("BNO08"):
            raise ValueError("expected a supported sensor label")
        if value["gravity_source"] != "stationary_accelerometer_mean" or value["axes"] != "sensor_native":
            raise ValueError("unknown vector semantics")
        for key in ("gravity_mps2", "acceleration_mps2", "gyro_rad_s", "gravity_std_mps2"):
            vector = value[key]
            if len(vector) != 3 or any(isinstance(item, (bool, str, bytes)) for item in vector):
                raise ValueError("expected three numeric vector values")
            if not all(math.isfinite(float(item)) and abs(float(item)) <= 100 for item in vector):
                raise ValueError("vector is nonfinite or outside sensor bounds")
        if any(item < 0 for item in value["gravity_std_mps2"]):
            raise ValueError("standard deviation must be nonnegative")
        for key in ("sample_count", "latest_timestamp_ns", "reference_timestamp_ns"):
            if isinstance(value[key], bool) or not isinstance(value[key], int):
                raise ValueError("count and timestamps must be integers")
        if not 1 <= value["sample_count"] <= 1000:
            raise ValueError("sample count is outside bounds")
        if not 0 <= value["latest_timestamp_ns"] <= value["reference_timestamp_ns"] <= 2**63-1:
            raise ValueError("timestamps must share the ordered RGB host-clock domain")
        for key, maximum in (("window_milliseconds", 1000), ("age_milliseconds", 250)):
            number = value[key]
            if isinstance(number, (bool, str, bytes)) or not math.isfinite(float(number)) or not 0 <= number <= maximum:
                raise ValueError("sample timing is outside bounds")
        expected_age = (value["reference_timestamp_ns"]-value["latest_timestamp_ns"])/1_000_000
        if abs(value["age_milliseconds"]-expected_age) > .001:
            raise ValueError("sample age disagrees with timestamps")
        if not isinstance(value["stationary"], bool):
            raise ValueError("stationary quality must be Boolean")
        validated_imu_rotation(value["imu_to_rgb_rotation"])
        return value
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid IMU telemetry: " + str(error)) from error


class IMUDiagnosticWindow:
    """Half-second raw sensor window in DepthAI's synchronized host clock.

    The accelerometer mean is proper acceleration in native sensor axes. Its
    sign relative to gravity is intentionally not inferred. Only stationary
    observations can be interpreted as a gravity-direction diagnostic.
    """
    def __init__(self, sensor, imu_to_rgb_rotation):
        self.sensor = sensor
        self.rotation = validated_imu_rotation(imu_to_rgb_rotation)
        self.acceleration = deque(maxlen=200)
        self.gyro = deque(maxlen=200)
        self.failed = False

    def ingest(self, message):
        for packet in message.packets:
            for name, samples in (("acceleroMeter", self.acceleration), ("gyroscope", self.gyro)):
                report = getattr(packet, name)
                timestamp = timestamp_nanoseconds(report)
                if timestamp <= 0 or (samples and timestamp <= samples[-1][0]):
                    continue
                raw = [report.x, report.y, report.z]
                if any(isinstance(value, (bool, str, bytes)) for value in raw):
                    raise RuntimeError("invalid IMU report vector")
                vector = [float(value) for value in raw]
                if not all(math.isfinite(value) and abs(value) <= 100 for value in vector):
                    raise RuntimeError("invalid IMU report vector")
                samples.append((timestamp, vector))

    def snapshot(self, reference_timestamp_ns):
        beginning = reference_timestamp_ns-500_000_000
        acceleration = [(stamp, vector) for stamp, vector in self.acceleration if beginning <= stamp <= reference_timestamp_ns]
        gyro = [(stamp, vector) for stamp, vector in self.gyro if beginning <= stamp <= reference_timestamp_ns]
        if not acceleration or not gyro:
            return None
        latest = min(acceleration[-1][0], gyro[-1][0])
        age = (reference_timestamp_ns-latest)/1_000_000
        if age > 250:
            return None
        count = len(acceleration)
        mean = [math.fsum(vector[axis] for _, vector in acceleration)/count for axis in range(3)]
        deviation = [math.sqrt(math.fsum((vector[axis]-mean[axis])**2 for _, vector in acceleration)/count) for axis in range(3)]
        gyro_mean = [math.fsum(vector[axis] for _, vector in gyro)/len(gyro) for axis in range(3)]
        maximum_gyro_norm = max(math.sqrt(sum(item*item for item in vector)) for _, vector in gyro)
        magnitude = math.sqrt(sum(item*item for item in mean))
        window = (acceleration[-1][0]-acceleration[0][0])/1_000_000
        def covered(samples):
            return len(samples) >= 10 and all(second[0]-first[0] <= 50_000_000 for first, second in zip(samples, samples[1:]))
        stationary = covered(acceleration) and covered(gyro) and window >= 100 and 8 <= magnitude <= 12 and max(deviation) <= .15 and maximum_gyro_norm < .03
        return validated_imu_telemetry({"sensor": self.sensor, "gravity_source": "stationary_accelerometer_mean",
            "axes": "sensor_native", "gravity_mps2": mean, "acceleration_mps2": mean,
            "gyro_rad_s": gyro_mean, "sample_count": count, "window_milliseconds": window,
            "latest_timestamp_ns": latest, "reference_timestamp_ns": reference_timestamp_ns,
            "age_milliseconds": age, "gravity_std_mps2": deviation,
            "imu_to_rgb_rotation": self.rotation, "stationary": stationary})


def configure_optional_imu(pipeline, dai, device, calibration, rgb_socket, disabled=False):
    """Feature-gated BNO08x raw telemetry; unavailable IMU leaves RGB-D intact."""
    node = None
    try:
        if disabled:
            emit("CEREBRO_DEPTHCAM_IMU unavailable=disabled_after_pipeline_start_failure")
            return None, None
        get_sensor = getattr(device, "getConnectedIMU", None)
        sensor = str(get_sensor()) if callable(get_sensor) else "unavailable"
        if not sensor.startswith("BNO08"):
            emit("CEREBRO_DEPTHCAM_IMU unavailable=unsupported_sensor sensor=" + sensor)
            return None, None
        extrinsics = calibration.getImuToCameraExtrinsics(rgb_socket)
        if len(extrinsics) != 4 or any(len(row) != 4 for row in extrinsics):
            raise RuntimeError("missing factory IMU-to-RGB rotation")
        window = IMUDiagnosticWindow(sensor, [extrinsics[row][column] for row in range(3) for column in range(3)])
        sensors = [dai.IMUSensor.ACCELEROMETER_RAW, dai.IMUSensor.GYROSCOPE_RAW]
        node = pipeline.create(dai.node.IMU)
        node.enableIMUSensor(sensors, 100)
        node.setBatchReportThreshold(5)
        node.setMaxBatchReports(20)
        queue = node.out.createOutputQueue(maxSize=20, blocking=False)
        emit("CEREBRO_DEPTHCAM_IMU sensor={} rate_hz=100 source=stationary_accelerometer_mean axes=sensor_native".format(sensor))
        return queue, window
    except Exception as error:
        if node is not None:
            try:
                pipeline.remove(node)
            except Exception as removal_error:
                emit_error("Unable to remove unavailable optional IMU: " + str(removal_error))
        emit("CEREBRO_DEPTHCAM_IMU unavailable=initialization_failed reason=" + " ".join(str(error).split()))
        return None, None


def read_optional_imu(queue, window, rgb_frame):
    if queue is None or window is None or window.failed:
        return None
    try:
        for _ in range(20):
            message = queue.tryGet()
            if message is None:
                break
            window.ingest(message)
        return window.snapshot(timestamp_nanoseconds(rgb_frame))
    except Exception as error:
        window.failed = True
        emit_error("Optional IMU telemetry unavailable; RGB-D continues: " + str(error))
        return None


def frame_timing(rgb, depth, clock_now):
    return {
        "rgb_age_ms": round((clock_now - rgb.getTimestamp()).total_seconds() * 1000, 1),
        "depth_age_ms": round((clock_now - depth.getTimestamp()).total_seconds() * 1000, 1),
        "sync_skew_ms": round(abs((rgb.getTimestamp() - depth.getTimestamp()).total_seconds()) * 1000, 1),
    }


def validated_pinhole_intrinsics(matrix, width, height, flattened=False):
    """Validate K for the exact pixels being published, then flatten row-major."""
    try:
        if width <= 0 or height <= 0:
            raise ValueError("nonpositive frame dimensions")
        if flattened:
            if len(matrix) != 9:
                raise ValueError("expected nine intrinsic values")
            values = list(matrix)
        else:
            if len(matrix) != 3 or any(len(row) != 3 for row in matrix):
                raise ValueError("expected a 3x3 intrinsic matrix")
            values = [value for row in matrix for value in row]
        if any(isinstance(value, (bool, str, bytes)) for value in values):
            raise ValueError("intrinsics must be numeric")
        values = [float(value) for value in values]
        if not all(math.isfinite(value) for value in values):
            raise ValueError("intrinsics must be finite")
        if not (values[0] > 0 and values[4] > 0
                and 0 <= values[2] < width and 0 <= values[5] < height):
            raise ValueError("invalid focal lengths or principal point")
        if (any(abs(values[index]) > 1e-6 for index in (1, 3, 6, 7))
                or abs(values[8] - 1) > 1e-6):
            raise ValueError("intrinsics are not a pinhole camera matrix")
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid RGB camera intrinsics: " + str(error)) from error
    return values


def rgb_frame_intrinsics(rgb_frame, nominal_intrinsics, width, height):
    """Prefer per-frame K, which includes the Camera node's crop/resize transform.

    Older frames without transformation metadata may use EEPROM-derived K, but
    that fallback is explicitly identified on the wire. Present-but-invalid
    metadata is an error, never a reason to publish the nominal calibration.
    """
    get_transform = getattr(rgb_frame, "getTransformation", None)
    if get_transform is not None:
        if not callable(get_transform):
            raise RuntimeError("invalid RGB frame transformation accessor")
        transform = get_transform()
        if transform is not None:
            get_matrix = getattr(transform, "getIntrinsicMatrix", None)
            if get_matrix is not None:
                if not callable(get_matrix):
                    raise RuntimeError("invalid RGB frame intrinsic accessor")
                matrix = get_matrix()
                return (validated_pinhole_intrinsics(matrix, width, height),
                        "transformed_frame")
    return (validated_pinhole_intrinsics(nominal_intrinsics, width, height,
                                         flattened=True),
            "legacy_eeprom")


def rgb_frame_source_geometry(rgb_frame, published_intrinsics):
    """Optional source/crop evidence, without guessing absent SDK metadata."""
    get_transform = getattr(rgb_frame, "getTransformation", None)
    if get_transform is None:
        return None, None, None
    if not callable(get_transform):
        raise RuntimeError("invalid RGB frame transformation accessor")
    transform = get_transform()
    if transform is None:
        return None, None, None
    unavailable = object()

    def optional(name):
        getter = getattr(transform, name, None)
        if getter is None:
            return unavailable
        if not callable(getter):
            raise RuntimeError("invalid RGB source geometry accessor: " + name)
        return getter()

    def matrix_values(value, name):
        try:
            if len(value) != 3 or any(len(row) != 3 for row in value):
                raise ValueError("expected a 3x3 matrix")
            values = [item for row in value for item in row]
            if any(isinstance(item, (bool, str, bytes)) for item in values):
                raise ValueError("matrix must be numeric")
            values = [float(item) for item in values]
            if not all(math.isfinite(item) and abs(item) <= 1_000_000 for item in values):
                raise ValueError("matrix must be finite and bounded")
            return values
        except (TypeError, ValueError, OverflowError) as error:
            raise RuntimeError("invalid RGB " + name + ": " + str(error)) from error

    source_size = optional("getSourceSize")
    if source_size is not unavailable:
        try:
            if len(source_size) != 2:
                raise ValueError("expected width and height")
            if any(isinstance(item, (bool, str, bytes)) for item in source_size):
                raise ValueError("dimensions must be numeric")
            numbers = [float(item) for item in source_size]
            if not all(math.isfinite(item) and item.is_integer() and 1 <= item <= 8192 for item in numbers):
                raise ValueError("source dimensions must be integers from 1 to 8192")
            source_size = [int(item) for item in numbers]
        except (TypeError, ValueError, OverflowError) as error:
            raise RuntimeError("invalid RGB source size: " + str(error)) from error
    else:
        source_size = None
    source_matrix = optional("getSourceIntrinsicMatrix")
    source_intrinsics = None
    if source_matrix is not unavailable:
        source_intrinsics = matrix_values(source_matrix, "source intrinsics")
        size = source_size if source_size is not None else [8192, 8192]
        source_intrinsics = validated_pinhole_intrinsics(source_intrinsics, *size, flattened=True)
    image_matrix = optional("getMatrix")
    image_transform = None
    if image_matrix is not unavailable:
        image_transform = matrix_values(image_matrix, "image transform")
        a, b, c, d, e, f, g, h, i = image_transform
        determinant = a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
        if not math.isfinite(determinant) or abs(determinant) <= 1e-12:
            raise RuntimeError("invalid RGB image transform: singular matrix")
    if source_intrinsics is not None and image_transform is not None:
        product = [sum(image_transform[row*3+k]*source_intrinsics[k*3+column] for k in range(3))
                   for row in range(3) for column in range(3)]
        if not all(math.isclose(actual, expected, rel_tol=1e-5, abs_tol=1e-3)
                   for actual, expected in zip(product, published_intrinsics)):
            raise RuntimeError("invalid RGB source geometry: transform times source K disagrees with frame K")
    return source_size, source_intrinsics, image_transform


def depth_frame_geometry(depth_frame, rgb_frame, published_rgb_intrinsics):
    """Observe native depth geometry; never substitute the RGB calibration.

    Equal dimensions alone do not establish pixel correspondence. Keep this
    diagnostic optional/nonfatal for legacy viewing, with explicit unavailable,
    invalid and mismatched outcomes rather than manufacturing alignment proof.
    """
    dimensions_match = (depth_frame.getWidth(), depth_frame.getHeight()) == (rgb_frame.getWidth(), rgb_frame.getHeight())
    comparison = {"status": "unavailable", "dimensionsMatch": dimensions_match,
                  "intrinsicsMatch": None, "maximumIntrinsicDifferencePixels": None,
                  "sdkAlignedToRGB": None, "sdkEqualTransformationToRGB": None,
                  "depthTransformationValid": None, "rgbTransformationValid": None,
                  "detail": None}
    evidence = {"depth_intrinsics": None, "depth_intrinsics_source": "unavailable",
                "depth_source_size": None, "depth_source_intrinsics": None,
                "depth_image_transform": None, "depth_rgb_geometry_correspondence": comparison,
                "rgb_transformation_size": None, "depth_transformation_size": None,
                "rgb_source_distortion_coefficients": None, "depth_source_distortion_coefficients": None,
                "rgb_source_distortion_model": None, "depth_source_distortion_model": None}

    def transformation(frame):
        accessor = getattr(frame, "getTransformation", None)
        if accessor is None:
            return None
        if not callable(accessor):
            raise RuntimeError("Native frame transformation accessor is invalid")
        return accessor()

    def optional_bool(instance, name, *args):
        method = getattr(instance, name, None)
        if method is None:
            return None
        if not callable(method):
            raise RuntimeError("Native transformation accessor is invalid: " + name)
        value = method(*args)
        if type(value) is not bool:
            raise RuntimeError("Native transformation did not return a boolean: " + name)
        return value

    def observe_native_metadata(transform, prefix):
        if transform is None:
            return
        getter = getattr(transform, "getSize", None)
        if callable(getter):
            size = getter()
            if len(size) != 2 or any(type(value) is not int or not 0 <= value <= 8192 for value in size):
                raise RuntimeError("Invalid native " + prefix + " transformation size")
            evidence[prefix + "_transformation_size"] = list(size)
        getter = getattr(transform, "getDistortionCoefficients", None)
        if callable(getter):
            values = getter()
            if len(values) > 64 or any(isinstance(value, (bool, str, bytes)) for value in values):
                raise RuntimeError("Invalid native " + prefix + " source distortion coefficients")
            coefficients = [float(value) for value in values]
            if not all(math.isfinite(value) and abs(value) <= 1_000_000 for value in coefficients):
                raise RuntimeError("Nonfinite native " + prefix + " source distortion coefficients")
            # SDK coefficients describe the SOURCE sensor. Do not substitute
            # zeros or infer the current output is distorted from this alone.
            evidence[prefix + "_source_distortion_coefficients"] = coefficients
        getter = getattr(transform, "getDistortionModel", None)
        if callable(getter):
            evidence[prefix + "_source_distortion_model"] = str(getter())

    try:
        depth_transform, rgb_transform = transformation(depth_frame), transformation(rgb_frame)
        observe_native_metadata(rgb_transform, "rgb")
        observe_native_metadata(depth_transform, "depth")
        if depth_transform is None:
            comparison["detail"] = "Native depth transformation metadata is unavailable"
            return evidence
        comparison["depthTransformationValid"] = optional_bool(depth_transform, "isValid")
        if rgb_transform is not None:
            comparison["rgbTransformationValid"] = optional_bool(rgb_transform, "isValid")
        getter = getattr(depth_transform, "getIntrinsicMatrix", None)
        if getter is None:
            comparison["detail"] = "Native depth intrinsic metadata is unavailable"
            return evidence
        if not callable(getter):
            raise RuntimeError("Native depth intrinsic accessor is invalid")
        depth_intrinsics = validated_pinhole_intrinsics(getter(), int(depth_frame.getWidth()), int(depth_frame.getHeight()))
        evidence["depth_intrinsics"] = depth_intrinsics
        evidence["depth_intrinsics_source"] = "transformed_frame"
        source_size, source_intrinsics, image_transform = rgb_frame_source_geometry(depth_frame, depth_intrinsics)
        evidence.update(depth_source_size=source_size, depth_source_intrinsics=source_intrinsics,
                        depth_image_transform=image_transform)
        depth_size = evidence["depth_transformation_size"]
        if depth_size is not None and tuple(depth_size) != (depth_frame.getWidth(), depth_frame.getHeight()):
            raise RuntimeError("Native depth transformation dimensions differ from its actual frame")
        rgb_size = evidence["rgb_transformation_size"]
        if rgb_size is not None and tuple(rgb_size) != (rgb_frame.getWidth(), rgb_frame.getHeight()):
            raise RuntimeError("Native RGB transformation dimensions differ from its actual frame")
        maximum_difference = max(abs(a-b) for a, b in zip(depth_intrinsics, published_rgb_intrinsics))
        comparison["maximumIntrinsicDifferencePixels"] = maximum_difference
        comparison["intrinsicsMatch"] = maximum_difference <= .001
        if rgb_transform is not None:
            comparison["sdkAlignedToRGB"] = optional_bool(depth_transform, "isAlignedTo", rgb_transform)
            comparison["sdkEqualTransformationToRGB"] = optional_bool(depth_transform, "isEqualTransformation", rgb_transform)
        if comparison["depthTransformationValid"] is False or comparison["rgbTransformationValid"] is False:
            comparison["status"] = "invalid"
            comparison["detail"] = "The SDK reports an invalid native transformation"
        elif not dimensions_match or not comparison["intrinsicsMatch"] or comparison["sdkAlignedToRGB"] is False:
            comparison["status"] = "mismatched"
            comparison["detail"] = "Native depth/RGB dimensions, intrinsics or SDK alignment disagree"
        elif comparison["depthTransformationValid"] is True and comparison["rgbTransformationValid"] is True and comparison["sdkAlignedToRGB"] is True:
            comparison["status"] = "matched"
        else:
            comparison["detail"] = "Native validity/alignment proof is unavailable; matching dimensions or K alone are insufficient"
    except Exception as error:
        evidence["depth_intrinsics_source"] = "invalid_transform"
        comparison["status"] = "invalid"
        comparison["detail"] = " ".join(str(error).split())
    return evidence


def validated_lens_position(value, name):
    """Return an optional integer lens position without rounding or guessing."""
    if value is None:
        return None
    try:
        if isinstance(value, (bool, str, bytes)):
            raise ValueError("lens position must be numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or not numeric.is_integer() or not 0 <= numeric <= 255:
            raise ValueError("lens position must be an integer from 0 to 255")
        return int(numeric)
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid " + name + " lens position: " + str(error)) from error


def configure_rgb_calibrated_focus(rgb_camera, calibration, rgb_socket):
    """Match RGB focus to the EEPROM calibration used for depth alignment.

    Luxonis's aligned RGB/depth example fixes focus to this surveyed setting.
    Missing calibration remains explicitly unavailable; EEPROM is never edited.
    """
    get_position = getattr(calibration, "getLensPosition", None)
    if get_position is None:
        return None
    if not callable(get_position):
        raise RuntimeError("invalid RGB calibrated lens-position accessor")
    try:
        value = get_position(rgb_socket)
    except Exception as error:
        emit_error("RGB focus calibration unavailable; leaving focus unchanged: " + str(error))
        return None
    position = validated_lens_position(value, "RGB calibrated")
    if position is not None:
        rgb_camera.initialControl.setManualFocus(position)
    return position


def rgb_frame_lens_position(rgb_frame):
    get_position = getattr(rgb_frame, "getLensPosition", None)
    if get_position is None:
        return None
    if not callable(get_position):
        raise RuntimeError("invalid RGB frame lens-position accessor")
    return validated_lens_position(get_position(), "RGB frame")


def camera_observation_error(method, error):
    # Optional diagnostics must not overflow the bounded IPC header if an SDK
    # exception contains a large dump or repeated transport text.
    return (method + ": " + " ".join(str(error)[:1200].split()))[:400]


def rgb_frame_readback(rgb_frame):
    """Optional actual ImgFrame observations; never configure the camera."""
    evidence = {"rgb_frame_exposure_microseconds": None, "rgb_frame_iso": None,
                "rgb_frame_color_temperature_kelvin": None, "rgb_frame_observation_errors": []}
    errors = evidence["rgb_frame_observation_errors"]
    for method, key in (("getExposureTime", "rgb_frame_exposure_microseconds"),
                        ("getSensitivity", "rgb_frame_iso"),
                        ("getColorTemperature", "rgb_frame_color_temperature_kelvin")):
        try:
            getter = getattr(rgb_frame, method, None)
            if not callable(getter):
                raise ValueError("getter unavailable")
            value = getter()
            if method == "getExposureTime":
                if not isinstance(value, timedelta):
                    raise ValueError("expected SDK timedelta")
                value = value.total_seconds() * 1_000_000
                if not math.isfinite(value) or not 0 < value <= 1_000_000_000:
                    raise ValueError("exposure must be finite and positive")
            elif type(value) is not int or not 0 < value <= 10_000_000:
                raise ValueError("expected a positive bounded SDK integer")
            evidence[key] = value
        except Exception as error:
            errors.append(camera_observation_error(method, error))
    return evidence


def rectified_stereo_frame_evidence(left_frame, right_frame, meter_unit=None):
    """Observe each synchronized mono frame's own SDK geometry, nonfatally.

    Matrices are row-major. SDK extrinsics describe SOURCE coordinate systems,
    not an asserted rectified virtual-camera basis or a measured calibration.
    No RGB/EEPROM intrinsics, spec translation or default centimeter unit is
    substituted when actual frame evidence is absent.
    """
    def observe(owner, method, errors, validator, *args):
        try:
            getter = getattr(owner, method, None)
            if not callable(getter):
                raise ValueError("getter unavailable")
            return validator(getter(*args))
        except Exception as error:
            errors.append(camera_observation_error(method, error))
            return None

    def integer(value):
        if type(value) is not int or not 0 <= value < 2**64:
            raise ValueError("expected a nonnegative SDK integer")
        return value

    def timestamp(value):
        if not isinstance(value, timedelta):
            raise ValueError("expected SDK timedelta")
        seconds = value.total_seconds()
        if not math.isfinite(seconds) or not 0 <= seconds < (2**64 / 1_000_000_000):
            raise ValueError("invalid SDK timestamp")
        return integer(int(round(seconds * 1_000_000_000)))

    def dimensions(value):
        if len(value) != 2 or any(type(v) is not int or not 1 <= v <= 8192 for v in value):
            raise ValueError("expected native dimensions from1 to8192")
        return list(value)

    def boolean(value):
        if type(value) is not bool:
            raise ValueError("expected SDK boolean")
        return value

    def text(value):
        if value is None or isinstance(value, (bool, int, float, bytes)):
            raise ValueError("value unavailable")
        value = str(value)
        if not value or len(value) > 256:
            raise ValueError("invalid SDK label")
        return value

    def available(value):
        if value is None:
            raise ValueError("value unavailable")
        return value

    def matrix(value, size):
        if len(value) != size or any(len(row) != size for row in value):
            raise ValueError("expected a {}x{} matrix".format(size, size))
        values = [item for row in value for item in row]
        if any(isinstance(item, (bool, str, bytes)) for item in values):
            raise ValueError("matrix must be numeric")
        values = [float(item) for item in values]
        if not all(math.isfinite(item) and abs(item) <= 1_000_000 for item in values):
            raise ValueError("matrix must be finite and bounded")
        return values

    def image_matrix(value):
        values = matrix(value, 3)
        a, b, c, d, e, f, g, h, i = values
        determinant = a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
        if abs(determinant) <= 1e-12:
            raise ValueError("singular image transform")
        return values

    def rigid_matrix(value):
        values = matrix(value, 4)
        if any(abs(values[12+i] - expected) > 1e-5 for i, expected in enumerate((0, 0, 0, 1))):
            raise ValueError("invalid homogeneous last row")
        rotation = [[values[row*4+column] for column in range(3)] for row in range(3)]
        if any(abs(sum(rotation[k][row]*rotation[k][column] for k in range(3))
                   - (1 if row == column else 0)) > 1e-3 for row in range(3) for column in range(3)):
            raise ValueError("extrinsic rotation is not orthonormal")
        a, b, c = rotation
        determinant = a[0]*(b[1]*c[2]-b[2]*c[1])-a[1]*(b[0]*c[2]-b[2]*c[0])+a[2]*(b[0]*c[1]-b[1]*c[0])
        if abs(determinant - 1) > 1e-3 or any(abs(values[index]) > 100 for index in (3, 7, 11)):
            raise ValueError("extrinsic is not a bounded proper rigid transform in meters")
        return values

    def coefficients(value):
        if len(value) > 64 or any(isinstance(v, (bool, str, bytes)) for v in value):
            raise ValueError("invalid source distortion coefficients")
        values = [float(v) for v in value]
        if not all(math.isfinite(v) and abs(v) <= 1_000_000 for v in values):
            raise ValueError("nonfinite source distortion coefficients")
        return values

    def mono(frame):
        errors = []
        result = {"source": "sdk_frame_transformation", "sequence": None,
                  "timestampNanoseconds": None, "timestampDeviceNanoseconds": None,
                  "width": frame.getWidth(), "height": frame.getHeight(),
                  "intrinsics": None, "sourceSize": None, "sourceIntrinsics": None,
                  "imageTransform": None, "transformationSize": None, "transformationValid": None,
                  "sourceDistortionCoefficients": None, "sourceDistortionModel": None,
                  "extrinsicsToCommon": None, "evidenceErrors": errors}
        for method, key, validator in (("getSequenceNum", "sequence", integer),
                                       ("getTimestamp", "timestampNanoseconds", timestamp),
                                       ("getTimestampDevice", "timestampDeviceNanoseconds", timestamp)):
            result[key] = observe(frame, method, errors, validator)
        transform = observe(frame, "getTransformation", errors, available)
        if transform is None:
            return result, None
        for method, key, validator in (("isValid", "transformationValid", boolean),
                                       ("getSize", "transformationSize", dimensions),
                                       ("getSourceSize", "sourceSize", dimensions),
                                       ("getTransformationMatrix", "imageTransform", image_matrix),
                                       ("getDistortionCoefficients", "sourceDistortionCoefficients", coefficients),
                                       ("getDistortionModel", "sourceDistortionModel", text)):
            result[key] = observe(transform, method, errors, validator)
        result["intrinsics"] = observe(transform, "getIntrinsicMatrix", errors,
            lambda value: validated_pinhole_intrinsics(value, result["width"], result["height"]))
        def source_intrinsics(value):
            values = matrix(value, 3)
            if result["sourceSize"] is not None:
                return validated_pinhole_intrinsics(values, *result["sourceSize"], flattened=True)
            # Retain this actual matrix without inventing its absent dimensions.
            if (values[0] <= 0 or values[4] <= 0 or values[2] < 0 or values[5] < 0
                    or any(abs(values[i]) > 1e-6 for i in (1, 3, 6, 7)) or abs(values[8]-1) > 1e-6):
                raise ValueError("invalid source pinhole intrinsics")
            return values
        result["sourceIntrinsics"] = observe(transform, "getSourceIntrinsicMatrix", errors, source_intrinsics)
        if result["transformationValid"] is False:
            errors.append("isValid: SDK reports an invalid transformation")
        if result["transformationSize"] not in (None, [result["width"], result["height"]]):
            errors.append("getSize: transformation dimensions differ from actual mono pixels")
        if all(result[key] is not None for key in ("intrinsics", "sourceIntrinsics", "imageTransform")):
            a, k = result["imageTransform"], result["sourceIntrinsics"]
            product = [sum(a[row*3+j]*k[j*3+column] for j in range(3)) for row in range(3) for column in range(3)]
            if any(abs(actual-expected) > .001 for actual, expected in zip(product, result["intrinsics"])):
                errors.append("source geometry: imageTransform times sourceIntrinsics disagrees with frame intrinsics")
        extrinsics = observe(transform, "getExtrinsics", errors, available)
        if extrinsics is not None:
            ex_errors = []
            ex = {"source": "sdk_frame_transformation_getExtrinsics", "toCameraSocket": None,
                  "sourceLengthUnit": None, "lengthUnit": "meter", "useSpecTranslation": False,
                  "matrix": None, "evidenceErrors": ex_errors}
            for attribute, key in (("toCameraSocket", "toCameraSocket"), ("lengthUnit", "sourceLengthUnit")):
                try:
                    ex[key] = text(getattr(extrinsics, attribute))
                except Exception as error:
                    ex_errors.append(camera_observation_error(attribute, error))
            if meter_unit is None:
                ex_errors.append("getTransformationMatrix: explicit SDK meter unit unavailable")
            else:
                ex["matrix"] = observe(extrinsics, "getTransformationMatrix", ex_errors, rigid_matrix, False, meter_unit)
            result["extrinsicsToCommon"] = ex
        return result, transform

    left, left_transform = mono(left_frame)
    right, right_transform = mono(right_frame)
    pair = {"source": "sdk_frame_transformation_getExtrinsicsTransformationMatrixTo",
            "from": "left_source_optical", "to": "right_source_optical",
            "translationUnit": "meter", "useSpecTranslation": False,
            "matrix": None, "evidenceErrors": []}
    if left_transform is None or right_transform is None:
        pair["evidenceErrors"].append("source left/right frame transformations unavailable")
    elif meter_unit is None:
        pair["evidenceErrors"].append("explicit SDK meter unit unavailable")
    else:
        pair["matrix"] = observe(left_transform, "getExtrinsicsTransformationMatrixTo", pair["evidenceErrors"],
                                 rigid_matrix, right_transform, False, meter_unit)
    return {"rectified_left_geometry": left, "rectified_right_geometry": right,
            "rectified_left_source_to_right_source": pair}


def frame_payload(
    rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None,
    captured_at_milliseconds=None, rgb_calibrated_lens_position=None,
    depth_alignment_method=None, imu_telemetry=None, stereo_configuration=None,
    stereo_length_unit_meter=None, runtime_calibration=None
):
    rgb_width = int(rgb_frame.getWidth())
    rgb_height = int(rgb_frame.getHeight())
    depth_width = int(depth_frame.getWidth())
    depth_height = int(depth_frame.getHeight())
    frame_intrinsics, intrinsics_source = rgb_frame_intrinsics(
        rgb_frame, rgb_intrinsics, rgb_width, rgb_height
    )
    source_size, source_intrinsics, image_transform = rgb_frame_source_geometry(
        rgb_frame, frame_intrinsics
    )
    depth_geometry = depth_frame_geometry(depth_frame, rgb_frame, frame_intrinsics)
    if depth_alignment_method not in (None, "stereo_input_align_to", "image_align"):
        raise RuntimeError("invalid depth alignment method")
    imu_telemetry = validated_imu_telemetry(imu_telemetry)
    calibrated_lens_position = validated_lens_position(
        rgb_calibrated_lens_position, "RGB calibrated"
    )
    frame_lens_position = rgb_frame_lens_position(rgb_frame)

    rgb_bytes = memoryview(rgb_frame.getData()).tobytes()
    expected_rgb_length = rgb_width * rgb_height * 3
    if len(rgb_bytes) != expected_rgb_length:
        raise RuntimeError(
            "unexpected RGB byte count: expected {}, received {}".format(
                expected_rgb_length, len(rgb_bytes)
            )
        )

    # RAW16 arrives as native uint16 values.  Converting through NumPy's
    # explicit little-endian dtype keeps the wire contract portable.
    depth_native = depth_frame.getFrame()
    if depth_native.size != depth_width * depth_height:
        raise RuntimeError(
            "unexpected depth sample count: expected {}, received {}".format(
                depth_width * depth_height, depth_native.size
            )
        )
    depth_bytes = depth_native.astype("<u2", copy=False).tobytes(order="C")

    left_bytes = memoryview(left_frame.getData()).tobytes()
    right_bytes = memoryview(right_frame.getData()).tobytes()
    mono_width = int(left_frame.getWidth())
    mono_height = int(left_frame.getHeight())
    expected_mono_length = mono_width * mono_height
    if (len(left_bytes) != expected_mono_length or
            len(right_bytes) != expected_mono_length or
            int(right_frame.getWidth()) != mono_width or
            int(right_frame.getHeight()) != mono_height):
        raise RuntimeError("unexpected rectified stereo frame dimensions")

    header = {
        "protocol_version": PROTOCOL_VERSION,
        "sequence": int(rgb_frame.getSequenceNum()),
        "timestamp_ns": timestamp_nanoseconds(rgb_frame),
        "captured_at_milliseconds": captured_at_milliseconds,
        "rgb_width": rgb_width,
        "rgb_height": rgb_height,
        "rgb_format": "RGB888",
        "rgb_length": len(rgb_bytes),
        "depth_width": depth_width,
        "depth_height": depth_height,
        "depth_format": "DEPTH16LE",
        "depth_unit": "millimeter",
        "depth_length": len(depth_bytes),
        "stereo_width": mono_width,
        "stereo_height": mono_height,
        "stereo_format": "GRAY8",
        "left_length": len(left_bytes),
        "right_length": len(right_bytes),
        "rgb_intrinsics": frame_intrinsics,
        "rgb_intrinsics_source": intrinsics_source,
        "running_service_source_sha256": RUNNING_SERVICE_SOURCE_SHA256,
        "rgb_output_undistorted": RGB_OUTPUT_UNDISTORTED,
        "depth_alignment_method": depth_alignment_method,
        "rgb_source_size": source_size,
        "rgb_source_intrinsics": source_intrinsics,
        "rgb_image_transform": image_transform,
        "imu": imu_telemetry,
        "rgb_calibrated_lens_position": calibrated_lens_position,
        "rgb_frame_lens_position": frame_lens_position,
        "sidewalk_center_deviation": sidewalk_deviation,
        "sidewalk_confidence": sidewalk_confidence,
        "chess_pieces": chess_pieces or [],
    }
    header.update(depth_geometry)
    header.update(validated_stereo_configuration(stereo_configuration))
    header.update(rgb_frame_readback(rgb_frame))
    header.update(rectified_stereo_frame_evidence(left_frame, right_frame, stereo_length_unit_meter))
    if runtime_calibration is not None:
        header["runtime_calibration_identity"] = runtime_calibration_identity(runtime_calibration)
        header["runtime_calibration"] = runtime_calibration
    header_bytes = json.dumps(
        header, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return header_bytes, rgb_bytes, depth_bytes, left_bytes, right_bytes


def send_frame(
    client, rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None,
    captured_at_milliseconds=None, rgb_calibrated_lens_position=None,
    depth_alignment_method=None, imu_telemetry=None, stereo_configuration=None,
    stereo_length_unit_meter=None, runtime_calibration=None
):
    header, rgb_bytes, depth_bytes, left_bytes, right_bytes = frame_payload(
        rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
        sidewalk_deviation, sidewalk_confidence, chess_pieces, captured_at_milliseconds,
        rgb_calibrated_lens_position, depth_alignment_method, imu_telemetry, stereo_configuration,
        stereo_length_unit_meter, runtime_calibration
    )
    client.sendall(PROTOCOL_MAGIC + struct.pack(">I", len(header)) + header)
    client.sendall(rgb_bytes)
    client.sendall(depth_bytes)
    client.sendall(left_bytes)
    client.sendall(right_bytes)


FACE_MODEL_MANIFEST_VERSION = 1
FACE_MODEL_PARSER_TYPE = "depthai_yolo_spatial_v1"
FACE_DETECTION_TTL_SECONDS = 0.75
FACE_MODEL_MANIFEST_KEYS = {
    "manifest_version",
    "model_stem",
    "parser_type",
    "labels",
    "num_classes",
    "input_width",
    "input_height",
    "coordinate_size",
    "confidence_threshold",
    "iou_threshold",
}


def load_face_model_manifest(blob_path):
    manifest_path = os.path.splitext(blob_path)[0] + ".json"
    if not os.path.isfile(manifest_path):
        emit_error("Face model manifest not found; disabling NN: " + manifest_path)
        return None

    try:
        with open(manifest_path, "r", encoding="utf-8") as stream:
            manifest = json.load(stream)
        if not isinstance(manifest, dict) or set(manifest) != FACE_MODEL_MANIFEST_KEYS:
            raise ValueError("manifest keys do not match schema version 1")
        if manifest["manifest_version"] != FACE_MODEL_MANIFEST_VERSION:
            raise ValueError("unsupported manifest version")
        expected_stem = os.path.splitext(os.path.basename(blob_path))[0]
        if manifest["model_stem"] != expected_stem:
            raise ValueError("model_stem does not match blob filename")
        if manifest["parser_type"] != FACE_MODEL_PARSER_TYPE:
            raise ValueError("unsupported parser_type")

        labels = manifest["labels"]
        if not isinstance(labels, list) or not labels:
            raise ValueError("labels must be a nonempty array")
        if any(
            not isinstance(label, str) or not label or label != label.strip()
            for label in labels
        ):
            raise ValueError("labels must contain nonempty trimmed strings")
        if len(set(labels)) != len(labels):
            raise ValueError("labels must be unique")
        if type(manifest["num_classes"]) is not int or manifest["num_classes"] != len(labels):
            raise ValueError("num_classes must equal labels length")

        for key in ("input_width", "input_height"):
            value = manifest[key]
            if type(value) is not int or value <= 0 or value > 4096:
                raise ValueError(f"{key} must be an integer from 1 through 4096")
        if manifest["coordinate_size"] != 4:
            raise ValueError("coordinate_size must be 4")
        for key in ("confidence_threshold", "iou_threshold"):
            value = manifest[key]
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError(f"{key} must be finite")
            if value < 0.0 or value > 1.0:
                raise ValueError(f"{key} must be between 0 and 1")
        return manifest
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        emit_error("Invalid face model manifest; disabling NN: " + str(error))
        return None


def stream_camera(client, stop_event, mxid=None, role="face", model_name="chess", width=1280, height=720, ir_dot_intensity=None, stereo_mode="standard"):
    ir_dot_intensity = ir_dot_intensity_for_role(role, ir_dot_intensity)
    if stereo_mode not in ("standard","near_field") or (stereo_mode=="near_field" and role!="face"):
        raise ValueError("near_field stereo mode requires a face camera; standard is the default")
    frame_size = (width, height)
    # Footage capture may request a color size above the OV9282 stereo
    # sensors' native output. Keep stereo at a supported aspect-matched size;
    # Platform-specific alignment resamples depth into the selected RGB pixels.
    mono_size = stereo_capture_size(frame_size)
    dai = load_depthai()
    device = None
    runtime_loaded = load_runtime_stereo_profile(role)
    runtime_context_lost = threading.Event()

    def reconnection_callback(status):
        runtime_context_lost.set()
        emit_error("device reconnect invalidated runtime calibration context: " + str(status))

    try:
        if mxid:
            device = dai.Device(dai.DeviceInfo(mxid))
        else:
            device = dai.Device()
        device.setMaxReconnectionAttempts(
            DEVICE_RECONNECT_ATTEMPTS, reconnection_callback
        )
        usb_speed = device.getUsbSpeed()
        frame_rate = capture_frame_rate_for_bandwidth(usb_speed == dai.UsbSpeed.HIGH, frame_size, mono_size)
        emit("CEREBRO_DEPTHCAM_CAPTURE rgb={}x{} mono={}x{} usb={} fps={:.3f}".format(
            width, height, mono_size[0], mono_size[1], usb_speed, frame_rate))
        calibration = device.readCalibration2()
        with dai.Pipeline(device) as pipeline:
            # Freeze runtime data for factory and profile paths alike.
            pipeline.setAutoCalibrationMode(dai.Pipeline.AutoCalibrationMode.OFF)
            with runtime_stereo_calibration_session(device, pipeline, dai, role, calibration, runtime_loaded) as runtime_state:
                rgb_socket = color_camera_socket(device, dai)
                rgb_camera = pipeline.create(dai.node.Camera).build(rgb_socket)
                calibrated_lens_position = configure_rgb_calibrated_focus(
                    rgb_camera, calibration, rgb_socket
                )
                emit("CEREBRO_DEPTHCAM_RGB_FOCUS source={} lens_position={}".format(
                    "eeprom" if calibrated_lens_position is not None else "unavailable",
                    calibrated_lens_position,
                ))
                rgb_output = rgb_camera.requestOutput(
                    frame_size,
                    type=dai.ImgFrame.Type.RGB888i,
                    resizeMode=dai.ImgResizeMode.CROP,
                    fps=frame_rate,
                    enableUndistortion=RGB_OUTPUT_UNDISTORTED,
                )

                # OAK-D Pro is an RVC2 device. DepthAI's automatic v3 Depth node
                # does not always infer its OV9282 stereo pair, so wire the two
                # physical mono sensors explicitly and align their result to RGB.
                left_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_B)
                right_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_C)
                left_output = left_camera.requestOutput(
                    mono_size, type=dai.ImgFrame.Type.GRAY8, fps=frame_rate,
                    enableUndistortion=False,
                )
                right_output = right_camera.requestOutput(
                    mono_size, type=dai.ImgFrame.Type.GRAY8, fps=frame_rate,
                    enableUndistortion=False,
                )
                stereo = pipeline.create(dai.node.StereoDepth)
                stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.ROBOTICS)
                # Explicit SDK mesh rectification includes lens distortion. Never
                # silently retain AUTO/homography if this required v3.8 API fails.
                stereo.useHomographyRectification(False)
                emit("CEREBRO_DEPTHCAM_RECTIFICATION requested=explicit_mesh resolved_strategy_observed=false")
                stereo.setLeftRightCheck(True)
                configure_stereo_mode(stereo,stereo_mode)
                if runtime_state["attempted"]:
                    stereo.setDisparityToDepthUseSpecTranslation(False)
                    stereo.setRectificationUseSpecTranslation(False)
                    stereo.setDepthAlignmentUseSpecTranslation(False)
                configure_latest_input(stereo.left)
                configure_latest_input(stereo.right)
                left_output.link(stereo.left)
                right_output.link(stereo.right)

                aligned_depth_output, alignment_method = configure_rgb_depth_alignment(
                    pipeline, dai, device.getPlatform(), stereo, rgb_output, frame_size
                )
                emit("CEREBRO_DEPTHCAM_ALIGNMENT method={} platform={}".format(
                    alignment_method, device.getPlatform()
                ))
                imu_retry_key = (role, mxid or "automatic")
                imu_queue, imu_window = configure_optional_imu(pipeline, dai, device, calibration, rgb_socket,
                    disabled=imu_retry_key in IMU_DISABLED_AFTER_START_FAILURE)

                nn_model = None
                nn_queue = None
                face_model_labels = []
                script_dir = os.path.dirname(os.path.abspath(__file__))

                if role == "belly":
                    # The bundled road model has no sidewalk class. Navigation stays
                    # fail-closed until a purpose-built sidewalk contract is added.
                    pass
                elif role == "face":
                    # Dynamic Custom Spatial model (e.g. yolov8_chess_6shave.blob, yolov8_monopoly_6shave.blob)
                    blob_name = f"yolov8_{model_name.lower()}_6shave.blob"
                    blob_path = os.path.join(script_dir, "Models", blob_name)
                    if not os.path.exists(blob_path):
                        blob_path = os.path.join(script_dir, "..", "Models", blob_name)

                    if not os.path.exists(blob_path):
                        emit_error("Face model blob not found; disabling NN: " + blob_path)
                        manifest = None
                    else:
                        manifest = load_face_model_manifest(blob_path)

                    if manifest is not None:
                        try:
                            nn_model = pipeline.create(dai.node.YoloSpatialDetectionNetwork)
                            nn_model.setBlobPath(blob_path)
                            nn_model.setConfidenceThreshold(manifest["confidence_threshold"])
                            nn_model.setNumClasses(manifest["num_classes"])
                            nn_model.setCoordinateSize(manifest["coordinate_size"])
                            nn_model.setIouThreshold(manifest["iou_threshold"])
                            nn_input_stream = rgb_camera.requestOutput(
                                (manifest["input_width"], manifest["input_height"]),
                                type=dai.ImgFrame.Type.RGB888i,
                                resizeMode=dai.ImgResizeMode.CROP,
                                fps=5.0,
                                enableUndistortion=RGB_OUTPUT_UNDISTORTED,
                            )
                            nn_input_stream.link(nn_model.input)
                            stereo.depth.link(nn_model.inputDepth)
                            face_model_labels = manifest["labels"]
                        except Exception as error:
                            emit_error("Failed to initialize manifested face spatial neural network: " + str(error))
                            nn_model = None
                            face_model_labels = []

                sync = pipeline.create(dai.node.Sync)
                sync.setSyncThreshold(SYNC_THRESHOLD)
                sync.setSyncAttempts(3)
                # Leave a short timestamp-matching window while bounding history.
                for name in ("rgb", "depth", "left", "right"):
                    configure_latest_input(sync.inputs[name], size=4)
                rgb_output.link(sync.inputs["rgb"])
                aligned_depth_output.link(sync.inputs["depth"])
                stereo.rectifiedLeft.link(sync.inputs["left"])
                stereo.rectifiedRight.link(sync.inputs["right"])
                queue = sync.out.createOutputQueue(maxSize=1, blocking=False)

                if nn_model is not None:
                    configure_latest_input(nn_model.input, size=1)
                    configure_latest_input(nn_model.inputDepth, size=1)
                    nn_queue = nn_model.out.createOutputQueue(maxSize=1, blocking=False)

                try:
                    pipeline.start()
                except Exception:
                    # The helper's existing retry opens a fresh pipeline. Sacrifice
                    # optional IMU telemetry after a startup failure so it cannot
                    # prevent subsequent RGB-D recovery in this process.
                    if imu_window is not None:
                        IMU_DISABLED_AFTER_START_FAILURE.add(imu_retry_key)
                        emit_error("Pipeline startup failed with optional IMU; retrying RGB-D without IMU telemetry")
                    raise
                stereo_configuration=observed_stereo_configuration(stereo)
                stereo_length_unit_meter = getattr(getattr(dai, "LengthUnit", None), "METER", None)
                if stereo_mode=="near_field" and stereo_configuration["stereo_mode"]!="near_field":
                    raise RuntimeError("near_field stereo configuration was not confirmed by SDK readback")
                emit("CEREBRO_DEPTHCAM_STEREO "+json.dumps(stereo_configuration,separators=(",",":")))
                if runtime_context_lost.is_set():
                    raise RuntimeError("camera reconnected before runtime calibration provenance was frozen")
                runtime_provenance = finalize_runtime_calibration(runtime_state, device, pipeline, stereo, dai, role)
                write_calibration_evidence(device, calibration, dai, role, frame_size, mono_size,
                    requested_mxid=mxid, requested_stereo_mode=stereo_mode, runtime_state=runtime_state)
                configure_ir_projectors(device, role, ir_dot_intensity)
                intrinsic_matrix = calibration.getCameraIntrinsics(
                    rgb_socket, frame_size[0], frame_size[1]
                )
                rgb_intrinsics = [
                    float(value) for row in intrinsic_matrix for value in row
                ]
                if len(rgb_intrinsics) != 9:
                    raise RuntimeError("DepthAI returned invalid RGB camera intrinsics")
                emit("CEREBRO_DEPTHCAM_STREAMING")

                latest_sidewalk_deviation = None
                latest_sidewalk_confidence = None
                latest_chess_pieces = []
                latest_chess_pieces_updated_at = None
                last_timing_at = 0.0

                while not stop_event.is_set() and pipeline.isRunning():
                    if runtime_context_lost.is_set():
                        raise RuntimeError("camera reconnect invalidated frozen runtime calibration provenance")
                    group = queue.get(QUEUE_WAIT)
                    if group is None:
                        continue
                    if not isinstance(group, dai.MessageGroup):
                        raise RuntimeError("DepthAI sync returned an invalid message")

                    rgb_frame = group["rgb"]
                    depth_frame = group["depth"]
                    left_frame = group["left"]
                    right_frame = group["right"]
                    if not isinstance(rgb_frame, dai.ImgFrame) or not isinstance(
                        depth_frame, dai.ImgFrame
                    ):
                        raise RuntimeError("DepthAI sync group is missing RGB or depth")

                    # Process latest on-device neural network sidewalk segmentation/YOLO if available
                    if nn_queue is not None:
                        try:
                            nn_msg = nn_queue.tryGet()
                            if nn_msg is not None:
                                if role == "belly":
                                    # road-segmentation-adas-0001 has road, curb, and
                                    # mark classes, but no sidewalk class. Fail closed
                                    # until a real sidewalk model and confidence
                                    # contract are available.
                                    latest_sidewalk_deviation = None
                                    latest_sidewalk_confidence = None
                                elif role == "face":
                                    detections = getattr(nn_msg, "detections", None)
                                    if detections is None:
                                        raise RuntimeError("SpatialImgDetections is missing detections")
                                    latest_chess_pieces = []
                                    for det in detections:
                                        label_index = int(det.label)
                                        if label_index < 0 or label_index >= len(face_model_labels):
                                            raise RuntimeError("Detection label is outside manifested labels")
                                        latest_chess_pieces.append({
                                            "type": face_model_labels[label_index],
                                            "x": float(det.spatialCoordinates.x / 1000.0),
                                            "y": float(det.spatialCoordinates.y / 1000.0),
                                            "z": float(det.spatialCoordinates.z / 1000.0)
                                        })
                                    latest_chess_pieces_updated_at = time.monotonic()
                        except Exception as error:
                            emit_error("Failed to post-process on-device NeuralNetwork output: " + str(error))
                            latest_chess_pieces = []
                            latest_chess_pieces_updated_at = None
                    elif role == "face":
                        # Board corners do not identify chess pieces. Without a
                        # compatible detection model, publish no piece detections.
                        latest_chess_pieces = []
                        latest_chess_pieces_updated_at = None

                    if (
                        role == "face"
                        and latest_chess_pieces_updated_at is not None
                        and time.monotonic() - latest_chess_pieces_updated_at
                        > FACE_DETECTION_TTL_SECONDS
                    ):
                        latest_chess_pieces = []
                        latest_chess_pieces_updated_at = None

                    send_started = time.monotonic()
                    clock_now = dai.Clock.now()
                    timing = frame_timing(rgb_frame, depth_frame, clock_now)
                    if runtime_context_lost.is_set():
                        raise RuntimeError("camera reconnect invalidated frame runtime calibration provenance")
                    send_frame(
                        client, rgb_frame, depth_frame, left_frame, right_frame,
                        rgb_intrinsics, latest_sidewalk_deviation, latest_sidewalk_confidence,
                        latest_chess_pieces,
                        captured_at_milliseconds=capture_time_milliseconds(
                            [rgb_frame, depth_frame], clock_now, time.time()),
                        rgb_calibrated_lens_position=calibrated_lens_position,
                        depth_alignment_method=alignment_method,
                        imu_telemetry=read_optional_imu(imu_queue, imu_window, rgb_frame),
                        stereo_configuration=stereo_configuration,
                        stereo_length_unit_meter=stereo_length_unit_meter,
                        runtime_calibration=runtime_provenance,
                    )
                    send_finished = time.monotonic()
                    if send_finished - last_timing_at >= 5:
                        last_timing_at = send_finished
                        timing.update(role=role, width=width, height=height, usb_speed=str(usb_speed), fps=frame_rate,
                                      send_ms=round((send_finished - send_started) * 1000, 1))
                        emit("CEREBRO_DEPTHCAM_TIMING " + json.dumps(timing, separators=(",", ":")))

                if not stop_event.is_set():
                    raise RuntimeError("DepthAI pipeline stopped unexpectedly")
    finally:
        if device is not None:
            try:
                device.close()
            except Exception as error:
                emit_error("unable to close DepthAI device: " + str(error))


def accept_client(server, stop_event):
    while not stop_event.is_set():
        try:
            client, _ = server.accept()
            client.settimeout(CLIENT_SEND_TIMEOUT_SECONDS)
            return client
        except socket.timeout:
            continue
    return None


def client_is_connected(client):
    try:
        readable, _, _ = select.select([client], [], [], 0)
        if not readable:
            return True
        return client.recv(1, socket.MSG_PEEK) != b""
    except (BlockingIOError, InterruptedError, socket.timeout):
        return True
    except OSError:
        return False


def serve(server, stop_event, mxid=None, role="face", model_name="chess", width=1280, height=720, ir_dot_intensity=None, stereo_mode="standard"):
    while not stop_event.is_set():
        client = accept_client(server, stop_event)
        if client is None:
            return

        with client:
            retry_delay = INITIAL_RETRY_DELAY_SECONDS
            while not stop_event.is_set():
                try:
                    stream_camera(client, stop_event, mxid, role, model_name, width, height,
                                  ir_dot_intensity=ir_dot_intensity,stereo_mode=stereo_mode)
                    break
                except (BrokenPipeError, ConnectionResetError, socket.timeout) as error:
                    emit_error("camera client disconnected: " + str(error))
                    break
                except Exception as error:
                    emit_error(error)
                    if stop_event.wait(retry_delay):
                        return
                    if not client_is_connected(client):
                        break
                    retry_delay = min(retry_delay * 2.0, MAX_RETRY_DELAY_SECONDS)


def monitor_parent_process(parent_pid, stop_event):
    if parent_pid <= 1:
        emit_error("invalid Cerebro parent process ID")
        os._exit(2)

    # Secondary background thread to block on sys.stdin.read(1) for instant parent exit detection (even if parent becomes a macOS zombie)
    def monitor_stdin():
        import sys
        try:
            char = sys.stdin.read(1)
            if char == "":
                emit_error("Cerebro parent process stdin reached EOF (parent dead); stopping DepthAI service")
                os._exit(0)
        except Exception:
            os._exit(0)

    stdin_thread = threading.Thread(target=monitor_stdin, name="CerebroStdinMonitor", daemon=True)
    stdin_thread.start()

    while not stop_event.wait(1.0):
        parent_changed = os.getppid() != parent_pid
        try:
            os.kill(parent_pid, 0)
            parent_missing = False
        except ProcessLookupError:
            parent_missing = True
        except PermissionError:
            parent_missing = False

        if parent_changed or parent_missing:
            # This thread must be able to end a helper whose main thread is
            # blocked inside a native SDK call. The process is orphaned, so
            # normal socket cleanup is unnecessary; descriptors and the OAK
            # device close when the kernel exits the process.
            emit_error("Cerebro parent process exited; stopping DepthAI service")
            os._exit(0)


def main():
    args = parse_arguments()
    socket_path = normalized_socket_path(args.socket_path)
    stop_event = threading.Event()

    def request_stop(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    server = None
    identity = None
    service_lock = None
    try:
        service_lock = acquire_service_lock(socket_path)
        server, identity = create_server(socket_path)
        parent_monitor = threading.Thread(
            target=monitor_parent_process,
            args=(args.parent_pid, stop_event),
            name="CerebroParentMonitor",
            daemon=True,
        )
        parent_monitor.start()
        emit("CEREBRO_DEPTHCAM_READY " + socket_path)
        serve(server, stop_event, args.mxid, args.role, args.model_name, args.width, args.height,
              ir_dot_intensity=args.ir_dot_intensity,stereo_mode=args.stereo_mode)
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as error:
        emit_error(error)
        return 1
    finally:
        if server is not None:
            server.close()
        if identity is not None:
            remove_owned_socket(socket_path, identity)
        release_service_lock(service_lock)


if __name__ == "__main__":
    raise SystemExit(main())
