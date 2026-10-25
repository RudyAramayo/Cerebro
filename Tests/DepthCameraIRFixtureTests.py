#!/usr/bin/env python3
"""IR configuration fixtures; imports no SDK and never opens a USB device."""
from collections import defaultdict
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import threading
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ir_fixture_service", ROOT / "Cerebro/Webcam_color.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class Projectors:
    def __init__(self, result=True, error=None):
        self.calls = []
        self.result = result
        self.error = error

    def setIrFloodLightIntensity(self, value):
        self.calls.append(("flood", value))
        return self.result

    def setIrLaserDotProjectorIntensity(self, value):
        self.calls.append(("dot", value))
        if self.error:
            raise self.error
        return self.result


def capture(function, *args, **kwargs):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = function(*args, **kwargs)
    return result, output.getvalue()


def run_fixtures():
    face = service.parse_arguments(["--socket", "/private/tmp/fake-ir.sock"])
    belly = service.parse_arguments(["--socket", "/private/tmp/fake-ir.sock", "--role", "belly"])
    assert face.ir_dot_intensity == 0.5 and belly.ir_dot_intensity == 0
    assert face.stereo_mode==belly.stereo_mode=="standard"
    assert service.parse_arguments(["--socket","fixture","--stereo-mode","near_field"]).stereo_mode=="near_field"
    for arguments in [["--stereo-mode","unknown"],["--role","belly","--stereo-mode","near_field"]]:
        with contextlib.redirect_stderr(io.StringIO()):
            try:service.parse_arguments(["--socket","fixture",*arguments])
            except SystemExit as error:assert error.code==2
            else:raise AssertionError("Invalid/unsupported stereo opt-in was accepted")
    for value in ["0", "0.25", "1"]:
        args = service.parse_arguments(["--socket", "fixture", "--ir-dot-intensity", value])
        assert args.ir_dot_intensity == float(value)
    for value in ["nan", "inf", "-inf", "-0.01", "1.01", "text"]:
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                service.parse_arguments(["--socket", "fixture", "--ir-dot-intensity=" + value])
            except SystemExit as error:
                assert error.code == 2
            else:
                raise AssertionError("Invalid normalized intensity admitted: " + value)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            service.parse_arguments(["--socket", "fixture", "--role", "belly", "--ir-dot-intensity", "0.1"])
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError("Belly projector was enabled")
    for role, requested, expected in [("face", None, 0.5), ("face", 0, 0), ("face", 1, 1), ("belly", None, 0)]:
        device = Projectors()
        result, log = capture(service.configure_ir_projectors, device, role, requested)
        assert result is True and device.calls == [("flood", 0.0), ("dot", expected)]
        assert "dot_result=accepted" in log and "flood_requested=0.000" in log
    result, log = capture(service.configure_ir_projectors, object(), "face")
    assert result is False and "unsupported_sdk" in log and "dot_result=accepted" not in log
    for return_value in [False, None, 1]:
        result, log = capture(service.configure_ir_projectors, Projectors(result=return_value), "face")
        assert result is False and "unavailable_or_rejected" in log and "dot_result=accepted" not in log
    result, log = capture(service.configure_ir_projectors, Projectors(error=RuntimeError("driver\nnot found")), "face")
    assert result is False and "dot_result=error" in log and "driver not found" in log
    assert len(log.splitlines()) == 2
    path = Path(service.ir_status_directory()) / "face-ir-status.json"
    status = json.loads(path.read_text())
    assert status["processID"] == os.getpid() and status["role"] == "face"
    assert status["dotResult"] == "error" and status["sdkAccepted"] is False
    assert status["depthImprovementVerified"] is False and status["timestampUTC"]
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    assert not list(path.parent.glob(".face-ir-status-*")), "Atomic status left a partial file"
    with patch.object(service.os, "replace", side_effect=OSError("read only fixture")):
        result, log = capture(service.configure_ir_projectors, Projectors(), "face")
    assert result is True and "diagnostic status could not be saved" in log
    assert json.loads(path.read_text()) == status, "Failed atomic replacement overwrote the previous diagnostic"
    assert not list(path.parent.glob(".face-ir-status-*")), "Failed write left temporary data"
    with patch.object(service, "load_depthai", side_effect=AssertionError("Invalid settings opened a device")):
        try:
            service.stream_camera(None, None, role="belly", ir_dot_intensity=0.5)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid direct stream configuration was admitted")

    # Execute the actual stream setup with a complete in-memory pipeline. The
    # projector methods assert that start succeeded, while unavailable emitters
    # must not prevent the synchronized RGB-D service from reaching STREAMING.
    class Input:
        def setMaxSize(self, value): pass
        def setBlocking(self, value): pass

    class Output:
        def link(self, target): pass
        def createOutputQueue(self, *args, **kwargs): return object()

    class Camera:
        requests = []
        def build(self, value): self.socket = value; return self
        def requestOutput(self, size, **kwargs):
            self.requests.append((self.socket, size, kwargs)); return Output()

    class Stereo:
        PresetMode = SimpleNamespace(ROBOTICS="robotics")
        def __init__(self):
            self.left, self.right = Input(), Input()
            self.rectifiedLeft, self.rectifiedRight = Output(), Output()
            self.inputAlignTo, self.depth = Input(), Output()
            self.preset, self.left_right, self.subpixel, self.output_size = None, None, None, None
            self.extended=False;self.initialConfig=self;self.mode_calls=[]
        def setDefaultProfilePreset(self, value): self.preset = value
        def setLeftRightCheck(self, value): self.left_right = value
        def setSubpixel(self, value): self.subpixel = value;self.mode_calls.append(("subpixel",value))
        def setExtendedDisparity(self, value): self.extended=value;self.mode_calls.append(("extended",value))
        def getSubpixel(self):
            assert device.started,"Stereo provenance was stamped before the pipeline started"
            return self.subpixel
        def getExtendedDisparity(self):
            assert device.started,"Stereo provenance was stamped before the pipeline started"
            return self.extended
        def setOutputSize(self, width, height):
            assert self.preset == "robotics", "Output sizing preceded the preset that could overwrite it"
            self.output_size = (width, height)

    class Sync:
        def __init__(self): self.inputs, self.out = defaultdict(Input), Output()
        def setSyncThreshold(self, value): pass
        def setSyncAttempts(self, value): pass

    class Device(Projectors):
        def __init__(self, result=True, usb_speed="super"):
            super().__init__(result=result)
            self.started, self.closed = False, False
            self.usb_speed = usb_speed
        def setMaxReconnectionAttempts(self, *args): pass
        def getUsbSpeed(self): return self.usb_speed
        def getPlatform(self): return "rvc2"
        def readCalibration2(self): return self
        def getCameraIntrinsics(self, *args): return [[500, 0, 320], [0, 500, 200], [0, 0, 1]]
        def close(self): self.closed = True
        def setIrFloodLightIntensity(self, value):
            assert self.started, "Flood control preceded pipeline.start"
            return super().setIrFloodLightIntensity(value)
        def setIrLaserDotProjectorIntensity(self, value):
            assert self.started, "Dot control preceded pipeline.start"
            return super().setIrLaserDotProjectorIntensity(value)

    class Pipeline:
        stereo_nodes = []
        def __init__(self, device, fail=False): self.device, self.fail = device, fail
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def create(self, kind):
            node = kind()
            if kind is Stereo: self.stereo_nodes.append(node)
            return node
        def start(self):
            if self.fail: raise RuntimeError("pipeline start failed")
            self.device.started = True
        def isRunning(self): return False

    for supported, size, mono, usb, expected_fps,mode in [
            (True, (640, 400), (640, 400), "high", 10.,"standard"),
            (True, (1280, 800), (1280, 800), "high", 2.5,"standard"),
            (True, (1920, 1080), (1280, 720), "high", 2.,"standard"),
            (True, (1280, 800), (1280, 800), "super", service.FRAME_RATE,"standard"),
            (False, (640, 400), (640, 400), "super", service.FRAME_RATE,"standard"),
            (True, (640, 400), (640, 400), "high", 10.,"near_field")]:
        Camera.requests = []; Pipeline.stereo_nodes = []
        device = Device(result=supported, usb_speed=usb)
        fake = SimpleNamespace(Device=lambda *args: device, DeviceInfo=lambda value: value,
            Pipeline=lambda device: Pipeline(device), UsbSpeed=SimpleNamespace(HIGH="high"),
            Platform=SimpleNamespace(RVC2="rvc2", RVC3="rvc3", RVC4="rvc4"),
            node=SimpleNamespace(Camera=Camera, StereoDepth=Stereo, Sync=Sync),
            ImgFrame=SimpleNamespace(Type=SimpleNamespace(RGB888i="rgb", GRAY8="gray")),
            ImgResizeMode=SimpleNamespace(CROP="crop"), CameraBoardSocket=SimpleNamespace(CAM_B="b", CAM_C="c"))
        stop = threading.Event(); stop.set()
        with patch.object(service, "load_depthai", return_value=fake), \
             patch.object(service, "color_camera_socket", return_value="rgb"), \
             patch.object(service, "configure_rgb_calibrated_focus", return_value=None), \
             patch.object(service, "configure_optional_imu", return_value=(None, None)):
            _, log = capture(service.stream_camera, None, stop, width=size[0], height=size[1], model_name="nonexistent_fixture_model",stereo_mode=mode)
        assert device.closed and device.calls == [("flood", 0.0), ("dot", 0.5)]
        assert "CEREBRO_DEPTHCAM_STREAMING" in log
        assert "CEREBRO_DEPTHCAM_CALIBRATION role=face" in log
        evidence_pointer = json.loads((Path(service.ir_status_directory())/"face-calibration-latest.json").read_text())
        evidence = json.loads(Path(evidence_pointer["evidencePath"]).read_text())
        assert evidence["requestedPipeline"]["stereoMode"] == mode
        assert evidence["requestedPipeline"]["resolvedStrategyObserved"] is False
        assert evidence["metricAccuracyVerified"] is False and evidence["eepromExport"]["status"] == "unavailable"
        assert len(Camera.requests) == 3
        assert [entry[1] for entry in Camera.requests] == [size, mono, mono]
        assert all(entry[2]["fps"] == expected_fps for entry in Camera.requests)
        assert Camera.requests[0][2]["enableUndistortion"] is True
        assert all(entry[2]["enableUndistortion"] is False for entry in Camera.requests[1:])
        stereo = Pipeline.stereo_nodes[0]
        assert stereo.output_size == size and stereo.left_right is True and stereo.subpixel is (mode=="standard")
        assert stereo.extended is (mode=="near_field")
        assert stereo.mode_calls==([("subpixel",False),("extended",True)] if mode=="near_field" else [("subpixel",True)])
        assert '"stereo_mode":"'+mode+'"' in log and '"stereo_mode_source":"sdk_initial_config_readback"' in log
        assert "CEREBRO_DEPTHCAM_CAPTURE rgb={}x{} mono={}x{}".format(*size, *mono) in log

    # Configuration intent cannot label frames when SDK readback disagrees.
    device=Device();stop=threading.Event();stop.set()
    with patch.object(service,"load_depthai",return_value=fake), \
         patch.object(service,"color_camera_socket",return_value="rgb"), \
         patch.object(service,"configure_rgb_calibrated_focus",return_value=None), \
         patch.object(service,"configure_optional_imu",return_value=(None,None)), \
         patch.object(Stereo,"getExtendedDisparity",return_value=False):
        try:capture(service.stream_camera,None,stop,width=640,height=400,stereo_mode="near_field")
        except RuntimeError as error:assert "not confirmed by SDK readback" in str(error)
        else:raise AssertionError("Rejected near-field configuration streamed as requested")
    assert device.closed and not device.calls,"Failed near-field readback reached IR/streaming"

    print("Depth camera IR fixtures passed: validated face/belly CLI defaults, normalized bounds, unsupported/rejected/error reporting, after-start SDK ordering; real RGB-D setup retains metric settings and requests matched SDK dimensions/aspect with USB2/USB3 capture rates")


def main():
    with tempfile.TemporaryDirectory(prefix="rob-ir-fixture-") as directory:
        fake_home = Path(directory) / "fake-home"
        status_directory = fake_home / "Library/Application Support/Cerebro/DepthCamera"
        with patch.object(service, "ir_status_directory", return_value=str(status_directory)):
            run_fixtures()
    print("IR status persistence passed: private permissions, atomic replacement, actual SDK results and nonfatal diagnostic I/O failure; no USB")


if __name__ == "__main__":
    main()
