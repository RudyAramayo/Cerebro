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
published as a signed/notarized production download. No installed production
Cerebro binary was replaced, and no robot actuator was commanded.

## Remaining inputs and commissioning

Actual mount transforms, body dimensions, neck order and axes, tool geometry,
LACT pin centers, joint directions and physical hanging angles require measured
data. The apparent startup positions of joints 2 and 4 are recorded as an
operator observation, not numerical calibration.

The installed Cerebro app predates the follow feature. A current source build
contains it, but installation, verification of the controller on the physical
phone, and supervised follow testing remain pending. The paired iPhone tunnel
was unavailable for the read-only version query. No motion authorization or
sensor gate was bypassed.

See [capture and commissioning](capture-and-commissioning.md) for the first
stationary dataset and the progression to a supervised ball exercise.
