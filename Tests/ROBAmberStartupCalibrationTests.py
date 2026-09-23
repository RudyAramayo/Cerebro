"""Synthetic camera/encoder trials only; never connect to robot hardware."""
import copy
import importlib.util
import math
from pathlib import Path
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "startup_calibration", ROOT / "Cerebro/Resources/ShadowPlanner/startup_calibration.py")
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)


class StartupCalibrationTests(unittest.TestCase):
    def trial(self):
        self.zero = np.array([.1, -.2, .05, -.1, .03, -.02, .07])
        self.direction = np.array([1, -1, 1, -1, 1, -1, 1])
        identity = dict(arm="right", modelID="model-fixture", referenceID="scan-fixture", controllerSession="boot-fixture")
        sequence, command, now = 0, 0, 1000.
        def endpoint(target):
            nonlocal sequence, command, now
            command += 1
            acknowledged = now
            samples = []
            for _ in range(3):
                sequence += 1; now += 250
                samples.append(dict(identity, source="markerless_rgbd", status="confirmed", camera="belly", streamID="camera-fixture",
                    frameSequence=sequence, telemetrySequence=sequence, commandID=command, commandAccepted=True,
                    cameraCapturedAtMilliseconds=now, telemetrySampledAtMilliseconds=now, receivedAtMilliseconds=now+20,
                    commandAcknowledgedAtMilliseconds=acknowledged, cameraRegistrationRMS=.003, residualMeters=.004,
                    measuredVendorRadians=list(target), commandedVendorRadians=list(target),
                    observedModelRadians=(self.direction*(target-self.zero)).tolist(), standardDeviationRadians=[.001]*7))
            return samples
        baseline = np.array([.2]*7)
        record = dict(identity, schemaVersion=1, binding=calibration.SIDES["right"].copy(), baseline=endpoint(baseline), wiggles=[])
        for joint in range(7):
            plus=baseline.copy(); plus[joint]+=.04
            minus=baseline.copy(); minus[joint]-=.04
            record["wiggles"].append(dict(joint=joint+1, plus=endpoint(plus), minus=endpoint(minus), **{"return":endpoint(baseline)}))
        validation=baseline.copy(); validation[1]-=.03
        record["validation"]=endpoint(validation)
        return record

    def test_mixed_directions_and_offsets_recovered_without_return_to_zero(self):
        report=calibration.assess(self.trial())
        self.assertTrue(report["accepted"], report["detail"])
        np.testing.assert_allclose(report["vendorAtModelZeroRadians"], self.zero, atol=1e-12)
        np.testing.assert_array_equal(report["direction"], self.direction)
        self.assertEqual(report["distinctCameraFrames"], 69)
        self.assertFalse(report["hardwareOutputEnabled"])

    def test_ignored_command_is_not_treated_as_movement(self):
        record=self.trial()
        for sample in record["wiggles"][5]["plus"]:
            sample["measuredVendorRadians"][5]=.2
        self.assert_rejected(record, "not reached")

    def test_ambiguous_or_unseen_wrist_is_not_zero_error(self):
        record=self.trial()
        for sample in record["wiggles"][6]["plus"]:
            sample["observedModelRadians"][6]=self.direction[6]*(.2-self.zero[6])
        self.assert_rejected(record, "scale disagrees")
        record=self.trial()
        record["wiggles"][6]["plus"][0]["status"]="ambiguous"
        self.assert_rejected(record, "Unconfirmed")

    def test_noisy_camera_cannot_pass_precise_calibration(self):
        record=self.trial()
        record["baseline"][0]["standardDeviationRadians"][1]=math.radians(5)
        self.assert_rejected(record, "uncertainty")

    def test_duplicate_frames_and_telemetry_are_rejected(self):
        for key in ("frameSequence", "telemetrySequence"):
            record=self.trial()
            record["validation"][0][key]=record["baseline"][0][key]
            self.assert_rejected(record, "reused")

    def test_stale_or_unsynchronized_samples_are_rejected(self):
        record=self.trial()
        record["baseline"][0]["cameraCapturedAtMilliseconds"]-=500
        self.assert_rejected(record, "synchronized")
        record=self.trial()
        record["baseline"][0]["receivedAtMilliseconds"]+=1000
        self.assert_rejected(record, "Stale")

    def test_endpoints_cannot_reuse_commands_or_reorder_capture_times(self):
        record=self.trial()
        for sample in record["validation"]:
            sample["commandID"]=record["baseline"][0]["commandID"]
        self.assert_rejected(record,"distinct commands")
        record=self.trial()
        for sample in record["validation"]:
            for key in ("cameraCapturedAtMilliseconds","telemetrySampledAtMilliseconds",
                        "receivedAtMilliseconds","commandAcknowledgedAtMilliseconds"):
                sample[key]-=15000
        self.assert_rejected(record,"capture-time order")

    def test_wrong_arm_or_session_is_rejected(self):
        for key,value in (("arm","left"),("controllerSession","another-boot"),("modelID","new-model")):
            record=self.trial(); record["baseline"][0][key]=value
            self.assert_rejected(record, "changed")
        record=self.trial(); record["binding"]["gatewayArm"]="right"
        self.assert_rejected(record, "binding")

    def test_camera_motion_after_fitting_fails_held_out_validation(self):
        record=self.trial()
        for sample in record["validation"]:
            sample["observedModelRadians"][2]+=.1
        self.assert_rejected(record, "Held-out")

    def test_fit_frames_cannot_be_reused_as_validation(self):
        record=self.trial(); record["validation"]=copy.deepcopy(record["baseline"])
        self.assert_rejected(record, "reused")

    def test_previous_offset_is_compared_but_never_used_as_evidence(self):
        record=self.trial(); previous=calibration.assess(record)
        previous["controllerSession"]="previous-boot"
        previous["vendorAtModelZeroRadians"][1]+=.1
        result=calibration.assess(record,previous)
        self.assertTrue(result["accepted"])
        self.assertAlmostEqual(result["offsetChangeRadians"][1],-.1)
        self.assertEqual(result["previousControllerSession"],"previous-boot")
        previous["modelID"]="different-geometry"
        result=calibration.assess(record,previous)
        self.assertFalse(result["accepted"])
        self.assertNotIn("vendorAtModelZeroRadians",result)

    def test_preview_has_bounded_single_joint_wiggles_and_no_zero_reset(self):
        route=[dict(name="clearance", positions=[0,-.3,0,0,0,0,0]),
               dict(name="inspection", positions=[0,-.65,0,0,0,0,0])]
        plan=calibration.preview_steps([0]*7,route)
        self.assertFalse(plan["hardwareOutputEnabled"])
        self.assertFalse(plan["returnToB1Zero"])
        previous=np.zeros(7)
        for step in plan["steps"]:
            if step["phase"]=="present":
                self.assertLessEqual(max(abs(np.array(step["positions"])-previous)),math.radians(3)+1e-12)
                previous=np.array(step["positions"])
            if step["phase"] in ("plus","minus"):
                self.assertEqual(np.count_nonzero(np.array(step["positions"])-[0,-.65,0,0,0,0,0]),1)
        with self.assertRaises(ValueError):
            calibration.preview_steps([0]*7,[route[0],dict(name="inspection", positions=[0,-2.32,0,0,0,0,0])])

    def test_preview_preserves_clearance_route_before_moving_extremities(self):
        clearance=[0,-.3,0,0,0,0,0]
        inspection=[0,-.3,0,0,0,.5,0]
        plan=calibration.preview_steps([0]*7,[dict(name="clearance",positions=clearance),
                                            dict(name="wrist",positions=inspection)])
        self.assertFalse(plan["clearanceVerified"])
        self.assertTrue(plan["requiresSegmentValidation"])
        endpoints=[s for s in plan["steps"] if s.get("stopAndVerify")]
        self.assertEqual([s["waypointName"] for s in endpoints],["clearance","wrist"])
        np.testing.assert_allclose(endpoints[0]["positions"],clearance)
        np.testing.assert_allclose(endpoints[1]["positions"],inspection)
        for step in plan["steps"]:
            if step.get("waypointName")=="clearance":
                self.assertEqual(step["positions"][5],0)

    def test_preview_rejects_an_endpoint_without_clearance_waypoints(self):
        endpoint=[0,-.207477,.922961,-.816727,.976605,1.644858,-.284677]
        for route in (endpoint,[dict(name="folded",positions=endpoint)],[]):
            with self.subTest(route=route),self.assertRaises(ValueError):
                calibration.preview_steps([0]*7,route)

    def assert_rejected(self, record, detail):
        report=calibration.assess(record)
        self.assertFalse(report["accepted"],report)
        self.assertIn(detail,report["detail"])
        self.assertNotIn("vendorAtModelZeroRadians",report)


if __name__=="__main__":
    unittest.main()
