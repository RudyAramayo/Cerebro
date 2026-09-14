# Geometry workbench validation — September 13, 2026

This is a local development and calibration milestone, not a production robot
release or a commissioned geometry solution.

## Delivered

- Standalone AppKit/SceneKit Geometry Lab, built from geometry-only sources with
  no robot transports or actuator clients.
- The same view in Cerebro's Development menu; optional calibrated depth uses
  a single pending frame, bounded display rate, and stale-frame removal.
- Editable frame hierarchy, origins, axes, limits, preview positions, envelopes,
  camera frames and LACT pin centers. Scan and vendor-mesh imports and bundle
  export run on a background queue.
- Rigid landmark registration with separate validation points and saved fit
  inputs; position-only B1 IK preview with a residual and no execution path.
- Simulation-only profiles, a capture guide, measurement sheet, and portable
  URDF export using the original single-arm B1 meshes for both arm chains.
- Controller documentation identifying the existing Admin → Follow controls.

## Validation

- `Scripts/test-robot-geometry.sh`: **61 checks passed**. Coverage includes
  transform order, optical axes, calibrated deprojection, profile rejection,
  LACT geometry, rigid fitting through 180-degree and gimbal-lock cases,
  independent holdouts, IK residuals, and preservation of origins during export.
- The existing Amber reference transform fixtures and follow protocol/static
  checks passed during the investigation.
- `Scripts/build-robot-geometry-lab.sh`: local offline app builds successfully.
- Full Cerebro Debug build succeeds with signing disabled for validation.
  Existing project warnings remain; no new geometry-source warnings were found.
- The rendering harness loaded the photo-estimate profile and original B1
  meshes, wrote a SceneKit preview, and exited successfully. The image was
  visually inspected. Full final interactive UI testing was limited by the
  desktop automation tool returning `cgWindowNotFound`.
- Independent XML and filesystem validation of the exported bundle found
  **35 links, 34 joints and 8 unique vendor mesh files**. Every mesh hash matched
  its original; all mesh references resolved inside the bundle. The tree was
  connected, and preview angles were not baked into joint origins.

The local standalone utility is ad-hoc signed for development. It has not been
published as a signed/notarized production download. At this geometry-only
milestone no installed Cerebro binary was replaced or actuator commanded;
the later supervised runtime update is recorded below.

## Remaining inputs and commissioning

Actual mount transforms, body dimensions, neck order and axes, tool geometry,
LACT pin centers, joint directions and physical hanging angles require measured
data. The apparent startup positions of joints 2 and 4 are recorded as an
operator observation, not numerical calibration.

The initial inspection found an installed Cerebro app that predated Follow and
an unavailable paired iPhone tunnel for the read-only version query. Both local
apps were subsequently updated as recorded below. Supervised Follow testing
remains pending; no motion authorization or sensor gate was bypassed.

See [capture and commissioning](capture-and-commissioning.md) for the first
stationary dataset and the progression to a supervised ball exercise.

## Subsequent iPhone and Cerebro update

Later on September 13, ROBController build 2 was installed and verified on the
physical iPhone. It includes a direct Auto-screen Follow entry. The separate
Cerebro Follow camera fix builds and passes its isolated lifecycle checks.
After the operator confirmed physical readiness, Apple Development signed
Cerebro 1.0 build 2 from clean commit `590e83c` was installed and started through
its existing login supervisor. Signature verification passed; the process
remained running during startup observation. The prior app is preserved in
Downloads as `Cerebro Before Follow - 2026-09-13.app`.

Read-only service status showed healthy aligned main-camera RGB-D and a ready
controller listener; both depth workers reported streaming. No controller was
connected at observation time and no Follow target was authorized. Normal
startup can initialize or move hardware. Insta360 was not supplying frames,
and the camera worker disabled a neural-network stage because its configured
`yolov8_chess_6shave.blob` model was absent. Live iPhone connection, complete
perception readiness and a supervised physical rehearsal remain to be verified.
See [iPhone-only Follow](../iphone-headless-follow.md) for the current workflow.
