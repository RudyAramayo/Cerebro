"""Offline shared-surface bundle recovery, gauge and held-out isolation."""
import copy
import importlib.util
import math
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
DIRECTORY=ROOT/'Cerebro/Resources/ShadowPlanner'
SPEC=importlib.util.spec_from_file_location('constrained_bundle_test',DIRECTORY/'qr_neck_constrained_bundle.py')
BUNDLE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(BUNDLE)
MODEL=BUNDLE.MeasuredOrderModel(DIRECTORY)
QR=BUNDLE.QR


def dataset():
    gains=[1.9,1.7,1.8]
    camera=MODEL.nominal_camera.copy()
    camera[:3,:3]=camera[:3,:3]@cv2.Rodrigues(np.array([-.08,.015,-.02]))[0]
    camera[:3,3]=[.11,.006,.12]
    MODEL.lower_offset=-.2
    tilt=cv2.Rodrigues(np.array([.04,.03,0.]))[0]
    gravity=tilt@np.array([0.,0.,1.])
    horizontal=tilt@np.array([[0.,1,0],[-1,0,0],[0,0,1.]])
    definitions=[('ROB:FLOOR:L01',QR.transform(horizontal,tilt@np.array([.55,.10,0.]))),
                 ('ROB:FLOOR:R01',QR.transform(horizontal,tilt@np.array([.55,-.10,0.]))),
                 ('ROB:TABLE:001',QR.transform(horizontal,tilt@np.array([.60,0.,.10])))]
    K=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
    captures=[]
    for identifier,target in definitions:
        views=[]
        for pi,pan in enumerate([-8.,0.,8.]):
            for li,lower in enumerate([5861,6011,6161]):
                for ui,upper in enumerate([5906,6056,6206]):
                    command=[pan,lower,upper]
                    frame=MODEL.frames([command],gains)[0]
                    C=frame@camera
                    pose=BUNDLE.JOINT.rigid_inverse(C)@target
                    pixels=cv2.projectPoints(QR.object_corners(),cv2.Rodrigues(pose[:3,:3])[0],pose[:3,3],K,np.zeros(5))[0].reshape(4,2)
                    assert np.min(pixels)>=0 and np.max(pixels)<2000 and pose[2,3]>.05
                    views.append({'id':f'pose-{len(views)}','training':(pi+li+ui)%4!=0,
                                  'targetID':identifier,'cameraMatrix':[700.,700.,1000.,1000.],
                                  'imageSize':[2000,2000],'cornersPixels':pixels.tolist(),
                                  'baseToNeck':frame.reshape(-1).tolist(),'stepIndex':len(views),
                                  'neckPanDegrees':pan,'lowerTarget':lower,'neckUpperTarget':upper,
                                  'centerDepthMeters':float(pose[2,3]),
                                  'imu':{'stationary':True,'axes':'sensor_native','sample_count':20,
                                         'age_milliseconds':10.,'imu_to_rgb_rotation':np.eye(3).reshape(-1).tolist(),
                                         'gravity_mps2':(C[:3,:3].T@gravity*9.5).tolist()}})
        captures.append({'targetID':identifier,'document':{'schemaVersion':1,'targetID':identifier,
                         'symbolSideMeters':.12,'modelID':MODEL.model_id,'views':views},'captureStatus':'complete'})
    seed=dict(zip(BUNDLE.JOINT.PARAMETER_NAMES[:6],[*gains,-.08,.015,-.02]))
    seed.update(cameraX=.11,cameraY=.006,cameraZ=.12,lowerOffsetRadians=-.2,gravityRxRadians=.04,gravityRyRadians=.03)
    return captures,seed,camera,gravity


class ConstrainedBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.captures,cls.seed,cls.camera,cls.gravity=dataset()
        cls.result=BUNDLE.fit(cls.captures,DIRECTORY,maximum_seconds=60,starts=1,seed_report=cls.seed)

    def test_recovers_torso_composite_without_known_global_marker_coordinates(self):
        result=self.result
        self.assertLess(result['quality']['heldOut']['cornerRMSEPixels'],1e-5)
        self.assertLess(result['quality']['heldOut']['imuDirectionRMSEDegrees'],1e-4)
        self.assertLess(result['quality']['heldOut']['centerDepthRMSEMeters'],1e-6)
        np.testing.assert_allclose(np.array(result['upperToOpticalCameraRowMajor']).reshape(4,4),self.camera,atol=1e-5)
        np.testing.assert_allclose(result['surfaceValidation']['fittedGravityDirectionTorso'],self.gravity,atol=1e-5)
        self.assertFalse(result['registrationVerified']);self.assertFalse(result['candidateURDFReady'])
        self.assertFalse(result['calibrationApplied']);self.assertFalse(result['identifiability']['covarianceIsHardwareUncertainty'])
        self.assertEqual(result['assumptions']['frame'],'torso_link')
        self.assertFalse(result['assumptions']['bodyLeanAndTorsoYawMeasured'])

    def test_heldout_pixels_depth_and_imu_do_not_enter_training_objective(self):
        changed=copy.deepcopy(self.captures)
        for capture in changed:
            for view in capture['document']['views']:
                if not view['training']:
                    view['cornersPixels']=(np.array(view['cornersPixels'])+[2.,-.7]).tolist()
                    view['centerDepthMeters']+=.04
                    view['imu']['gravity_mps2']=(cv2.Rodrigues(np.array([.1,0,0]))[0]@view['imu']['gravity_mps2']).tolist()
        result=BUNDLE.fit(changed,DIRECTORY,maximum_seconds=60,starts=1,seed_report=self.seed)
        np.testing.assert_allclose(list(result['parameters'].values()),list(self.result['parameters'].values()),atol=1e-9)
        self.assertGreater(result['quality']['heldOut']['cornerRMSEPixels'],2.)
        self.assertGreater(result['quality']['heldOut']['centerDepthRMSEMeters'],.039)
        self.assertGreater(result['quality']['heldOut']['imuDirectionRMSEDegrees'],4.)

    def test_pan_is_first_and_torso_anchor_is_not_old_high_pan_origin(self):
        model=BUNDLE.MeasuredOrderModel(DIRECTORY)
        command=[23.,6211,6506]
        model.lower_offset=.1
        P,L,U=np.radians([23.,6.,12.])
        expected=QR.transform(np.eye(3),BUNDLE.CAD_PIVOT_TORSO)
        for R in [BUNDLE.JOINT.rotation([0,0,1],P),BUNDLE.JOINT.rotation([0,1,0],L+.1)]:
            expected=expected@QR.transform(R,[0,0,0])
        expected=expected@QR.transform(np.eye(3),[0,0,.15579])@QR.transform(BUNDLE.JOINT.rotation([0,1,0],U),[0,0,0])
        np.testing.assert_allclose(model.frames([command],[1,1,1])[0],expected,atol=1e-12)

    def test_surface_constraints_allow_tilted_gravity_and_reject_false_flattening(self):
        data=BUNDLE.prepare(self.captures,MODEL)
        p=np.array(list(self.result['parameters'].values()))
        _,_,cameras,targets,gravity=BUNDLE.project(p,MODEL,data,None)
        u=self.result['surfaceValidation']['uncertainties']
        good=BUNDLE.physical_residual(targets,gravity,data['captures'],[],cameras,data['training'],u,np.zeros(3),p[6])
        self.assertLess(np.linalg.norm(good),1e-5)
        wrong=BUNDLE.physical_residual(targets,[0,0,1.],data['captures'],[],cameras,data['training'],u,np.zeros(3),p[6])
        self.assertGreater(np.linalg.norm(wrong),5.)
        shifted=copy.deepcopy(targets);shifted[1][:3,3]+=gravity*.02
        bad=BUNDLE.physical_residual(shifted,gravity,data['captures'],[],cameras,data['training'],u,np.zeros(3),p[6])
        self.assertGreater(np.linalg.norm(bad),6.)

    def test_perpendicular_pivot_radius_is_not_the_glass_distance_bound(self):
        p=np.array(list(self.result['parameters'].values()))
        # A large shaft-axis component can satisfy full3D distance while the
        # actual perpendicular upper-axis pivot radius remains20mm.
        xyz=np.array([.02,.12,0.]);p[6:9]=BUNDLE.camera_parameters(xyz)
        camera,_,_=BUNDLE.decode(p,MODEL,len(self.captures))
        self.assertAlmostEqual(np.linalg.norm(camera[[0,2],3]),.02)
        self.assertGreater(np.linalg.norm(camera[:3,3]),.0685)
        self.assertEqual(self.result['assumptions']['upperServoCenterToVirtualAxisOriginSurveyed'],False)

    def test_pose_prediction_reports_conditional_sensitivity_and_extrapolation(self):
        inside,outside=BUNDLE.predict_camera_to_torso(self.result,[[0,6011,6056],[0,6495,5900]],DIRECTORY)
        self.assertTrue(inside['insideTrainingCommandConvexHull'])
        self.assertFalse(outside['insideTrainingCommandConvexHull'])
        self.assertFalse(inside['physicalErrorBoundEstablished'])
        self.assertGreater(max(inside['conditionalOneSigmaPositionMeters']),1e-6)
        self.assertGreater(max(inside['conditionalOneSigmaRotationDegrees']),1e-6)

    def test_fresh_scene_validation_freezes_neck_and_fits_only_marker_poses(self):
        changed=copy.deepcopy(self.captures)
        model=BUNDLE.MeasuredOrderModel(DIRECTORY);model.lower_offset=-.2
        for capture in changed:
            target=np.array(self.result['targetToTorsoRowMajor'][capture['targetID']]).reshape(4,4)
            target[:3,3]+=.03*target[:3,0]
            for view in capture['document']['views']:
                command=[view['neckPanDegrees'],view['lowerTarget'],view['neckUpperTarget']]
                C=model.frames([command],[1.9,1.7,1.8])[0]@self.camera
                pose=BUNDLE.JOINT.rigid_inverse(C)@target
                K=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
                view['cornersPixels']=cv2.projectPoints(QR.object_corners(),cv2.Rodrigues(pose[:3,:3])[0],pose[:3,3],K,np.zeros(5))[0].reshape(4,2).tolist()
                view['centerDepthMeters']=float(pose[2,3])
        result=BUNDLE.validate_frozen_neck(changed,self.result,DIRECTORY)
        self.assertFalse(result['neckAndCameraParametersOptimized'])
        self.assertTrue(result['markerPosesOptimizedOnTrainingOnly'])
        self.assertLess(result['quality']['heldOut']['cornerRMSEPixels'],1e-5)
        self.assertLess(result['quality']['heldOut']['rawCenterDepthRMSEMeters'],1e-6)

    def test_cli_never_overwrites_capture_or_model_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);entries=[]
            for i,capture in enumerate(self.captures):
                document=copy.deepcopy(capture['document'])
                document.update(registrationVerified=False,surveySessionID='test',sceneContextID='scene')
                path=folder/f'capture-{i}.json';path.write_text(json.dumps(document))
                entries.append({'targetID':capture['targetID'],'capturePath':str(path),'status':'complete','samples':len(document['views'])})
            manifest=folder/'survey.json'
            manifest.write_text(json.dumps({'schemaVersion':1,'captureKind':'multi_target_neck_survey',
                'robotBaseStationary':True,'registrationVerified':False,'sessionID':'test','sceneContextID':'scene','captures':entries}))
            capture=Path(entries[0]['capturePath']);original=capture.read_bytes()
            for output in [capture,manifest,DIRECTORY/'must-not-create-constrained-fit.json']:
                process=subprocess.run([sys.executable,str(DIRECTORY/'qr_neck_constrained_bundle.py'),
                    '--manifest',str(manifest),'--output',str(output)],capture_output=True,text=True)
                self.assertNotEqual(process.returncode,0)
                self.assertIn('cannot overwrite',process.stderr)
            self.assertEqual(capture.read_bytes(),original)
            self.assertFalse((DIRECTORY/'must-not-create-constrained-fit.json').exists())

    def test_factory_distortion_cannot_be_applied_to_undistorted_or_unproven_output(self):
        data=BUNDLE.prepare(copy.deepcopy(self.captures),MODEL)
        with self.assertRaisesRegex(ValueError,'per-image native-distorted'):
            BUNDLE.apply_fixed_distortion_to_pnp(data,[.01,0,0,0,0])
        for view in data['originalViews']:
            view.update(rgbOutputUndistorted=True,pixelModel='undistorted',pixelModelProvenanceSHA256='a'*64)
        with self.assertRaises(ValueError):BUNDLE.apply_fixed_distortion_to_pnp(data,[.01,0,0,0,0])
        # A caller cannot turn an EEPROM hypothesis into source-image proof by
        # changing a few JSON flags and supplying a well-formed fake digest.
        for view in data['originalViews']:
            view.update(rgbOutputUndistorted=False,pixelModel='native_distorted',
                        distortionCoefficients=[.01,0,0,0,0])
        with self.assertRaisesRegex(ValueError,'immutable original'):
            BUNDLE.apply_fixed_distortion_to_pnp(data,[.01,0,0,0,0])

    def test_native_distorted_mode_requires_original_frame_metadata_not_only_flags(self):
        data=BUNDLE.prepare(copy.deepcopy(self.captures),MODEL);D=[.01,0,0,0,0]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'capture-input.json'
            frames=[{'sequence':i+1,'rgbOutputUndistorted':False,'rgbOutputDistortionCoefficients':D}
                    for i in range(len(data['originalViews']))]
            raw=json.dumps({'frames':frames}).encode();path.write_bytes(raw)
            import hashlib
            digest=hashlib.sha256(raw).hexdigest()
            for i,view in enumerate(data['originalViews']):
                view.update(rgbOutputUndistorted=False,pixelModel='native_distorted',
                            pixelModelProvenanceSHA256=digest,distortionCoefficients=D,
                            sourceEvidence={'capturePath':directory,'captureInputSHA256':digest,'frameSequence':i+1})
            BUNDLE.validate_image_models(data,D)
            frames[0]['rgbOutputUndistorted']=True
            path.write_text(json.dumps({'frames':frames}))
            with self.assertRaisesRegex(ValueError,'hash changed'):BUNDLE.validate_image_models(data,D)


if __name__=='__main__':unittest.main()
