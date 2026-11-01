# Accumulated surface preview

The controller/ghost viewport has an **Accumulate surfaces** checkbox and a
**Reset scan** button. Enable accumulation with the base stationary. Slowly
inspect overlapping views with the neck. Separate HEAD
and BELLY histories replace their raw clouds after stable geometry is available.
The normal live cloud remains the default.

This first implementation builds a rough, session-only geometric preview. It
does not move any actuator, register a camera to an arm, modify the collision
map, or supply navigation clearance. Cyan translucent cylinders are inferred
can-sized geometry; the colored voxels are the actual measured returns.

## Representation and work budget

- Each camera owns a sparse hash map of at most 32,000 occupied 20 mm voxels.
  Coordinates are metres in a floor-aligned, Y-up robot-local frame. Rendering
  applies the existing presentation scale once, after reconstruction.
- A voxel becomes stable after two distinct frames. Per-frame means prevent a
  dense view from outweighing a sparse view. The mean has a bounded 32-frame
  averaging weight. Capture sequence and capture time must both advance.
  Deleted hash slots are compacted between frame updates so repeated expiry
  does not turn sparse-map lookups into full-table scans; survivor weights and
  timestamps remain unchanged.
- Six robust planes at most are fit to the stable voxel centroids. RANSAC uses
  a deterministic reservoir of at most 2,048 points per plane, followed by a
  covariance refit. Broad support in two directions and at most 10 mm RMS are
  required. A can's narrow curved surface is not a room plane.
- Confirmed planes retain their identity, normal, offset and UV axes. They are
  re-used while accumulated measured support remains. Small new planes need
  repeat fits, and near-coplanar residual noise does not immediately create a
  second competing face. Unmodeled samples remain residual points.
- Adjacent observed 40 mm geometry cells
  are merged into rectangles, then two triangles per rectangle. Missing cells
  produce holes, including gaps inside a table. Geometry cell size is independent
  of texture resolution: plane textures now come from calibrated BGRA camera
  images, orthorectified at 2 mm per texel initially, capped at 2048 pixels per
  dimension with coarser levels for larger extents. Depth visibility checks keep
  foreground objects out of a table's texture. Filled photographic texels stay
  fixed; later views fill only missing regions. Plane/profile reset or expiry
  discards the keyframe. This is texture history, not a live video surface.
  Atlas extent and measured-colour fallback now refresh even when RGB is
  unavailable or another plane owns the photographic acquisition slot. Filled
  16×16 tiles are skipped during refill; holes remain eligible for later RGB.
  First-view exposure differences can still leave seams between locked regions.
  Until a usable photograph is available, a plane keeps its measured voxel
  colours. Partly filled photographs use those coarse colours only in missing
  regions; they are never locked into the photographic history, so later valid
  views can fill them. Missing depth does not create new measured geometry.
  Photo visibility uses perpendicular distance to the fitted plane, in the same
  units as its RMS, rather than an optical-Z threshold that rejects oblique
  surfaces. Foreground/invalid-depth rejection remains in place.
- Nonplanar detail can use up to four retained 128×128 native-depth patches
  per camera. Candidate patches require at least 90% repeated depth support,
  within 20 mm optical depth in the previous accepted view no more than two
  seconds earlier, and at least 12% of those samples outside the planes' 15 mm
  fit tolerance. Contrast and missing plane support prioritize the fixed budget;
  QR detection or payload text does not influence selection. One patch is
  acquired per update. Captures above 1,048,576 pixels retain the plane path
  without allocating this detail history.
  Each valid pixel owns an independent, camera-oriented footprint at its
  measured depth and samples only its own photographic pixel centre. No
  triangles connect different returns, so holes and foreground depth jumps
  cannot stretch or delete neighbouring QR features. The footprint positions
  and photograph stay fixed. Coarse plane triangles and residual points are
  clipped within the patch's ray bundle and observed depth slab, preserving
  their outside geometry and UVs; there is no depth bias or draw-through overlay.
  The four-patch limit bounds added detail to 65,536 measured pixels and
  131,072 triangles. Patches retain missing-depth holes rather than infilling
  them, and are not a fused, watertight surface. Large viewpoint changes can
  reveal the individual footprints. They supply no collision or free-space
  evidence. Existing context resets, two-view see-through removal and 90-second
  expiry apply; published geometry/images are immutable across worker updates.
- Extraction stops at 2,048 rectangles. Up to 4,000 residual points preserve
  irregular details. The HUD reports when a detail limit is reached. It also
  reports capture age; retained history never gets described as current data.
- There is at most one pending surface job per camera, at most four updates
  per second per camera, on the existing serial cloud worker. Raw cloud delivery
  drops to four display updates per second once surfaces replace it, and avoids
  constructing the hidden point geometry. Camera capture and actuator watchdogs
  retain their existing paths. Busy trial display keeps its existing two-Hz
  throttle. Only one photographic atlas is acquired/refilled per reconstruction
  update, so a new room view does not rebuild every texture in one job.
  Geometry and textures are
  built off the main thread and published only if their generation still matches.
  Scene publication replaces the old root atomically with implicit animation
  disabled instead of removing its children before adding a replacement.

## Accumulation and limits

Only fresh, settled depth with calibrated intrinsics, a capture stream
ID/sequence and a usable display projection enters the map. An explicit camera
pose can accumulate tabletop-only views without seeing the floor; legacy pose
priors require a fresh accepted floor alignment. Head and belly observations are not fused
with each other because their relative registration remains provisional.
Changing intrinsics, capture stream, base placement, body-motion epoch or the
active camera/display projection profile resets the histories, including when
the new frame has no usable floor. An explicit camera pose is applied once to
both the samples and their visibility rays; a fresh floor fit remains diagnostic
instead of applying another alignment. Base/arm motion pauses accumulation.
An in-flight result cannot republish a history after reset or a changed
projection/body context. An empty surface result restores raw-cloud processing.

New views must overlap the existing geometry: at least 60 sampled nearest-voxel
matches, at least 15% sampled overlap, and at most 25 mm nearest-point RMS.
This checks the current neck/URDF pose prior; it does **not** estimate a camera
pose or correct drift. A flat floor alone does not establish translation or yaw.
If a view is rejected, return to an overlapping view or start a new submap.
Legacy views without a valid floor retain the last history but do not extend
it. Explicit poses use their unchanged projection for samples and visibility
rays even when no floor is visible. This display pose remains provisional and
does not establish camera-to-arm registration.

Old surfaces disappear after two accepted images consistently see more than
60 mm through their location. A locally consistent 3×3 depth neighbourhood is
required; missing depth, occlusion and image edges do not clear a surface.
Unseen voxels expire after 90 seconds of subsequent accepted capture time.
There is no persisted room map, loop closure, global relocalization or general
dynamic object tracker. The bounded can tracks below are separate display priors.

A room scan while the robot drives needs a measured six-degree-of-freedom
camera pose with uncertainty, geometric registration and eventual loop closure.
Floor leveling alone cannot provide that. The established dense reconstruction
approach is pose tracking plus volumetric depth fusion, as described in
[KinectFusion](https://www.microsoft.com/en-us/research/publication/kinectfusion-real-time-dense-surface-mapping-tracking/)
and [Curless and Levoy's range-image integration](https://graphics.stanford.edu/papers/volrange/).
The sparse voxel measurements and separate rendering representation here leave
room to add that tracking without treating fitted polygons as free space.

## Can completion

The display prior is the existing 66 mm diameter, 115 mm tall can size. Two recent
raw frames preserve small-object detail instead of fitting a can to the room's
20 mm voxel centroids. Red-can appearance selects candidate side samples above
an observed supporting plane; the can axis follows that plane's normal, rather
than assuming a perfect world-up camera calibration. The fitter needs at least
20 side samples, 55% inliers within the candidate, at least
1.5 radians of angular support, support in three height bands, observed height
of at least 60% of the prior, and at most 4.5 mm radial RMS. There are at most
16 candidate regions per extraction, each with a separate current-frame fit for
stationarity. Shape/coverage tests still reject flat patches
and short arcs. Color and geometry do not identify a brand. Other appearances,
sizes, independently tilted cans and ambiguous observations remain points.

Up to four persistent can identities match nearby fits and smooth their centres.
Current partial side evidence may sustain an existing model when a complete
refit fails. Without such evidence a model coasts for at most three seconds;
two frames of positive see-through depth remove it sooner. Coasting models are
named as a brief observation gap, and the surface HUD continues to report age.
Reset/profile/camera/body epoch changes clear these tracks with the rest of the
display submap. A retained model never adds occupied/free-space evidence.

The full cylinder is an explicit inferred overlay, with no fabricated texture
on its back. It does not add voxels or erase the observed front half. Its shape,
dimensions and centre must not be used as measured grasp/collision evidence.

## Stationary targets for ghost arm reach

**Preview stationary surface target** in the ghost editor uses an inferred can
only after independent full fits from the current raw frame agree over time.
The display's two-frame fit, smoothed centre and partial-side continuation do
not count as stationary measurements. The bounded window holds at most twelve
samples, requires at least five over one second, at most 4 mm deviation from
the mean, and at most 3 mm/s fitted drift. A gap longer than 0.6 s starts a new
window. A partial-only or occluded current frame immediately loses preview
eligibility even while its cyan display model remains visible. These are
configurable-in-code tolerances for this can prior, not a claim of zero motion.

Candidate search prefilters red side points once before the repeated local
fits. The stationary target uses the unsmoothed fitted positions. It carries
its track, capture time, projection and body identity to the ghost editor;
head and belly candidates remain separate. An explicit camera pose is required,
and converting from Y-up display metres to robot-model coordinates undoes the
presentation scale exactly once. Targets older than 0.75 s, or from a changed
body/projection/stream, cannot start a preview. Reset, lost evidence or more
than 8 mm target displacement clears an active surface preview.

This button calculates a three-stage **visual arm reach** using the shared
horizontal-wrist IK: current pose, above the target, closest reach. It reports
endpoint error and wrist tilt. It performs no camera search, base/torso
preparation, grasp, arm command or collision admission. Review, Execute and
Save cannot promote this surface rehearsal into an executable gesture. The
separate prepared-base pour rehearsal and measured depth collision map retain
their own contracts. Registration and the physical right-arm pose mapping still
need their independent commissioning; apparent stability cannot establish them.

## Verification

```sh
bash Scripts/test-accumulated-surface-map.sh
python3 -B Scripts/test-accumulated-surface-render.py /private/tmp/cerebro-accumulated-surfaces.png
python3 -B Tests/ROBDepthFloorIntegrationRuntimeTests.py
bash Scripts/test-depth-floor-rectification.sh
bash Scripts/test-depth-cloud-projection.sh
```

The C fixture includes optimized and AddressSanitizer/UndefinedBehaviorSanitizer
runs. It exercises frame deduplication, density weighting, capacity/tombstones,
history expiry, overlap rejection, observed holes and colors, half-cylinder
fitting, false-fit rejection, independent inferred geometry and visibility
clearing. The Objective-C fixture runs the actual renderer and scan publication
methods with inert robot services, including stream resets, separate cameras,
paused motion, rejected-floor history and a reset during a pending worker job.
It never connects a camera or actuator.

The temporal C fixture adds 79 consecutive visible frames with partial fits and
depth noise: no can identity/dropout transitions, fixed plane UV axes, brief
occlusion/reacquisition, bounded disappearance and two-frame see-through removal.
The photographic fixture generates a real QR and requires 11 consecutive decodes
and a bit-identical photographic QR region despite exposure changes in later input frames.
Unphotographed fallback is deliberately allowed to refresh with measured colours.
It also compares an off-centre QR's rendered position with its source image,
checks observed colours when RGB is unavailable, and checks depth-hole fallback,
later photographic refill and noisy oblique-plane coverage.

The additional stitching fixture raycasts eight translated/rotated camera
views of a fixed, off-centre QR, with depth noise, exposure changes and a
foreground occluder. It tests the production atlas separately, then the full
voxel/plane/texture pipeline. All seven post-warm-up pipeline views retained
the same plane ID and decoded the QR, with **1.851 mm maximum world-position
error**. The isolated atlas had eight decodes and zero measured world drift;
coverage grew from 223,000 to 364,488 photographic texels. A large extent change
forced 4 mm texels and retained decoding with 2.053 mm drift. Missing-RGB extent
growth and fallback recolouring pass; the pre-change `8a5723c` renderer fails
the extent-growth assertion.

On the final fixture view, refill visited 36,864 of 384,000 texels, a **90.4%
reduction in texel visits** versus scanning the whole atlas. Candidate fitting
examined 576 of 5,526 raw points after appearance filtering, **89.6% fewer
candidate-search points**. These are deterministic work counts, not claims of
end-to-end speedup. The stationarity fixtures cover noise, slow drift,
oscillation, relocation, partial-only support, gaps, stale data, repeated builds,
high-rate bursts and invalid values, in optimized and ASan/UBSan runs.

The ghost fixtures test model/display coordinate conversion, time and context
rejection, actual model IK through the editor button, reset, and prevention of
review/execution/save promotion. Run them with:

```sh
bash Scripts/test-ghost-motion.sh
bash Scripts/test-ghost-editor-render.sh /private/tmp/rob-stationary-ghost.png
```

These new changes are validated offline. Installation/restart is deferred to
the coordinated robot-testing session's runtime owner. The deployment paragraph
below describes the earlier texture fix, not this stationary-target change.
Sanitized measurements are in
[the stitching/stationarity validation](calibration/evidence/2026-10-31-stationary-surfaces/validation.json).

The October 31 texture correction removed a duplicate vertical flip when
SceneKit samples a `CGImage`. The previous centred-code/decode tests missed it:
an off-centre QR stayed readable but moved 129.201 pixels within the plane. The
corrected source/render centre error is 0.000 pixels in the synthetic fixture.
The saved tabletop replay's neutral fallback covered 143,918 of 256,000 pixels
before the fix and zero afterward. Its mean absolute RGB-channel difference
from the input fell from 69.453 to 29.024 on an 8-bit scale. This includes
unmodeled gaps and inferred geometry; it is not a calibration measurement.
This replay repeats one stationary RGB-D snapshot to isolate rendering, rather
than testing moving-camera registration. That orientation correction alone did
not recover the difficult floor QR's depth/plane coverage. The later depth-detail
change below addresses that separate failure. Neither change establishes
complete reconstruction, QR detection of every target or robot registration.
Sanitized results and private-artifact hashes are in the
[October 31 renderer validation](calibration/evidence/2026-10-31-surface-texture/renderer-validation.json).

The native Debug build was installed and relaunched in coordination with the
active can-pour session, combining texture commit `43e63bb` (cherry-picked as
`c9e7e67`) with that session's changes. Code-signature verification passed, and
all installed Mach-O files, including `Cerebro.debug.dylib`, matched the build
product. The running process loaded those installed images. Both arms remained
inactive with unchanged joint positions. The passive restart left the neck pose
unknown, so a fresh live HEAD scan still needs an established neck pose. Native
renderer fixtures and recorded replay provide the texture verification above;
this verification used no actuator commands. See the
[deployment record](calibration/evidence/2026-10-31-surface-texture/deployment-validation.json)
for exact hashes and runtime identity.

### Floor QR coverage recovery (2026-10-31)

In the saved 640×400 table capture, 1,668 of the floor QR polygon's 1,681 pixels
have valid depth (99.23%). Only 61.81% of those measured returns fit within
15 mm of any of the six frozen planes. Increasing the flat-plane visibility
tolerance would paint foreground or nonplanar measurements onto incorrect
geometry. The depth-detail layer instead keeps their measured positions and
the original RGB samples, including all 1,668 supported QR pixels; the thirteen
missing depth pixels remain missing. Pixel-centre texture coordinates prevent
a footprint from sampling an invalid neighbour at its edges.

The replay repeats this **one stored capture six times**, with synthetic
advancing sequence/timestamps to isolate reconstruction. It is not six
independent live observations or evidence of moving-camera registration.
Frames 3–6 decode `ROB:FLOOR:R01` in the actual 640×400 SceneKit render,
with at most **1.241 pixels** source/render QR-corner displacement. Frame 1
warms the voxel history; frame 2 has incomplete scene extraction and still
misses full-scene QR detection. These failures remain in the report. The
`ca06db1` renderer fails all reconstructed frames under the same native and
2× nearest-pixel decoding checks. Photograph decoding and world-position/color
comparisons inspect the pixels actually represented in the patch geometry,
not an unattached copy of the camera image.

The existing eight-view atlas/stitch tests retain their previous results.
The new optimized and ASan/UBSan detail fixture checks 16,382 valid samples,
pixel-centre UV ownership, holes, depth discontinuities, repeated-view support,
nonoverlap, input limits, frozen world geometry and color, coarse clipping area
and UV preservation, foreground/missing-depth retention, interrupted and
consecutive see-through observations, immutable published images, and expiry.
Numeric results and private-artifact hashes are recorded in
[the floor-QR validation](calibration/evidence/2026-10-31-floor-qr/validation.json).
No raw camera image is committed. The app build is verified without installation;
the resumed pour session retains exclusive runtime/audio ownership.

To replay local saved calibration evidence through the actual accumulator and
SceneKit renderer (without opening a camera or robot service):

```sh
python3 -B Scripts/replay-accumulated-surfaces.py capture-input.json output-directory --require-qr --expected-can-count 4
```

`--expected-can-count` is for a known stationary can scene; omit it for other
captures. `--require-qr` checks native QR payloads against both the photographic
atlas/detail geometry and the rendered 3D view after warm-up, and compares
world-anchored texture pixels. Detection tries native size, then 2× nearest
pixels if native detection finds nothing; native-scale results are reported
separately. `--require-native-render-qr` additionally requires decoding the
unscaled render. `--max-qr-corner-error-pixels 2` checks alignment.
`--warmup-frames` defaults to one; the difficult floor replay explicitly uses
two and leaves every warm-up result visible in the report. Reports and
per-frame PNGs are written to the requested output directory.

On 2026-10-24, local head capture `4575D65E-1A32-4407-BA5D-5EC4F708E1CF`
preserved `ROB:TABLE:001` and four fixed can IDs in all four post-warm-up frames.
Belly capture `3380D3D1-2C43-48EA-9491-0F6989C1F237` preserved `ROB:BELLY:B01`
and `ROB:BELLY:B02` in all four post-warm-up frames. Both texture atlases and
rendered scenes decoded, and 225 world-anchored QR texture comparisons showed
no changes. These are recorded-scene checks, not verification of a running
robot session or measured can/grasp accuracy.

The synthetic 6,500-point table/wall example produces two planes and five quads
with its interior hole preserved; extraction was approximately 1–2 ms in an
optimized local run. That is an extraction benchmark, not an end-to-end camera
or room-scale performance claim. The existing renderer already batches point
primitives; polygon extraction is not automatically faster for small clouds.
