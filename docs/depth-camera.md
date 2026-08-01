# Luxonis RGB-D integration

## Decision

Cerebro uses a supervised out-of-process DepthAI provider as its primary OAK
camera path. AVFoundation remains an RGB-only fallback. This gives Cerebro
access to synchronized RGB and metric depth without putting the DepthAI native
runtime, USB ownership, or C++ exception boundary inside the robot controller
process.

Directly linking `depthai-core` would remove the Python process and can reduce
copies, but Luxonis has no Swift API or prebuilt macOS C++ release artifact.
That route requires a locally built dynamic library plus a narrow C or
Objective-C++ adapter. Catching C++ exceptions at the adapter does not isolate
native aborts, memory faults, or dependent-library failures. A future native
helper should therefore remain an XPC/helper process and keep the same provider
contract rather than linking into Cerebro itself.

## Luxonis release baseline

The integration is pinned to DepthAI `3.8.0`, released 2026-07-11:

- <https://github.com/luxonis/depthai-core/releases/tag/v3.8.0>
- <https://github.com/luxonis/depthai-core/blob/v3.8.0/examples/python/Depth/depth_rgb_align.py>
- <https://docs.luxonis.com/software-v3/depthai/tutorials/v2-vs-v3/>
- <https://docs.luxonis.com/software-v3/depthai/examples/misc/auto_reconnect/>

The 3.8 release adds the unified `Depth` node and device health diagnostics.
The camera service uses `Camera` + `Depth` + `Sync`, requests undistorted
640 x 400 RGB, aligns depth to that RGB output, and transfers a single paired
`MessageGroup`. Depth is RAW16 millimeters by default and invalid samples are
zero. UVC still exists in DepthAI 3.8, but it exposes one image input and is not
a transport for paired RGB plus metric RAW16 depth.

## Runtime data path

1. `AppDelegate` validates the selected Python environment and launches the
   bundled `Webcam_color.py` with a private Unix-socket path.
2. The helper alone opens the OAK device and configures limited SDK reconnects.
3. DepthAI synchronizes RGB and depth by timestamp and aligns depth to RGB.
4. The helper sends a versioned `CDP1` packet containing metadata, RGB888, and
   little-endian DEPTH16 data.
5. `CameraManager` validates all dimensions and lengths before allocating a
   CoreVideo buffer. Invalid or oversized packets terminate only the provider
   connection.
6. `CameraFrameSet.rgbSampleBuffer` feeds the existing preview, Vision, and
   Gemini code. `CameraFrameSet.alignedDepth` carries the same frame's depth;
   `distanceMillimeters(x:y:)` reads a valid, nonzero pixel safely. The main
   controller publishes the complete data and metadata as one immutable
   `latestAlignedDepthFrame` snapshot and clears it whenever RGB-D is not live.
7. If the helper is missing or reconnecting, `CameraManager` may use an
   accessible non-OAK AVFoundation camera as RGB-only fallback. A new RGB-D frame
   atomically becomes primary and stops that fallback session.

An OAK device is excluded from automatic AVFoundation fallback because UVC and
DepthAI would otherwise race for exclusive ownership. Legacy RGB-only OAK UVC
mode can be enabled deliberately when the SDK provider will not be used:

```bash
defaults write com.orbitusrobotics.Cerebro ROBAllowLuxonisUVCFallback -bool YES
```

Remove that default or set it to `NO` before returning to RGB-D mode.
While it is `YES`, Cerebro does not launch or connect the DepthAI helper, so the
UVC and SDK providers cannot compete for ownership of the OAK device.

## IPC v1

Each stream packet contains:

```text
4 bytes   ASCII magic CDP1
4 bytes   big-endian JSON header length
N bytes   compact UTF-8 JSON header
R bytes   RGB888 interleaved image
D bytes   little-endian UInt16 depth in millimeters
```

The JSON header includes protocol version, sequence, device timestamp,
dimensions, formats, units, and payload lengths. The consumer rejects unknown
versions/formats, inconsistent sizes, and payloads over 64 MiB. The socket is
mode `0600`; the helper removes it only when the filesystem object is the same
socket inode it created.

This initial protocol sends complete frame copies for simplicity. If profiling
shows copies are material, keep this control protocol and move only image
payloads to IOSurface/shared memory with a small bounded pool and explicit
lease/release messages.

## Failure behavior

- No Python or wrong DepthAI version: Python Settings reports the dependency;
  Cerebro continues running.
- No OAK camera: the helper remains alive and retries from 0.5 to 8 seconds.
- USB disconnect: DepthAI performs three immediate reconnect attempts, after
  which the helper rebuilds the device and pipeline with bounded backoff.
- Cerebro closes its camera client: the helper detects the closed socket and
  returns to accepting a new client.
- Helper exits or native SDK aborts: only the child process exits; AppDelegate
  and the socket client restart/reconnect.
- Cerebro exits normally: AppDelegate sends SIGTERM, waits for a bounded grace
  period, and sends SIGKILL only to that exact child if necessary. If Cerebro
  crashes, the helper's parent-PID monitor exits it. An exclusive lock prevents
  another helper from unlinking a live service's socket during restart races.
- Slow perception: `CameraManager` keeps at most one delivery in flight and
  drops older frames instead of accumulating latency.
- Malformed IPC: the provider connection is discarded and retried; no bytes
  are force-cast into application objects.

## Hardware validation checklist

No Luxonis device was attached during this refactor, so complete this checklist
on the target Mac with the real camera:

1. In Settings, create/select the managed Python environment and install
   dependencies. Validation must print `depthai 3.8.0`.
2. Connect the OAK camera directly over a known USB 3 data cable and launch
   Cerebro. Confirm logs contain `CEREBRO_DEPTHCAM_READY` followed by
   `CEREBRO_DEPTHCAM_STREAMING`.
3. Confirm camera state changes to `streamingRGBD`, RGB preview/Vision continue,
   and `alignedDepth` is 640 x 400 with nonzero millimeter values on objects.
4. Check alignment at foreground edges by comparing RGB pixel coordinates with
   depth values at the same coordinates.
5. Unplug for several seconds and reconnect. Cerebro must remain responsive,
   report reconnecting, and resume RGB-D without relaunching the app.
6. Launch with no camera, leave it for several retry cycles, then connect the
   camera. Robot control and unrelated subprocesses must remain usable.
7. Exercise an ordinary webcam while OAK is absent to confirm the RGB-only
   fallback, then attach OAK and confirm the provider switches to RGB-D.
8. Profile CPU and memory for at least 30 minutes. If RGB888-to-BGRA conversion
   or socket copies are significant, implement the IOSurface payload phase
   without changing the provider-facing `CameraFrameSet` API.

For OAK4/RVC4 hardware, also compare the device's Luxonis OS version against
the versions listed in the DepthAI 3.8.0 release notes before diagnosing SDK
failures.
