# Printable table reference

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
