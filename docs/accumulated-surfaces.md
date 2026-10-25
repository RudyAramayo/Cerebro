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
- Plane RGB colors accumulate into 40 mm texture cells. Adjacent observed cells
  are merged into rectangles, then two triangles per rectangle. Missing cells
  produce holes, including gaps inside a table. Textures are coarse observed
  RGB mosaics, not full-resolution photographic keyframe textures.
- Extraction stops at 2,048 rectangles. Up to 4,000 residual points preserve
  irregular details. The HUD reports when a detail limit is reached. It also
  reports capture age; retained history never gets described as current data.
- There is one pending surface job across the two cameras, at most two updates
  per second per camera, on the existing serial cloud worker. Raw cloud delivery
  drops to two display updates per second once surfaces replace it, and avoids
  constructing the hidden point geometry. Camera capture and actuator watchdogs
  retain their existing paths. Geometry and textures are
  built off the main thread and published only if their generation still matches.

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
There is no persisted room map, loop closure, global relocalization or dynamic
object tracker in this version.

A room scan while the robot drives needs a measured six-degree-of-freedom
camera pose with uncertainty, geometric registration and eventual loop closure.
Floor leveling alone cannot provide that. The established dense reconstruction
approach is pose tracking plus volumetric depth fusion, as described in
[KinectFusion](https://www.microsoft.com/en-us/research/publication/kinectfusion-real-time-dense-surface-mapping-tracking/)
and [Curless and Levoy's range-image integration](https://graphics.stanford.edu/papers/volrange/).
The sparse voxel measurements and separate rendering representation here leave
room to add that tracking without treating fitted polygons as free space.

## Can completion

The display prior is the existing 66 mm diameter, 115 mm tall upright can size.
Residual surface neighbourhoods above an observed horizontal tabletop are fit
to that radius. The fitter needs at least 20 side samples, 80% inliers, at least
1.5 radians of angular support, support in three height bands, observed height
of at least 60% of the prior, and at most 4.5 mm radial RMS. There are at most
16 candidate fits per extraction. Other sizes, tilted cans, deformations and
ambiguous observations remain points. Geometry alone does not identify a brand.

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

The synthetic 6,500-point table/wall example produces two planes and five quads
with its interior hole preserved; extraction was approximately 1–2 ms in an
optimized local run. That is an extraction benchmark, not an end-to-end camera
or room-scale performance claim. The existing renderer already batches point
primitives; polygon extraction is not automatically faster for small clouds.
