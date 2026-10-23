"""Bias/anisotropy-tolerant IMU frequency profile tests; no robot IO."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

ROOT=Path(__file__).resolve().parents[1];WORKER=ROOT/'Cerebro/Resources/ShadowPlanner/qr_neck_imu_report.py'
SPEC=importlib.util.spec_from_file_location('qr_neck_imu_report',WORKER);IMU=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(IMU)


def dataset():
    slope=.0567;records=[];matrix=np.array([[1.03,.02,.01],[.01,.96,.02],[.015,-.01,1.01]])
    for pan in [-40.,0.,40.]:
        bias=np.array([.25+pan*.002,-.4,.3]);u=matrix@np.array([0.,8.,0.]);v=matrix@np.array([0.,0.,8.])
        for upper in [5300,5700,6306,6906,7300]:
            angle=np.radians(slope*(upper-5300));a=bias+u*np.cos(angle)+v*np.sin(angle)
            for repeat in range(2):
                view={'schemaVersion':1,'neckPanDegrees':pan,'lowerTarget':6011,'neckUpperTarget':upper,
                      'imu':{'gravity_mps2':a.tolist(),'gyro_rad_s':[.001,.001,.001],'gravity_std_mps2':[.01,.01,.01],
                             'axes':'sensor_native','gravity_source':'stationary_accelerometer_mean','stationary':True,
                             'age_milliseconds':8.,'window_milliseconds':490.,'sample_count':50}}
                records.append({'view':view,'sourceKind':'discovery'})
    return records,slope


class NeckImuReportTests(unittest.TestCase):
    def test_recovers_shared_scale_despite_unknown_bias_and_ellipse(self):
        records,actual=dataset();report=IMU.analyze(records)
        self.assertEqual(report['status'],'imu_upper_profile_unverified')
        self.assertAlmostEqual(report['upperDegreesPerTargetUnit'],actual,delta=1e-7)
        self.assertLess(report['heldOutVectorRMSEMetersPerSecondSquared'],1e-7)
        self.assertEqual(report['usableGroupCount'],3)
        self.assertTrue(report['frequencyIdentifiableConditionally'])
        self.assertFalse(report['registrationVerified']);self.assertFalse(report['candidateURDFReady'])
        self.assertIsNone(report['assumedGravityMagnitude']);self.assertFalse(report['cameraIntrinsicsUsed'])
        for group in report['groups']:
            self.assertEqual(group['heldOutUpperLevels'],[6306])
            self.assertEqual(group['designRank'],3)
            self.assertGreater(group['ellipseAxisRatio'],1.01)
            comparison=next(entry for entry in group['naiveVersusProfileAngles'] if not entry['includedInTraining'])
            self.assertGreater(abs(comparison['profileAngleChangeDegrees']-comparison['naiveUnitAccelerationDirectionChangeDegrees']),.1)

    def test_held_out_whole_level_and_extra_target_records_do_not_tune_frequency(self):
        records,_=dataset();before=IMU.analyze(records);changed=copy.deepcopy(records)
        for record in changed:
            if record['view']['neckUpperTarget']==6306:
                record['view']['imu']['gravity_mps2'][1]+=.3
        extra=copy.deepcopy(changed[0]);extra['sourceKind']='target_capture';extra['view']['neckUpperTarget']=6100
        changed.append(extra);after=IMU.analyze(changed)
        self.assertEqual(before['upperDegreesPerTargetUnit'],after['upperDegreesPerTargetUnit'])
        self.assertGreater(after['heldOutVectorRMSEMetersPerSecondSquared'],.1)
        self.assertIn(6100,after['groups'][0]['heldOutUpperLevels'])

    def test_narrow_coverage_and_bad_windows_are_reported(self):
        records,_=dataset()
        for record in records:record['view']['neckUpperTarget']=6000+(record['view']['neckUpperTarget']-5300)//10
        report=IMU.analyze(records);self.assertEqual(report['status'],'imu_upper_profile_unavailable')
        records,_=dataset();records[0]['view']['imu']['age_milliseconds']=2000;records[1]['view']['imu']['gyro_rad_s']=[1.,0.,0.]
        report=IMU.analyze(records);self.assertEqual(report['rejectedRecordCount'],2)

    def test_constant_sensor_vector_has_no_identifiable_rotation_frequency(self):
        records,_=dataset()
        for record in records:record['view']['imu']['gravity_mps2']=[0.,7.,7.]
        report=IMU.analyze(records)
        self.assertEqual(report['status'],'imu_upper_profile_unidentifiable')
        self.assertFalse(report['frequencyIdentifiableConditionally'])

    def test_cli_keeps_input_and_discovery_records_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);source=folder/'capture.json';source.write_text('{"schemaVersion":1,"views":[]}')
            original=source.read_bytes()
            process=subprocess.run([sys.executable,str(WORKER),str(source),str(source)],capture_output=True,text=True)
            self.assertEqual(process.returncode,2);self.assertEqual(source.read_bytes(),original)
            manifest=folder/'survey.json';manifest.write_text(json.dumps({'schemaVersion':1,'captureKind':'multi_target_neck_survey','robotBaseStationary':True,'sessionID':'test','sceneContextID':'test','captures':[]}))
            record=folder/'discovery-0-0.json';record.write_text(json.dumps(dataset()[0][0]['view']));original=record.read_bytes()
            process=subprocess.run([sys.executable,str(WORKER),str(manifest),str(record)],capture_output=True,text=True)
            self.assertEqual(process.returncode,2);self.assertEqual(record.read_bytes(),original)


if __name__=='__main__':unittest.main()
