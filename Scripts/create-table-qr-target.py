#!/usr/bin/env python3
"""Create ROB's measured, vector QR calibration sheet (no robot connection)."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas


PAYLOAD = "ROB:TABLE:001"
SYMBOL_MM = 120.0
QUIET_MODULES = 4
STEM = "rob-table-calibration-qr"


def make_symbol() -> np.ndarray:
    params = cv2.QRCodeEncoder_Params()
    params.version = 1
    params.correction_level = cv2.QRCodeEncoder_CORRECT_LEVEL_Q
    params.mode = cv2.QRCodeEncoder_MODE_ALPHANUMERIC
    encoded = cv2.QRCodeEncoder_create(params).encode(PAYLOAD)
    # OpenCV includes its own white border. Normalize to the actual 21-module
    # symbol; the PDF supplies a measured four-module quiet zone separately.
    ys, xs = np.where(encoded == 0)
    symbol = encoded[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    assert symbol.shape == (21, 21)
    assert set(np.unique(symbol)) == {0, 255}
    preview = cv2.resize(np.pad(symbol, QUIET_MODULES, constant_values=255),
                         None, fx=20, fy=20, interpolation=cv2.INTER_NEAREST)
    decoded, _, _ = cv2.QRCodeDetector().detectAndDecode(preview)
    assert decoded == PAYLOAD, "Generated QR failed its decode check"
    return symbol


def dimension(c: canvas.Canvas, x1: float, y1: float,
              x2: float, y2: float) -> None:
    c.setLineWidth(0.5)
    c.line(x1, y1, x2, y2)
    if y1 == y2:
        for x in (x1, x2):
            c.line(x, y1 - 1.6 * mm, x, y1 + 1.6 * mm)
    else:
        for y in (y1, y2):
            c.line(x1 - 1.6 * mm, y, x1 + 1.6 * mm, y)


def create(output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    pdf = output_dir / f"{STEM}.pdf"
    metadata = output_dir / f"{STEM}.json"
    symbol = make_symbol()
    modules = symbol.shape[0]
    module_mm = SYMBOL_MM / modules
    quiet_mm = QUIET_MODULES * module_mm
    footprint_mm = SYMBOL_MM + 2 * quiet_mm
    page_width, page_height = letter
    symbol_x = (page_width - SYMBOL_MM * mm) / 2
    quiet_top = 225 * mm
    symbol_y = quiet_top - (quiet_mm + SYMBOL_MM) * mm
    quiet_x = symbol_x - quiet_mm * mm
    quiet_y = symbol_y - quiet_mm * mm

    c = canvas.Canvas(str(pdf), pagesize=letter, pageCompression=1, invariant=1)
    c.setTitle("ROB table calibration target - ROB:TABLE:001")
    c.setAuthor("ROB / Cerebro")
    c.setSubject("120 mm square QR calibration target; print at Actual Size")
    c.setViewerPreference("PrintScaling", "None")
    c.setFillColorRGB(0, 0, 0)
    c.setFont("Helvetica-Bold", 21)
    c.drawCentredString(page_width / 2, 258 * mm, "ROB TABLE CALIBRATION")
    c.setFont("Helvetica", 10)
    c.drawCentredString(page_width / 2, 248 * mm,
                        "Fixed reference for neck and depth-camera calibration")
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(page_width / 2, 239 * mm, f"TARGET ID: {PAYLOAD}")

    # All annotations are outside the complete four-module quiet zone.
    dimension(c, symbol_x, 230 * mm, symbol_x + SYMBOL_MM * mm, 230 * mm)
    c.setFont("Helvetica", 9)
    c.drawCentredString(page_width / 2, 233 * mm, "120 mm")
    dimension(c, 22 * mm, symbol_y, 22 * mm, symbol_y + SYMBOL_MM * mm)
    c.saveState()
    c.translate(18 * mm, symbol_y + SYMBOL_MM * mm / 2)
    c.rotate(90)
    c.drawCentredString(0, 0, "120 mm")
    c.restoreState()

    c.setFillColorRGB(1, 1, 1)
    c.rect(quiet_x, quiet_y, footprint_mm * mm, footprint_mm * mm, fill=1, stroke=0)
    c.setFillColorRGB(0, 0, 0)
    path = c.beginPath()
    for row in range(modules):
        start = None
        for column in range(modules + 1):
            black = column < modules and symbol[row, column] == 0
            if black and start is None:
                start = column
            elif not black and start is not None:
                path.rect(symbol_x + start * module_mm * mm,
                          symbol_y + (modules - 1 - row) * module_mm * mm,
                          (column - start) * module_mm * mm, module_mm * mm)
                start = None
    c.drawPath(path, fill=1, stroke=0)

    c.setFont("Helvetica-Bold", 11)
    c.drawCentredString(page_width / 2, 51 * mm, "QR symbol: 120 x 120 mm")
    c.setFont("Helvetica", 9)
    c.drawCentredString(page_width / 2, 45.5 * mm,
                        "Dimensions exclude the blank white margin around the code.")
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(page_width / 2, 38.5 * mm,
                        "PRINT 100% / ACTUAL SIZE - do not use Fit to Page")

    ruler_x = (page_width - 100 * mm) / 2
    ruler_y = 28 * mm
    c.setLineWidth(1)
    c.line(ruler_x, ruler_y, ruler_x + 100 * mm, ruler_y)
    for tick in range(11):
        length = 3 if tick in (0, 5, 10) else 1.5
        c.line(ruler_x + tick * 10 * mm, ruler_y,
               ruler_x + tick * 10 * mm, ruler_y + length * mm)
    c.setFont("Helvetica", 9)
    c.drawCentredString(page_width / 2, 21 * mm,
                        "Scale check: this line must measure exactly 100 mm.")
    c.setFont("Helvetica", 9)
    c.drawCentredString(page_width / 2, 11 * mm,
                        "Tape the sheet flat on the table. Keep the code and white margin clear.")
    c.showPage()
    c.save()

    half = SYMBOL_MM / 2000
    record = {
        "schemaVersion": 1,
        "targetID": PAYLOAD,
        "payload": PAYLOAD,
        "symbology": "QR Code Model 2",
        "qrVersion": 1,
        "errorCorrection": "Q",
        "moduleCount": modules,
        "symbolSideMeters": SYMBOL_MM / 1000,
        "moduleSideMeters": module_mm / 1000,
        "quietZoneModules": QUIET_MODULES,
        "quietZoneEachSideMeters": quiet_mm / 1000,
        "totalBlankFootprintSideMeters": footprint_mm / 1000,
        "physicalDimensionsExcludeQuietZone": True,
        "frame": "Origin at symbol center; +X printed right, +Y printed up, +Z out of printed face.",
        "cornerOrder": ["topLeft", "topRight", "bottomRight", "bottomLeft"],
        "canonicalCornersMeters": [[-half, half, 0], [half, half, 0],
                                   [half, -half, 0], [-half, -half, 0]],
        "cornerCorrespondence": "Canonical decoded QR orientation, not arbitrary image-top-left order after rotation.",
        "pagePoints": [page_width, page_height],
        "symbolBoundsPDFPoints": [symbol_x, symbol_y, SYMBOL_MM * mm, SYMBOL_MM * mm],
        "scaleCheckLengthMeters": 0.1,
        "scaleCheckPDFPoints": [ruler_x, ruler_y, ruler_x + 100 * mm, ruler_y],
        "printScaling": "Actual Size / 100%; verify the 100 mm line with a ruler.",
        "quietZoneReference": "https://www.qrcode.com/en/howto/code.html/index.html",
        "pdfSHA256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
    }
    metadata.write_text(json.dumps(record, indent=2) + "\n")
    return pdf, metadata


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("output/pdf"))
    args = parser.parse_args()
    for result in create(args.output_dir):
        print(result.resolve())
