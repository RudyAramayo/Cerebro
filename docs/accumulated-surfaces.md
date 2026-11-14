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
  Without a usable keyframe a plane is neutral gray, not a coarse RGB mosaic.
- Extraction stops at 2,048 rectangles. Up to 4,000 residual points preserve
  irregular details. The HUD reports when a detail limit is reached. It also
  reports capture age; retained history never gets described as current data.
- There is one pending surface job across the two cameras, at most four updates
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
16 candidate fits per extraction. Shape/coverage tests still reject flat patches
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
and a bit-identical keyframe despite exposure changes in later input frames.

To replay local saved calibration evidence through the actual accumulator and
SceneKit renderer (without opening a camera or robot service):

```sh
python3 -B Scripts/replay-accumulated-surfaces.py capture-input.json output-directory --require-qr --expected-can-count 4
```

`--expected-can-count` is for a known stationary can scene; omit it for other
captures. `--require-qr` checks native QR payloads against both the photographic
atlas and the rendered 3D view after warm-up, and compares world-anchored texture
pixels. Reports and per-frame PNGs are written to the requested output directory.

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
