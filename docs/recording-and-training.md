# Training sessions and camera footage

Open **Recording → Open Recording Control…**. Recording never starts merely
because a camera or autonomy is active. Training and camera footage have
separate Start/Stop controls and may run at the same time.

## Training corpus

Training sessions are written under:

`~/Library/Application Support/Cerebro/Recordings/Training/<UTC timestamp>_<ID>/`

The session starts with a `manifest.json` whose state is `recording`. On an
ordinary stop or application termination it is finalized as `complete` with
counts and an end time. If the process or computer fails first, the recording
directory, append-only JSON Lines logs, and completed keyframe files remain
recoverable; the `recording` state identifies an interrupted session.

Each enabled face/belly camera gets:

- `rgb/*.jpg`: timestamped, high-quality RGB keyframes at the selected bounded
  keyframe rate;
- `depth/*.depth16`: aligned, lossless little-endian uint16 millimeters, with
  zero reserved for invalid depth;
- `stereo_left/*.gray8` and `stereo_right/*.gray8` when the provider supplies
  rectified sensor views;
- `calibrations/*.json`: image dimensions, RGB pinhole intrinsics, alignment
  contract, and the current camera-to-robot extrinsic snapshot; and
- `frames.jsonl`: source sequence/timestamp, receive wall time and monotonic
  time, dimensions, file references, and calibration identity.

`events.jsonl` aligns RPLidar scans, local pose and pose-derived odometry,
manual/autonomous tread requests, controller authority, session boundaries,
write failures, and traversability labels. Raw valid RPLidar payloads are kept
separately under `lidar/` so a future parser can reproduce the original scan.

The automatic labeler is deliberately conservative. Only a fresh command from
the active **manual** controller can open a label window. Measured displacement
can produce `successfully_traversed`; sustained demand with negligible measured
motion can produce `stall_or_slip`. A handoff to autonomous control immediately
closes any manual window. Autonomous commands and outcomes remain in the log
for evaluation, but never label their own images as training truth. The
operator buttons add `acceptable`, `operator_rejected`, or `blocked` labels
against the latest keyframes and local pose.

This recorder creates the reproducible corpus; it does not fine-tune or replace
the running model during a drive. Model building should consume only finalized
sessions and preserve the label provenance in its split and evaluation report.

## Camera footage

Footage is written under:

`~/Movies/ROB Recordings/<UTC timestamp>_<ID>/`

Face, belly, and Insta360 are independently selectable. `Source` retains the
ordinary capture configuration. Face and belly also offer 1280×720,
1920×1080, and 3840×2160. A requested hardware size can temporarily restart
the DepthAI or AVFoundation stream; the independent neural-network input in
the DepthAI graph remains model-sized. Stereo capture stays at a supported
sensor size and aligned depth is resampled into the RGB coordinate space.

For Insta360 Pro cameras, 1920×960 and 3840×1920 select the on-camera stitched
2:1 panorama preview. The latter matches the high-resolution request shown in
Insta360's official Pro Camera API `camera._startPreview` example. Stopping
footage restores the normal 1920×960 preview.

Every `.mov` session has a manifest containing requested size, encoded size,
all observed source sizes, appended/dropped frame counts, and writer status.
This distinction matters: if hardware cannot provide the requested source
size, an encoded 4K frame must not be mistaken for 4K source detail.

Both modes refuse to start below 2 GB of free disk space. The panel remains a
live recording indicator; closing it does not stop recording.
