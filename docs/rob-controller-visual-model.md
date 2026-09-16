# Controller preview appearance

The SceneKit preview shares the upright PLY reconstruction with the website
and ROB Training: 113,900 captured triangles split across the chassis, treads,
torso, arms, neck and head. Captured colors are preserved with an unlit texture.
Procedural perforated flippers, end rollers and face LEDs remain in the rig.

Generate the bundle with ORobotics's `scripts/prepare-captured-rob.py` (see its
`docs/rob-visual-model.md`) and copy all three files into `Cerebro/` together:
`rob-visual.json`, `rob-captured.bin`, `rob-captured-colors.png`.
`ROBScanVisualModel.swift` is identical to the ROB Training adapter; it selects
SceneKit on macOS and RealityKit on iOS/visionOS and caches geometry and textures.
SceneKit flips atlas V coordinates for its NSImage texture convention.

Head commands rotate the captured optical assembly. Independent tread material
copies preserve left/right demand highlights on the captured surfaces. Existing
point clouds, IR beams and freshness handling are unchanged. Flippers remain at
their reference pose because this stream has no measured flipper-angle feedback.

Surface partitions and pivots are visual approximations at a 1.2× display scale.
They do not change geometry profiles, calibrated URDFs, encoder references,
actuator limits or control transport. The earlier 13.25/13.5-inch flipper
endpoint discrepancy remains unresolved; the scaffold uses 336.55 mm.

Run `Scripts/test-rob-visual.sh` for texture, hierarchy and independent head-motion
checks. An optional PNG path renders a standalone SceneKit view without opening
Cerebro or connecting hardware. The fixture reports initial and cached load time.

The captured base is aligned with the flipper rig. The virtual training laser
uses the captured shoulder housing and a named muzzle attachment, with no
additional housing. These attachment points are visual game effects only.
