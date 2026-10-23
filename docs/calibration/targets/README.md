# Printable calibration references

Print [the calibration sheet](../../../output/pdf/rob-table-calibration-qr.pdf)
at **Actual Size / 100%**. Disable Fit to Page and verify that its scale-check
line measures **100 mm** before using it. Tape the sheet flat to a rigid table;
keep the code and its white margin uncovered and avoid glossy tape over them.
Leave ROB's base, the table and the sheet stationary during the neck sweep.

The QR payload is `ROB:TABLE:001`. Its symbol is **120 x 120 mm**, excluding
the four-module white quiet zone. The QR specification requires that clear
margin on every side. [DENSO WAVE's sizing guide](https://www.qrcode.com/en/howto/code.html/index.html).
The complete symbol plus quiet zone spans approximately **165.714 mm**.

[Target metadata](../../../output/pdf/rob-table-calibration-qr.json) records the
metric dimensions, canonical corner order, page geometry and PDF checksum. The
marker origin is the symbol center, with X printed right, Y printed up and Z
out of the printed face. Corner coordinates refer to the symbol boundary,
not the page or white-border boundary. Resolve decoded QR orientation before
matching corners when the camera rotates.

Regenerate the vector PDF and metadata from the repository root:

```sh
python3 Scripts/create-table-qr-target.py
```

The generator uses OpenCV and ReportLab. It verifies QR decoding before saving.
The rendered PDF was also visually inspected and decoded. Printing the target
does not perform camera or neck calibration; it supplies the fixed reference
for the planned capture-and-fit process.

## Floor and right-wall references

All three sheets use a **120 x 120 mm symbol**, a four-module white quiet zone
and a **100 mm scale-check ruler**, matching the table reference. Print at
**Actual Size / 100%**, verify the ruler, and leave every sheet fixed during
capture. Left and right mean **ROB's own left and right** at placement.

| Sheet | Unique QR payload | Placement |
| --- | --- | --- |
| [Left floor](../../../output/pdf/rob-floor-left-calibration-qr.pdf) | `ROB:FLOOR:L01` | Flat on the floor to ROB's left, visible from a downward camera view. |
| [Right floor](../../../output/pdf/rob-floor-right-calibration-qr.pdf) | `ROB:FLOOR:R01` | Flat on the floor to ROB's right, visible from a downward camera view. |
| [Right wall](../../../output/pdf/rob-wall-right-calibration-qr.pdf) | `ROB:WALL:R01` | Flat on the wall to ROB's right, with the page title upright. |

Keep the floor sheets on the same rigid floor surface, clear of ROB's treads.
Tape outside each code's white quiet zone; avoid shiny tape over the code.
Keep ROB's base stationary while recording the initial reference positions.
Record measured center-to-center separation of the floor targets, their
placement relative to a specified ROB base reference, and the wall target's
center height above the floor. Do not turn an unmeasured left/right placement
into a precise world coordinate. A floor-plane fit and a wall-plane fit are
independent orientation checks, not measured camera-to-arm registration.

Each PDF has a neighboring JSON file with its ID, dimensions, canonical corner
coordinates, intended surface/side and PDF checksum. The new sheets carry
`referencePoseMeasured: false` until their physical placements are measured.
The original table PDF and JSON remain byte-identical after the generator
extension.

Generate the three environment sheets without replacing the table sheet:

```sh
python3 Scripts/create-table-qr-target.py --target environment
```

Use `--target floor-left`, `floor-right` or `wall-right` for one sheet. Capture
software must preserve the decoded target ID and use the matching metric
definition; a floor or wall detection must not be relabeled as `ROB:TABLE:001`.
