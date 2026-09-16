# Controller preview appearance

The preview uses the September 15 scan-informed ROB mesh shared with the
website and ROB Training. `Cerebro/rob-visual.json` comes from ORobotics's
`scripts/export-rob-visual.mjs`. `ROBScanVisualModel.swift` is identical to the
ROB Training adapter and selects SceneKit on macOS and RealityKit on iOS/visionOS.

The model has triangular tracks, separate perforated flipper plates on the rear
wheel axle, end rollers, the open waist and neck, speaker chest, seven-joint
arms and paired head cameras. The preview opens facing the chest. Head commands
rotate the complete optical assembly; tread demand highlights cleats without
stretching the mesh. Existing point clouds, IR beams and freshness handling are
unchanged. Flipper pose stays at the visual reference because there is no
measured flipper-angle feedback in this stream.

This is a presentation mesh, not a change to robot geometry profiles, calibration,
encoder references, actuator limits or control transport. The source readings
include an unresolved 13.25/13.5-inch flipper endpoint discrepancy; the visual
uses 336.55 mm with a 1.2× preview scale.

Run `Scripts/test-rob-visual.sh` for the shared mesh/hierarchy fixture. An optional
PNG path renders a standalone view without opening Cerebro or connecting hardware.
