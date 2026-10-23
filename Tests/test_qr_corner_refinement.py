"""Synthetic measured-homography tests; never connects to robot hardware."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REFINE = load("corner_refinement", ROOT/"Cerebro/Resources/ShadowPlanner/qr_corner_refinement.py")
GENERATOR = load("printable_qr", ROOT/"Scripts/create-table-qr-target.py")


def synthetic(target="ROB:TABLE:001", corners=None, contrast=0.65, seed=4):
    if corners is None:
        corners = [[285, 117], [373, 116], [376, 177], [278, 177]]
    corners = np.array(corners, dtype=np.float32)
    reference, canonical = REFINE.template(target)
    h = cv2.getPerspectiveTransform(canonical, corners)
    image = cv2.warpPerspective(reference, h, (440, 300), borderValue=255)
    image = cv2.GaussianBlur(image, (5, 5), .7)
    rng = np.random.default_rng(seed)
    image = np.clip(image.astype(float)*contrast+20+np.linspace(0, 12, 440)[None, :]
                    + rng.normal(0, 1, image.shape), 0, 255).astype(np.uint8)
    initial = corners+rng.normal(0, .8, corners.shape)
    return image, initial, corners


class ExactPatternCornerTests(unittest.TestCase):
    def test_patterns_are_the_printed_patterns(self):
        for _, (payload, stem, *_) in GENERATOR.TARGETS.items():
            with self.subTest(payload=payload):
                np.testing.assert_array_equal(REFINE.symbol(payload), GENERATOR.make_symbol(payload))
                metadata = json.loads((ROOT/"output/pdf"/(stem+".json")).read_text())
                self.assertEqual(REFINE._PATTERNS[payload][0], metadata["pdfSHA256"])
                reference, _ = REFINE.template(payload)
                self.assertEqual(cv2.QRCodeDetector().detectAndDecode(reference)[0], payload)

    def test_known_physical_boundaries_with_perspective_blur_and_noise(self):
        postures = [None, [[160, 75], [260, 95], [270, 180], [145, 170]],
                    [[130, 90], [270, 60], [280, 190], [150, 230]]]
        for payload in REFINE._PATTERNS:
            for index, corners in enumerate(postures):
                with self.subTest(payload=payload, posture=index):
                    image, initial, actual = synthetic(payload, corners, seed=4+index)
                    refined, quality = REFINE.refine_image(image, initial, payload)
                    error = float(np.sqrt(np.mean(np.sum((refined-actual)**2, axis=1))))
                    self.assertLess(error, .3)
                    self.assertLess(error, float(np.sqrt(np.mean(np.sum((initial-actual)**2, axis=1)))))
                    self.assertGreaterEqual(quality["correlation"], REFINE.MINIMUM_CORRELATION)

    def test_wrong_exact_pattern_is_rejected(self):
        for actual in REFINE._PATTERNS:
            image, initial, _ = synthetic(actual)
            for requested in REFINE._PATTERNS:
                if requested != actual:
                    with self.subTest(actual=actual, requested=requested):
                        with self.assertRaises(ValueError):
                            REFINE.refine_image(image, initial, requested)

    def test_rotated_pages_resolve_printed_canonical_corners(self):
        image_order = np.array([[160, 75], [270, 80], [275, 195], [150, 190]], dtype=np.float32)
        for payload in REFINE._PATTERNS:
            for rotation in (1, 2, 3):
                with self.subTest(payload=payload, rotation=rotation):
                    printed_order = np.roll(image_order, -rotation, axis=0)
                    image, _, actual = synthetic(payload, printed_order, seed=15+rotation)
                    # Detector starts at the geometric image corner, not the
                    # printed QR's physical top-left after rotating the page.
                    initial = image_order+np.random.default_rng(22).normal(0, .5, image_order.shape)
                    refined, quality = REFINE.refine_image(image, initial, payload)
                    self.assertEqual(quality["rotationSteps"], rotation)
                    self.assertLess(float(np.sqrt(np.mean(np.sum((refined-actual)**2, axis=1)))), .3)
                    self.assertEqual(quality["bestCorrelation"], quality["correlation"])
                    runner = quality["runnerUpCorrelation"]
                    if runner is not None:
                        self.assertGreaterEqual(quality["bestCorrelation"]-runner, REFINE.MINIMUM_ORIENTATION_MARGIN)
                    ordered_initial = np.roll(initial, -rotation, axis=0)
                    np.testing.assert_allclose(quality["cornerDisplacementPixels"],
                                               np.linalg.norm(refined-ordered_initial, axis=1))

    def test_orientation_zero_keeps_the_original_numerical_fit(self):
        image, initial, _ = synthetic()
        valid = REFINE.corners_array(initial, image.shape[1], image.shape[0])
        original, original_quality = REFINE._refine_orientation(image, valid, "ROB:TABLE:001")
        refined, quality = REFINE.refine_image(image, initial, "ROB:TABLE:001")
        np.testing.assert_array_equal(refined, original)
        self.assertEqual(quality["rotationSteps"], 0)
        for key, value in original_quality.items():
            self.assertEqual(quality[key], value)

    def test_ambiguous_orientation_retains_raw_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            path, original = self.capture(Path(directory))
            scores = iter([.98, .97, .5, .4])
            with mock.patch.object(REFINE, "_refine_orientation",
                                   side_effect=lambda gray, ordered, target: (ordered, {"correlation": next(scores)})):
                result = REFINE.refine_capture(path, Path(directory)/"refined.json")
            self.assertEqual(result["cornerRefinement"]["acceptedViews"], 0)
            self.assertEqual(result["views"][0]["cornersPixels"], original["views"][0]["cornersPixels"])
            self.assertIn("ambiguous", result["views"][0]["cornerRefinement"]["reason"])

    def test_rotated_capture_preserves_raw_order_and_outputs_canonical_order(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            path, original = self.capture(directory)
            image_order = np.array([[160, 75], [270, 80], [275, 195], [150, 190]], dtype=np.float32)
            printed_order = np.roll(image_order, -2, axis=0)
            image, _, actual = synthetic(corners=printed_order)
            cv2.imwrite(str(directory/"sample-0.jpg"), image, [cv2.IMWRITE_JPEG_QUALITY, 98])
            original["views"][0]["cornersPixels"] = image_order.tolist()
            path.write_text(json.dumps(original))
            before = path.read_bytes()
            result = REFINE.refine_capture(path, directory/"refined.json")
            view = result["views"][0]
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(view["rawCornersPixelsBeforeRefinement"], image_order.tolist())
            self.assertEqual(view["cornerRefinement"]["rotationSteps"], 2)
            self.assertLess(float(np.sqrt(np.mean(np.sum((np.array(view["cornersPixels"])-actual)**2, axis=1)))), .3)

    def test_flat_or_low_contrast_is_rejected(self):
        image, initial, _ = synthetic(contrast=.03)
        with self.assertRaises(ValueError):
            REFINE.refine_image(image, initial, "ROB:TABLE:001")
        with self.assertRaises(ValueError):
            REFINE.refine_image(np.full_like(image, 150), initial, "ROB:TABLE:001")

    def test_bad_geometry_and_large_corrections_are_rejected(self):
        image, _, actual = synthetic()
        for corners in [actual[::-1], actual*0, actual+[-400, 0], [[1, 1], [4, 1], [4, 4], [1, 4]]]:
            with self.assertRaises(ValueError):
                REFINE.refine_image(image, corners, "ROB:TABLE:001")
        with self.assertRaises(ValueError):
            REFINE.refine_image(image, actual+[7, 0], "ROB:TABLE:001")

    def test_projective_center_is_diagonal_intersection(self):
        c = np.array([[10, 20], [80, 10], [100, 90], [0, 70]], dtype=float)
        center = REFINE.projective_center(c)
        diagonal = c[2]-c[0]
        delta = center-c[0]
        self.assertLess(abs(diagonal[0]*delta[1]-diagonal[1]*delta[0]), .001)
        self.assertGreater(np.linalg.norm(center-c.mean(axis=0)), 1.)

    def capture(self, folder, flat=False):
        image, initial, _ = synthetic()
        if flat:
            image[:] = 150
        cv2.imwrite(str(folder/"sample-0.jpg"), image, [cv2.IMWRITE_JPEG_QUALITY, 98])
        document = {"schemaVersion": 1, "targetID": "ROB:TABLE:001", "symbolSideMeters": .12,
                    "registrationVerified": False, "poseSource": "accepted_neck_commands",
                    "views": [{"id": "sample-0", "imageSize": [440, 300],
                               "cornersPixels": initial.tolist(), "cornersNormalized": [[.5, .5]]*4,
                               "centerPixel": [330, 150], "neckUpperTarget": 6036,
                               "cameraMatrix": [488., 488., 220., 150.], "centerDepthMeters": .7,
                               "estimatedMarkerCenterBase": [.5, .1, .8]}]}
        path = folder/"capture.json"
        path.write_text(json.dumps(document))
        return path, document

    def test_capture_copy_provenance_and_preserved_observations(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            path, original = self.capture(folder)
            before = path.read_bytes()
            output = folder/"refined.json"
            result = REFINE.refine_capture(path, output)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(result, json.loads(output.read_text()))
            self.assertEqual(result["cornerRefinement"]["sourceCaptureSHA256"], hashlib.sha256(before).hexdigest())
            self.assertEqual(result["cornerRefinement"]["acceptedViews"], 1)
            self.assertFalse(result["registrationVerified"])
            raw, view = original["views"][0], result["views"][0]
            for key in ("neckUpperTarget", "cameraMatrix", "centerDepthMeters", "estimatedMarkerCenterBase"):
                self.assertEqual(raw[key], view[key])
            self.assertEqual(raw["cornersPixels"], view["rawCornersPixelsBeforeRefinement"])
            for pixel, normal in zip(view["cornersPixels"], view["cornersNormalized"]):
                np.testing.assert_allclose(normal, [pixel[0]/440, 1-pixel[1]/300])
            with self.assertRaises(ValueError):
                REFINE.refine_capture(output, folder/"refined-again.json")

    def test_rejected_view_keeps_raw_corners(self):
        with tempfile.TemporaryDirectory() as folder:
            path, original = self.capture(Path(folder), flat=True)
            result = REFINE.refine_capture(path, Path(folder)/"refined.json")
            self.assertEqual(result["cornerRefinement"]["acceptedViews"], 0)
            self.assertEqual(result["views"][0]["cornersPixels"], original["views"][0]["cornersPixels"])
            self.assertEqual(result["views"][0]["cornerRefinement"]["status"], "rejected_raw_retained")

    def test_source_overwrite_unknown_pattern_and_unsafe_image_id_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path, original = self.capture(Path(folder))
            with self.assertRaises(ValueError):
                REFINE.refine_capture(path, path)
            for target, identifier in [("unknown", "sample-0"), ("ROB:TABLE:001", "../sample-0")]:
                original["targetID"] = target
                original["views"][0]["id"] = identifier
                path.write_text(json.dumps(original))
                with self.assertRaises(ValueError):
                    REFINE.refine_capture(path, Path(folder)/"refined.json")


if __name__ == "__main__":
    unittest.main()
