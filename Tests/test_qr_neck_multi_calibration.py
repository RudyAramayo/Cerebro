"""Synthetic shared-camera multi-target recovery and scene isolation tests."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
WORKER=ROOT/'Cerebro/Resources/ShadowPlanner/qr_neck_multi_calibration.py'
SPEC=importlib.util.spec_from_file_location('qr_neck_multi_calibration',WORKER)
MULTI=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MULTI)
JOINT=MULTI.JOINT;QR=JOINT.QR;MODEL=JOINT.NeckModel(WORKER.parent)


def dataset(marker_count=2):
    gains=np.array([1.3,1.15,1.7]);camera=MODEL.nominal_camera.copy()
    camera[:3,:3]=camera[:3,:3]@cv2.Rodrigues(np.array([-.08,.015,-.02]))[0]
    camera[:3,3]+=[.012,-.006,.018]
    horizontal=np.array([[0.,1,0],[-1,0,0],[0,0,1]])
    vertical=np.array([[0.,0,-1],[-1,0,0],[0,1,0]])
    definitions=[('ROB:FLOOR:L01',QR.transform(horizontal,[.55,.10,.78])),
                 ('ROB:FLOOR:R01',QR.transform(horizontal,[.55,-.10,.78])),
                 ('ROB:TABLE:001',QR.transform(horizontal,[.60,0,.84])),
                 ('ROB:WALL:R01',QR.transform(vertical,[.68,0,.85]))][:marker_count]
    matrix=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
    captures=[]
    for marker,(identifier,target) in enumerate(definitions):
        views=[];index=0
        for pi,pan in enumerate([-10.,0.,10.]):
            for li,lower in enumerate([5861,6011,6161]):
                for ui,upper in enumerate([6106,6256,6406]):
                    command=[pan,lower,upper];frame=MODEL.frames([command],gains)[0]
                    pose=JOINT.rigid_inverse(frame@camera)@target
                    pixels=cv2.projectPoints(QR.object_corners(),cv2.Rodrigues(pose[:3,:3])[0],pose[:3,3],matrix,np.zeros(5))[0].reshape(4,2)
                    assert np.min(pixels)>=0 and np.max(pixels[:,0])<2000 and np.max(pixels[:,1])<2000
                    view={'id':f'pose-{index}','training':(pi+li+ui)%4!=0,'targetID':identifier,
                          'cameraMatrix':[700.,700.,1000.,1000.],'imageSize':[2000,2000],'cornersPixels':pixels.tolist(),
                          'baseToNeck':MODEL.frames([command],[1.,1.,1.])[0].reshape(-1).tolist(),
                          'neckPanDegrees':pan,'lowerTarget':lower,'neckUpperTarget':upper,'centerDepthMeters':float(pose[2,3])}
                    views.append(view);index+=1
        document={'schemaVersion':1,'registrationVerified':False,'modelID':MODEL.model_id,'targetID':identifier,
                  'symbolSideMeters':.12,'surveySessionID':'synthetic-session','sceneContextID':'synthetic-scene','views':views}
        captures.append({'targetID':identifier,'document':document,'captureStatus':'complete'})
    return captures,gains,camera,definitions


class MultiNeckCalibrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.captures,cls.gains,cls.camera,cls.targets=dataset(4)
        cls.result=MULTI.fit(cls.captures,MODEL,starts=[[1.2,1.2,1.6]],maximum_iterations=120)

    def test_shared_metric_recovery_for_four_independent_marker_poses(self):
        result=self.result
        np.testing.assert_allclose(list(result['scales'].values()),self.gains,atol=2e-4)
        np.testing.assert_allclose(np.array(result['upperNeckToOpticalCamera']).reshape(4,4),self.camera,atol=5e-5)
        self.assertEqual(result['targetCount'],4)
        for marker,(_,target) in zip(result['markers'],self.targets):
            np.testing.assert_allclose(np.array(marker['baseToFixedTarget']).reshape(4,4),target,atol=5e-5)
            self.assertLess(marker['heldOutReprojectionRMSEPixels'],1e-5)
            self.assertLess(marker['heldOutDepthCenterResidualRMSEMeters'],1e-6)
        self.assertFalse(result['registrationVerified']);self.assertFalse(result['candidateURDFReady'])
        self.assertEqual(result['identifiability']['parameterCount'],33)
        self.assertTrue(result['identifiability']['conditionalCovarianceFullRank'])
        self.assertFalse(result['surfaceValidation']['constraintsAppliedToFit'])
        self.assertLess(result['surfaceValidation']['floorLeftRight']['leftPlaneToRightCenterMeters'],1e-6)
        for angle in result['surfaceValidation']['wallToFloorAnglesDegrees'].values():self.assertAlmostEqual(angle,90.,places=4)

    def test_held_out_marker_errors_do_not_change_the_shared_fit(self):
        original,_,_,_=dataset(2);before=MULTI.fit(original,MODEL,starts=[[1.2,1.2,1.6]],maximum_iterations=120)
        changed=copy.deepcopy(original)
        for item in changed:
            for view in item['document']['views']:
                if not view['training']:
                    view['cornersPixels']=(np.array(view['cornersPixels'])+[2.,-.7]).tolist();view['centerDepthMeters']+=.04
        after=MULTI.fit(changed,MODEL,starts=[[1.2,1.2,1.6]],maximum_iterations=120)
        np.testing.assert_allclose(list(before['parameters'].values()),list(after['parameters'].values()),atol=1e-9)
        self.assertGreater(after['heldOutReprojectionRMSEPixels'],1.)
        self.assertGreater(after['markers'][0]['heldOutDepthCenterResidualRMSEMeters'],.039)

    def test_global_pose_split_cannot_leak_between_markers(self):
        captures,_,_,_=dataset(2);captures[1]['document']['views'][0]['training']=not captures[0]['document']['views'][0]['training']
        with self.assertRaisesRegex(ValueError,'both training and held-out'):MULTI.prepare(captures,MODEL)
        captures,_,_,_=dataset(2)
        for item in captures:
            for view in item['document']['views']:view['lowerTarget']=6011
        with self.assertRaises(ValueError):MULTI.prepare(captures,MODEL)

    def test_imu_is_independent_diagnostic_and_rejects_stale_windows(self):
        captures,_,_,_=dataset(2)
        data=MULTI.prepare(captures,MODEL);view=copy.deepcopy(data['originalViews'][0]);pose=data['poses'][0]
        normal=pose['targetToCamera'][:3,2]
        factory=np.diag([1.,-1.,-1.])
        view['imu']={'sensor':'synthetic IMU','stationary':True,'axes':'sensor_native',
                     'gravity_source':'stationary_accelerometer_mean','gravity_mps2':(factory.T@normal*9.5).tolist(),
                     'imu_to_rgb_rotation':factory.reshape(-1).tolist(),'age_milliseconds':20.,'sample_count':20}
        result=MULTI.imu_validation(view,pose)
        self.assertEqual(result['status'],'stationary_observation_unverified')
        self.assertAlmostEqual(result['accelerationNormMetersPerSecondSquared'],9.5)
        self.assertLess(result['qrNormalVersusImuUnsignedDegrees'],1e-5)
        self.assertFalse(result['usedInOptimization'])
        view['imu']['age_milliseconds']=2000.
        self.assertEqual(MULTI.imu_validation(view,pose)['status'],'unavailable')
        self.assertIsNone(MULTI.imu_validation({},pose))

    def manifest(self,folder):
        captures,_,_,_=dataset(2);entries=[]
        for i,item in enumerate(captures):
            path=folder/f'capture-{i}.json';path.write_text(json.dumps(item['document']))
            entries.append({'targetID':item['targetID'],'capturePath':str(path),'status':'complete','samples':len(item['document']['views'])})
        manifest={'schemaVersion':1,'captureKind':'multi_target_neck_survey','robotBaseStationary':True,
                  'registrationVerified':False,'sessionID':'synthetic-session','sceneContextID':'synthetic-scene','captures':entries}
        path=folder/'survey.json';path.write_text(json.dumps(manifest));return path,manifest

    def test_manifest_requires_unique_supported_targets_and_same_fresh_scene(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);path,document=self.manifest(folder)
            manifest,_,captures,protected=MULTI.load_manifest(path)
            self.assertEqual(len(captures),2);self.assertEqual(len(protected),3)
            for mutation in [lambda d:d['captures'][1].update(targetID=d['captures'][0]['targetID']),
                             lambda d:d.update(robotBaseStationary=False),lambda d:d.update(sceneContextID='another-scene'),
                             lambda d:d['captures'][0].update(samples=99)]:
                changed=copy.deepcopy(document);mutation(changed);path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):MULTI.load_manifest(path)

    def test_cli_preserves_capture_inputs_and_protected_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);path,document=self.manifest(folder);capture=Path(document['captures'][0]['capturePath']);original=capture.read_bytes()
            process=subprocess.run([sys.executable,str(WORKER),str(path),str(capture)],capture_output=True,text=True)
            self.assertEqual(process.returncode,2);self.assertEqual(capture.read_bytes(),original)
            path.write_text('{"schemaVersion":NaN}')
            process=subprocess.run([sys.executable,str(WORKER),str(path),str(capture)],capture_output=True,text=True)
            self.assertEqual(process.returncode,2);self.assertEqual(capture.read_bytes(),original)
            forbidden=WORKER.parent/'must-not-create-multi-fit.json'
            process=subprocess.run([sys.executable,str(WORKER),str(path),str(forbidden)],capture_output=True,text=True)
            self.assertEqual(process.returncode,2);self.assertFalse(forbidden.exists())


if __name__=='__main__':unittest.main()
