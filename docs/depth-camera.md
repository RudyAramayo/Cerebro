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
The OAK-D service wires `Camera` + `StereoDepth` + `ImageAlign` + `Sync`,
requests undistorted RGB, aligns depth to that RGB output, and transfers one
synchronized `MessageGroup` with RGB, depth and both rectified mono images.
Arm routines, main-camera live conversation/follow and belly navigation request
640 × 400; explicit footage capture can request another resolution. Depth is RAW16 millimeters by default and invalid samples are
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
- Frozen RGB preview with a moving depth overlay: capture and the overlay run
  independently of the RGB display renderer. Live RGB samples carry
  `DisplayImmediately` in their **per-sample** attachment dictionary, as
  required by [CoreMedia](https://developer.apple.com/library/archive/qa/qa1957/_index.html).
  A display queue that refuses frames for one second is flushed. No frames
  are enqueued during that flush. If it does not finish within another second,
  or still cannot accept frames afterward, only the display layer is replaced.
  Late recovery callbacks cannot reset a newer renderer or reopen a hidden
  preview. This recovery applies to both face and belly camera previews.
- Malformed IPC: the provider connection is discarded and retried; no bytes
  are force-cast into application objects.

Run `python3 Tests/ROBCameraPreviewRuntimeTests.py` on macOS to exercise the
production sample-buffer factory and preview recovery methods with a simulated
renderer. The test uses real CoreMedia/IOSurface buffers and requires access to
the system CoreVideo service; it does not start cameras or robot hardware.

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

## 2026-09-23 latency measurements

Camera-only tests on ROB found the main face OAK connected at `UsbSpeed.SUPER`
(USB 3), while the belly OAK negotiated `UsbSpeed.HIGH` (USB 2). Both were already
capturing 640 × 400 with depth enabled. The capture-to-socket age used the older
RGB/depth capture timestamp, not the arrival time. Each comparison ran both
cameras together for approximately ten seconds; no motor operations occurred.

| Profile | Main median / p95 age | Main delivered fps | Belly median / p95 age | Belly delivered fps |
| --- | ---: | ---: | ---: | ---: |
| Previous helper, requested 30 fps | 80.2 / 84.3 ms | 30.2 | 518.5 / 539.4 ms | 15.1 |
| Bounded inputs, requested 30 fps | 82.4 / 120.4 ms | 30.2 | 521.0 / 576.1 ms | 14.6 |
| Bounded inputs, USB 2 capped at 10 fps | 82.5 / 89.5 ms | 30.2 | 106.0 / 119.1 ms | 10.0 |

In the final comparison, all 304 main and 102 belly frames were under the
400 ms arm input limit. RGB/depth timestamp skew was about 0.1–0.2 ms; helper
packing/socket sends were several milliseconds. The evidence points to USB 2
throughput and accumulated frames, rather than depth synchronization skew or
large application preview images, as the main belly delay. Merely bounding
queues did not fix the hardware bottleneck. Keeping 640 × 400 and capping USB 2
capture to 10 fps fixed the measured helper latency without disabling depth.
USB 3 capture stays at 30 fps. These short trials do not prove long-run timing
or end-to-end navigation/arm performance under every concurrent workload.

`Webcam_color.py` now bounds stereo/align/sync/NN input queues as well as the
host output queue. It prints `CEREBRO_DEPTHCAM_TIMING` records every five seconds:
USB speed, effective fps, image size, original RGB/depth age, sync skew and send
time. `CameraManager` coalesces pending session-queue frames to the newest input,
checks capture generations and logs capture-to-consumer age separately. Freshness
limits retain original capture timestamps and have not been relaxed.

The main face camera is now the sole arm-inspection view. Explicit controller
approval permits operator-supervised travel on the taught route with incomplete
camera coverage; stationary gripper commands still require visible, clear jaws.
Main-camera model video/follow uses the small profile. Destination terrain
navigation retains its calibrated belly perception source and Lidar checks:
substituting head-camera pixels without the correct ground transform would be
incorrect. Its belly capture demand also requests 640 × 400 and benefits from
the USB 2 cap. High-resolution recording can still override capture size, in
which case motion may fail its existing freshness gate.

[Luxonis latency guidance](https://docs.luxonis.com/software-v3/depthai/tutorials/optimizing)
describes measuring frame age against the SDK host clock and bounding input
queues. To verify transport recovery, check USB negotiation in the timing log;
a USB 3 port/cable may permit higher belly frame rates, but was not changed here.
Run `python3 Tests/ROBCameraIngressRuntimeTests.py` for the stalled-session-queue
regression, and `python3 Tests/DepthCameraIPCFixtureTests.py` for timestamp and
packet validation without hardware.

### Application-side RGB conversion

Later controller-approved trials still stopped at analyzed frame ages of
707–729 ms, despite the main camera capturing 640 × 400 over USB 3. Pausing
optional background MLX descriptions improved a five-second no-motion sample
(median analyzed age 356 → 263 ms), but the next stationary inspection still
stopped at 729 ms. The preference was restored; this was not a complete fix.

A live process sample found the IPC reader spending substantial time in the
per-pixel Swift RGB888-to-BGRA loop. An unoptimized standalone benchmark of the
production sample factory, 60 frames per case, measured:

| Frame size | Swift loop median / p95 | CPU vImage median / p95 |
| --- | ---: | ---: |
| 640 × 400 | 63.94 / 82.49 ms | 0.30 / 0.66 ms |
| 1280 × 720 | 242.69 / 399.12 ms | 0.48 / 0.61 ms |

The former 640 × 400 conversion already exceeded the 33.3 ms interval for
30 FPS, before later perception work. `CameraManager` now uses Accelerate's
CPU `vImageConvert_RGB888toBGRA8888`, with opaque alpha and the destination
buffer's actual row stride. This avoids GPU work and leaves RGB-D pairing,
capture timestamps, depth, frame admission and every motion safeguard intact.
These are conversion timings, not end-to-end camera or movement guarantees.

The production preview fixture checks every pixel at 640 × 400 and 1280 × 720,
plus single-pixel and odd-width vector tails, row padding, host presentation
time, display attachments and preview recovery. Preview, newest-frame ingress
and DepthAI packet fixtures passed. Live application timing after reload is
recorded separately from these isolated measurements.
