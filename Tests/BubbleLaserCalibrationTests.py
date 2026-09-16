import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np

spec = importlib.util.spec_from_file_location("detector", Path(__file__).resolve().parents[1] / "Cerebro/BubbleLaserCalibration.py")
detector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(detector)


class LaserTests(unittest.TestCase):
    def mat(self):
        image = np.full((480, 640, 3), (65, 95, 55), np.uint8)
        for x in range(100, 501, 50):
            cv2.line(image, (x, 100), (x, 350), (170, 185, 165), 1)
        for y in range(100, 351, 50):
            cv2.line(image, (100, y), (500, y), (170, 185, 165), 1)
        return image

    quad = [[100, 100], [500, 100], [500, 350], [100, 350]]

    def analyze(self, image, background=None):
        return detector.analyze(image, quad=self.quad, background=background)[0]

    def test_one_inch_grid_and_dot(self):
        off = self.mat(); on = off.copy()
        cv2.circle(on, (300, 200), 4, (0, 0, 255), -1)
        result = self.analyze(on, off)
        self.assertEqual(result["laser"]["status"], "found")
        p = result["laser"]["point"]
        self.assertAlmostEqual(p["matXMM"], 4 * 25.4, delta=.2)
        self.assertAlmostEqual(p["matYMM"], 2 * 25.4, delta=.2)
        self.assertAlmostEqual(p["u"], 300 / 639, delta=.002)

    def test_white_hot_core(self):
        off = self.mat(); on = off.copy()
        cv2.circle(on, (300, 225), 7, (15, 10, 255), -1)
        cv2.circle(on, (300, 225), 4, (255, 255, 255), -1)
        p = self.analyze(on, off)["laser"]["point"]
        self.assertAlmostEqual(p["x"], 300, delta=.5)
        self.assertAlmostEqual(p["y"], 225, delta=.5)

    def test_dot_at_grid_corners_is_not_clipped(self):
        for x, y in self.quad:
            off = self.mat(); on = off.copy()
            cv2.circle(on, (x, y), 7, (10, 10, 255), -1)
            cv2.circle(on, (x, y), 3, (255, 255, 255), -1)
            point = self.analyze(on, off)["laser"]["point"]
            self.assertAlmostEqual(point["x"], x, delta=.1)
            self.assertAlmostEqual(point["y"], y, delta=.1)

    def test_hue_wrap(self):
        off = self.mat(); on = off.copy()
        color = cv2.cvtColor(np.uint8([[[175, 220, 255]]]), cv2.COLOR_HSV2BGR)[0, 0]
        cv2.circle(on, (220, 210), 4, tuple(map(int, color)), -1)
        self.assertEqual(self.analyze(on, off)["laser"]["status"], "found")

    def test_static_printing_removed(self):
        off = self.mat()
        cv2.circle(off, (180, 180), 5, (0, 0, 255), -1)
        on = off.copy(); cv2.circle(on, (350, 250), 5, (0, 0, 255), -1)
        self.assertEqual(self.analyze(on, off)["laser"]["status"], "found")
        self.assertEqual(self.analyze(off, off)["laser"]["status"], "not_found")

    def test_ambiguous_reflections_are_not_selected(self):
        off = self.mat(); on = off.copy()
        for p in [(220, 180), (390, 250)]:
            cv2.circle(on, p, 5, (0, 0, 255), -1)
        laser = self.analyze(on, off)["laser"]
        self.assertEqual(laser["status"], "ambiguous")
        self.assertNotIn("point", laser)

    def test_off_mat_dot_and_large_red_patch(self):
        on = self.mat()
        cv2.circle(on, (40, 40), 4, (0, 0, 255), -1)
        cv2.rectangle(on, (180, 170), (270, 280), (0, 0, 255), -1)
        self.assertEqual(self.analyze(on)["laser"]["status"], "not_found")

    def test_moved_mat_requires_new_reference(self):
        off = self.mat()
        on = cv2.warpAffine(off, np.float32([[1, 0, 8], [0, 1, 7]]), (640, 480))
        self.assertEqual(self.analyze(on, off)["laser"]["status"], "reference_changed")

    def test_perspective_grid(self):
        q = [[140, 90], [460, 120], [520, 370], [90, 330]]
        board = detector.grid(self.mat(), 9, 6, 25.4, q)
        h = np.array(board["imageToMat"])
        recovered = cv2.perspectiveTransform(np.array(q, np.float32).reshape(-1, 1, 2), h).reshape(-1, 2)
        np.testing.assert_allclose(recovered, [[0, 0], [203.2, 0], [203.2, 127], [0, 127]], atol=.01)

    def test_invalid_inputs(self):
        for q in ([[0, 0]] * 4, [[1, 1], [500, 350], [500, 1], [1, 350]], [[float("nan"), 2]] * 4):
            with self.assertRaises(ValueError):
                detector.grid(self.mat(), 9, 6, 25.4, q)
        with self.assertRaises(ValueError):
            detector.detect_red_dot(self.mat(), np.zeros((40, 40, 3), np.uint8))

    def test_other_colors_and_sensor_noise(self):
        off = self.mat(); on = off.copy()
        for center, color in [((200, 200), (255, 255, 255)), ((300, 200), (255, 0, 0)),
                              ((400, 200), (0, 255, 0))]:
            cv2.circle(on, center, 5, color, -1)
        on[130, 130] = (0, 0, 255)  # One noisy red pixel is not a dot.
        self.assertEqual(self.analyze(on, off)["laser"]["status"], "not_found")

    def test_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            off = self.mat(); on = off.copy()
            cv2.circle(on, (300, 200), 6, (10, 10, 255), -1)
            cv2.imwrite(str(root / "off.png"), off)
            cv2.imwrite(str(root / "on.png"), on)
            result = subprocess.run([sys.executable, spec.origin, "--image", str(root / "on.png"),
                "--background", str(root / "off.png"), "--quad", json.dumps(self.quad),
                "--output", str(root / "result.json"), "--annotated", str(root / "overlay.png"),
                "--mask", str(root / "mask.png")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = json.loads((root / "result.json").read_text())
            self.assertEqual(saved["laser"]["status"], "found")
            self.assertEqual(cv2.imread(str(root / "overlay.png")).shape, on.shape)
            self.assertEqual(cv2.imread(str(root / "mask.png"), 0)[200, 300], 255)


if __name__ == "__main__":
    if "--fixture-dir" in sys.argv:
        index = sys.argv.index("--fixture-dir")
        root = Path(sys.argv[index + 1]); root.mkdir(parents=True, exist_ok=True)
        off = LaserTests().mat(); on = off.copy()
        cv2.circle(on, (300, 200), 7, (10, 10, 255), -1)
        cv2.circle(on, (300, 200), 3, (255, 255, 255), -1)
        cv2.imwrite(str(root / "laser-off.png"), off)
        cv2.imwrite(str(root / "laser-on.png"), on)
        del sys.argv[index:index+2]
    unittest.main()
