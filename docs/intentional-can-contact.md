# Measured can contact in a reviewed grasp

`ROBWorkspaceIntentionalContact` describes one measured finite can cylinder and
the precise grasp/lift/release stages that may intentionally touch it. It binds
the cylinder to its RGB-D sequence and capture time, captured map fingerprint,
scene, camera, robot geometry, physical-arm mapping and selected tool. A visible
front-wall point is not a cylinder-axis center. The measurement must supply the
axis centers and diameter; optional radial fit uncertainty is capped at 3 mm.

This proof is an optional part of `ROBWorkspaceCollisionPlan.review` and `make`.
It is stored in the proposal and its fingerprint is stored in the collision
context. A complete route must retain its exact step count and grip/release jaw
indices. A runtime actual-start check supplies the same proof and original
`contactStepIndex`; `carryingAtStart` explicitly preserves the actual task phase.
General connectors have no contact allowance unless a frozen task stage is
provided.

The allowance applies only to the selected tool and, after the grip stage, its
matching measured payload. Other articulated links receive the unchanged full
collision checks. A target cell is eligible only when all contributing raw
occupied RGB-D sample bounds lie inside the measured cylinder. Every endpoint
contributing to conservative map dilation is included. If a table or another
object contributes a point outside the cylinder to the same cell, it remains an
obstacle. A map without raw-sample bounds falls back to checking all eight voxel
corners. Unknown cells remain unknown even inside the can volume. The map is
never erased, relabeled or made globally free.

The full-route proposal models the potential payload before any movement. At
runtime, the first reviewed lift is followed by the separate fixed-view visual
grasp check. Carrying proceeds only with supported visual evidence. Failed or
unknown evidence keeps the arm held; it does not grant attached-object masking,
release a possible payload or chain another reach. Static old-can occupancy is
ignored only for the proof's selected tool/matching payload in the reviewed
contact stages, rather than being removed from the environment for every link.

`Scripts/test-workspace-intentional-contact.sh` checks straddling can-wall cells,
all-source sample bounds, shared-cell obstacles, unknown space, other links,
target/map/stage mismatch, immutable fingerprints and serialization. These are
hardware-free fixtures, not a physical pickup result.
