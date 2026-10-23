"""Synthetic metric tests of bounded URDF neck reprojection fitting."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT/'Cerebro/Resources/ShadowPlanner'
WORKER = DIRECTORY/'qr_neck_joint_calibration.py'
SPEC = importlib.util.spec_from_file_location('qr_neck_joint_calibration', WORKER)
JOINT = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(JOINT)
MODEL = JOINT.NeckModel(DIRECTORY)
QR = JOINT.QR


def dataset():
    gains = np.array([1.3, 1.15, 1.7])
    camera = MODEL.nominal_camera.copy()
    camera[:3, :3] = camera[:3, :3] @ cv2.Rodrigues(np.array([-.08, .015, -.02]))[0]
    camera[:3, 3] += [.012, -.006, .018]
    target = QR.transform(np.array([[0., 1, 0], [-1, 0, 0], [0, 0, 1]]), [.55, .02, .78])
    views = []
    matrix = np.array([[700., 0, 640], [0, 700., 400], [0, 0, 1.]])
    index = 0
    for pi, pan in enumerate([-10., 0., 10.]):
        for li, lower in enumerate([5861, 6011, 6161]):
            for ui, upper in enumerate([6106, 6256, 6406]):
                command = [pan, lower, upper]
                frame = MODEL.frames([command], gains)[0]
                target_camera = JOINT.rigid_inverse(frame @ camera) @ target
                points = (target_camera[:3, :3] @ QR.object_corners().T).T+target_camera[:3, 3]
                assert np.min(points[:, 2]) > .05
                pixels = cv2.projectPoints(QR.object_corners(), cv2.Rodrigues(target_camera[:3, :3])[0],
                                           target_camera[:3, 3], matrix, np.zeros(5))[0].reshape(4, 2)
                # The calibration camera dimensions are intentionally generous
                # so all generated metric poses remain visible.
                assert np.min(pixels) >= 0 and np.max(pixels[:, 0]) < 1280 and np.max(pixels[:, 1]) < 1000
                train = (pi+li+ui) % 4 != 0
                for sample in range(2):
                    view = {'id': f'pose-{index}-{sample}', 'training': train, 'targetID': 'ROB:TABLE:001',
                            'cameraMatrix': [700., 700., 640., 400.], 'imageSize': [1280, 1000],
                            'cornersPixels': pixels.tolist(), 'baseToNeck': MODEL.frames([command], [1., 1., 1.])[0].reshape(-1).tolist(),
                            'neckPanDegrees': pan, 'lowerTarget': lower, 'neckUpperTarget': upper,
                            'centerDepthMeters': float(target_camera[2, 3])}
                    views.append(view)
                index += 1
    return {'schemaVersion': 1, 'targetID': 'ROB:TABLE:001', 'symbolSideMeters': .12,
            'modelID': MODEL.model_id, 'poseSource': 'synthetic_known_geometry', 'views': views}, gains, camera, target


class JointNeckCalibrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document, cls.gains, cls.camera, cls.target = dataset()
        cls.result = JOINT.fit(cls.document, MODEL, starts=[[1.2, 1.2, 1.6]], maximum_iterations=120)

    def test_metric_gain_and_transform_recovery_under_fixed_zero_gauges(self):
        result = self.result
        np.testing.assert_allclose(list(result['scales'].values()), self.gains, atol=2e-4)
        np.testing.assert_allclose(np.array(result['upperNeckToOpticalCamera']).reshape(4, 4), self.camera, atol=5e-5)
        np.testing.assert_allclose(np.array(result['baseToFixedTarget']).reshape(4, 4), self.target, atol=5e-5)
        self.assertLess(result['trainingReprojectionRMSEPixels'], 1e-5)
        self.assertLess(result['heldOutReprojectionRMSEPixels'], 1e-5)
        self.assertLess(result['heldOutDepthCenterResidualRMSEMeters'], 1e-6)
        self.assertFalse(result['registrationVerified'])
        self.assertFalse(result['candidateURDFReady'])
        self.assertFalse(result['gauge']['zerosAreMeasured'])
        self.assertFalse(result['identifiability']['covarianceIsHardwareUncertainty'])
        self.assertEqual(result['gauge']['fixedUpperZeroTarget'], 6906)
        self.assertTrue(result['gauge']['panZeroIsAssumedRatherThanExactGauge'])
        self.assertTrue(result['identifiability']['conditionalCovarianceFullRank'])

    def test_held_out_pose_errors_never_change_training_solution(self):
        changed = copy.deepcopy(self.document)
        for view in changed['views']:
            if not view['training']:
                view['cornersPixels'] = (np.array(view['cornersPixels'])+[2., -.7]).tolist()
                view['centerDepthMeters'] += .04
        result = JOINT.fit(changed, MODEL, starts=[[1.2, 1.2, 1.6]], maximum_iterations=120)
        np.testing.assert_allclose(list(result['parameters'].values()), list(self.result['parameters'].values()), atol=1e-10)
        self.assertGreater(result['heldOutReprojectionRMSEPixels'], 1.)
        self.assertGreater(result['heldOutDepthCenterResidualRMSEMeters'], .039)

    def test_exact_urdf_zero_chain_and_swift_pitch_direction(self):
        zero = MODEL.frames([[0., 6011, 6906]], [1., 1., 1.])[0]
        np.testing.assert_allclose(zero[:3, 3], [-.1043293876731, 0., 1.041734984780], atol=1e-10)
        np.testing.assert_allclose(zero[:3, :3], np.eye(3), atol=1e-12)
        moved = MODEL.frames([[0., 6011, 7006]], [1., 1., 1.])[0]
        delta = cv2.Rodrigues(zero[:3, :3].T @ moved[:3, :3])[0].reshape(3)
        self.assertAlmostEqual(math.degrees(delta[1]), -3., places=8)

    def test_missing_axis_excitation_and_pose_split_leakage_are_rejected(self):
        changed = copy.deepcopy(self.document)
        for view in changed['views']:
            view['lowerTarget'] = 6011
        with self.assertRaises(ValueError):
            JOINT.prepare(changed, MODEL)
        changed = copy.deepcopy(self.document)
        changed['views'][1]['training'] = not changed['views'][0]['training']
        with self.assertRaisesRegex(ValueError, 'both training and held-out'):
            JOINT.prepare(changed, MODEL)
        changed = copy.deepcopy(self.document); changed['modelID'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'identity'):
            JOINT.prepare(changed, MODEL)

    def test_cli_preserves_input_and_protected_model_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)/'capture.json'
            original = '{"schemaVersion":1}'
            source.write_text(original)
            process = subprocess.run([sys.executable, str(WORKER), str(source), str(source)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            self.assertEqual(source.read_text(), original)
            protected = DIRECTORY/'test-output-that-must-not-be-created.json'
            self.assertFalse(protected.exists())
            process = subprocess.run([sys.executable, str(WORKER), str(source), str(protected)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            self.assertFalse(protected.exists())

    def test_cli_rejects_invalid_json_without_model_material(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, out = Path(temporary)/'in.json', Path(temporary)/'out.json'
            source.write_text('{"schemaVersion":NaN}')
            process = subprocess.run([sys.executable, str(WORKER), str(source), str(out)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            result = json.loads(out.read_text())
            self.assertEqual(result['status'], 'rejected')
            self.assertFalse(result['candidateURDFReady'])


if __name__ == '__main__':
    unittest.main()
