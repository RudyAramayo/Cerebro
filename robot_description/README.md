# ROB calibration drafts

- `rob_geometry_draft.json`: vendor single-arm joint constants instantiated
  twice, with schematic body/neck/track/camera geometry and URDF-zero preview.
- `rob_photo_layout_estimate.json`: an explicitly approximate folded-arm layout
  inspired by the lightsaber photographs and the reported hanging startup.
  The numerical angles are illustrative, not measured offsets.
- `landmarks-format-example.json`: synthetic point correspondences demonstrating
  fitting versus held-out validation data. Do not apply these to hardware.

Open profiles in **Robot Geometry Lab**, load the original single-arm B1 URDF
and its meshes, and refine them with measured landmarks. Follow
[the capture and commissioning guide](../docs/calibration/capture-and-commissioning.md).

Generate a portable mesh bundle with the standalone app:

```sh
build/'ROB Geometry Lab.app'/Contents/MacOS/'ROB Geometry Lab' \
  --export-draft /path/to/a/new/ROB-Calibration-folder \
  --profile robot_description/rob_photo_layout_estimate.json \
  --vendor '/path/to/Amber URDF/amber_b1.urdf'
```

The output contains `rob_droid.urdf`, `calibration.json`, mesh assets and a
limitations file. URDF export does not bake preview joint angles or boot
encoder zeros into the fixed geometry. It is **simulation-only** until a
separate commissioning process verifies the complete robot and driver mapping.
