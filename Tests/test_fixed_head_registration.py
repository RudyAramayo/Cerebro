"""Exercise fixed-head acquisition with synthetic RGB-D and real rigid optimizer."""
import hashlib
import copy
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
from scipy.spatial.transform import Rotation

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'Cerebro/Resources/ShadowPlanner'))
from fixed_head_registration import (balanced_surface_patch_indices, proper_fit,
                                     read_capture, register, stationary_gravity_initializer)
from markerless import MarkerlessEstimator


class FixedHeadRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.root=Path(self.temporary.name)
        self.width,self.height=160,120
        k=np.array([120.,120.,80.,60.])
        v,u=np.indices((self.height,self.width))
        rx=(u-k[2])/k[0];ry=(v-k[3])/k[1]
        left=np.where(rx<-.001,-.3/np.minimum(rx,-.001),99)
        right=np.where(rx>.001,.3/np.maximum(rx,.001),99)
        floor=np.where(ry>.001,.25/np.maximum(ry,.001),99)
        surfaces=np.stack([np.full(rx.shape,1.2),left,right,floor])
        which=np.argmin(surfaces,axis=0)
        depth=np.min(surfaces,axis=0)
        self.frames=[]
        for i in range(3):
            # Separate captured frames with deterministic submillimeter noise.
            values=np.rint(depth*1000+((u+2*v+i)%3-1)*.3).astype('<u2')
            values[3+i,4+i]+=1
            path=self.root/f'frame-{i}.depth-u16le'
            path.write_bytes(values.tobytes())
            self.frames.append(dict(depthPath=path.name,width=self.width,height=self.height,
                intrinsics=k.tolist(),sequence=i+1,capturedAtMilliseconds=10000+i*200,
                captureSHA256=hashlib.sha256(path.read_bytes()).hexdigest()))
        rows=[];normals=[];labels=[]
        for y in range(5,self.height-5,4):
            for x in range(5,self.width-5,4):
                z=depth[y,x]
                rows.append([rx[y,x]*z,ry[y,x]*z,z])
                normals.append([[0,0,1],[-1,0,0],[1,0,0],[0,1,0]][which[y,x]])
                labels.append('torso_link' if y<60 else 'base_link')
        self.points=np.asarray(rows);self.normals=np.asarray(normals);self.labels=np.asarray(labels)
        self.scope=dict(modelID='fixture-model',geometryID='fixture-geometry',mappingID='physical-right',
            cameraGeneration='A041BA7A-4805-431F-A5DC-197DDB43DE98',gatewaySessionGeneration=7,
            displayCorrectionIdentity='display-fixture',panTarget=6000,lowerTarget=6011,upperTarget=6906,
            intrinsicsIdentity='fixture-160x120')
        self.document=dict(schemaVersion=1,scope=self.scope,
            validRobotVolume=dict(lowMeters=[-.4,-.4,.1],highMeters=[.4,.4,1.3]),
            referenceUncertaintyMeters=.002,initialCameraToRobotColumnMajor=np.eye(4).flatten(order='F').tolist(),frames=self.frames)
        owner=self
        self.requested_sample_counts=[]
        class Estimator:
            def __init__(self,planner,surface_samples_per_link=160):
                owner.requested_sample_counts.append(surface_samples_per_link)
            def points(self,q,names):return owner.points,owner.normals,owner.labels
            @staticmethod
            def visible(points,camera,depth,intrinsics):return np.ones(len(points),dtype=bool)
        self.estimator=Estimator
        class Planner:
            reference={'modelID':'fixture-model'}
            q0=np.zeros(1)
        self.planner=Planner()

    def tearDown(self):self.temporary.cleanup()

    def fit(self):
        with patch('markerless.MarkerlessEstimator',self.estimator):
            return register(self.document,self.root,planner=self.planner)

    def test_actual_optimizer_and_withheld_captures(self):
        output,report=self.fit()
        self.assertEqual(self.requested_sample_counts,[640])
        self.assertFalse(report['registrationVerified'])
        self.assertGreaterEqual(report['fitPatchCount'],20)
        self.assertGreaterEqual(report['heldOutPatchCount'],6)
        self.assertEqual(report['heldOutFrameCount'],2)
        training=[s for s in output['samples'] if not s['validationOnly']]
        held=[s for s in output['samples'] if s['validationOnly']]
        self.assertTrue(set(s['captureID'] for s in training).isdisjoint(s['captureID'] for s in held))
        self.assertTrue(set(s['landmarkID'] for s in training).isdisjoint(s['landmarkID'] for s in held))
        self.assertLess(report['pointNormalRMSEMeters'],.003)
        matrix=np.array(report['candidateCameraToRobotColumnMajor']).reshape((4,4),order='F')
        self.assertLess(np.max(np.abs(matrix-np.eye(4))),.01)
        # Exercise the exact interchange schema with the production Swift fitter.
        (self.root/'registration-input.json').write_text(json.dumps(output))

    def test_patch_cap_preserves_sparse_torso_and_existing_split(self):
        labels=np.array(['base_link']*97+['left_track_link']*9+
                        ['right_track_link']*29+['torso_link']*13+['lean_link'])
        available=np.arange(len(labels))
        old=available[np.linspace(0,len(available)-1,100,dtype=int)]
        self.assertLess(sum(labels[old]=='torso_link'),10)
        selected=balanced_surface_patch_indices(available,labels,100)
        self.assertEqual(len(selected),100)
        self.assertEqual(len(np.unique(selected)),100)
        self.assertEqual(sum(labels[selected]=='torso_link'),13)
        self.assertTrue(set(selected).issubset(available))
        held=available[::3]
        chosen=balanced_surface_patch_indices(held,labels,25)
        self.assertEqual(len(chosen),25)
        self.assertTrue(set(chosen).issubset(held))

    def test_actual_fit_keeps_rare_torso_support_when_base_dominates(self):
        cells=np.floor(self.points/.03).astype(np.int64)
        _,indices=np.unique(cells,axis=0,return_index=True)
        indices.sort()
        spatial=cells[indices]
        partition=(spatial[:,0]*73856093^spatial[:,1]*19349663^spatial[:,2]*83492791)%3
        training=indices[partition!=0]
        torso=training[np.linspace(0,len(training)-1,13,dtype=int)]
        self.labels[:]='base_link'
        self.labels[torso]='torso_link'
        output,report=self.fit()
        self.assertFalse(report['registrationVerified'])
        self.assertGreaterEqual(sum(s['landmarkID'].startswith('torso_link:') and
                                   not s['validationOnly'] for s in output['samples']),8)
        self.assertGreaterEqual(report['heldOutPatchCount'],6)
        matrix=np.array(report['candidateCameraToRobotColumnMajor']).reshape((4,4),order='F')
        self.assertLess(np.max(np.abs(matrix-np.eye(4))),.01)

    def imu_frames(self, gravity_rgb):
        frames=copy.deepcopy(self.frames)
        factory=np.diag([1.,-1.,-1.])
        for i,frame in enumerate(frames):
            latest=1_000_000_000+i*200_000_000
            frame['imu']=dict(sensor='fixture-imu',gravity_mps2=(factory.T@gravity_rgb*9.81).tolist(),
                gravity_std_mps2=[.01,.01,.01],gyro_rad_s=[0.,0.,0.],sample_count=40,
                window_milliseconds=400.,age_milliseconds=5.,latest_timestamp_ns=latest,
                reference_timestamp_ns=latest+5_000_000,imu_to_rgb_rotation=factory.flatten().tolist(),
                stationary=True,gravity_source='stationary_accelerometer_mean',axes='sensor_native')
        return frames

    def test_stationary_imu_seed_corrects_pitch_keeps_translation_heading_and_sources(self):
        # A fixed world-yaw rotation keeps the camera X heading equal.
        true=Rotation.from_euler('z',17.,degrees=True).as_matrix()@Rotation.from_euler('x',170.,degrees=True).as_matrix()
        prior=np.eye(4);prior[:3,:3]=Rotation.from_euler('z',17.,degrees=True).as_matrix()@Rotation.from_euler('x',177.,degrees=True).as_matrix()
        prior[:3,3]=[.12,-.03,1.04]
        frames=self.imu_frames(true.T@np.array([0.,0.,1.]))
        originals=copy.deepcopy(frames);before=prior.copy()
        seed,diagnostic=stationary_gravity_initializer(frames,prior)
        np.testing.assert_allclose(seed[:3,:3],true,atol=1e-12)
        np.testing.assert_array_equal(seed[:3,3],prior[:3,3])
        np.testing.assert_array_equal(prior,before)
        self.assertEqual(frames,originals)
        self.assertTrue(diagnostic['applied'])
        self.assertAlmostEqual(diagnostic['rotationChangeDegrees'],7.)
        self.assertEqual(diagnostic['source'],'stationary_imu_level_base_initializer_only')

    def test_bad_or_missing_imu_preserves_exact_prior(self):
        prior=np.eye(4);prior[:3,:3]=Rotation.from_euler('x',7.,degrees=True).as_matrix()
        good=self.imu_frames(np.array([0.,0.,1.]))
        mutations=[('sensor','other-imu'),('stationary',False),('age_milliseconds',101),('sample_count',1),
            ('gravity_mps2',[0.,0.,0.]),('gravity_std_mps2',[.5,.01,.01]),
            ('gyro_rad_s',[.1,0.,0.]),('axes','rgb'),('gravity_source','unknown'),
            ('imu_to_rgb_rotation',[1.,0.,0.,0.,1.,0.,0.,0.,-1.]),
            ('reference_timestamp_ns',1),('window_milliseconds',float('nan'))]
        cases=[copy.deepcopy(self.frames)]
        for key,value in mutations:
            frames=copy.deepcopy(good);frames[1]['imu'][key]=value;cases.append(frames)
        repeated=copy.deepcopy(good);repeated[1]['imu']=copy.deepcopy(repeated[0]['imu']);cases.append(repeated)
        inconsistent=copy.deepcopy(good);inconsistent[1]['imu']['gravity_mps2']=[1.,0.,-9.75];cases.append(inconsistent)
        for frames in cases:
            with self.subTest(frames=frames):
                seed,diagnostic=stationary_gravity_initializer(frames,prior)
                np.testing.assert_array_equal(seed,prior)
                self.assertFalse(diagnostic['applied'])

    def test_imu_seed_does_not_guess_heading_or_large_correction(self):
        frames=self.imu_frames(np.array([0.,0.,1.]))
        for angle in [45.,90.]:
            prior=np.eye(4);prior[:3,:3]=Rotation.from_euler('y',angle,degrees=True).as_matrix()
            seed,diagnostic=stationary_gravity_initializer(frames,prior)
            np.testing.assert_array_equal(seed,prior)
            self.assertFalse(diagnostic['applied'])

    def test_actual_optimizer_uses_gravity_seed_and_original_heldout_gates(self):
        self.document['frames']=self.imu_frames(np.array([0.,0.,1.]))
        prior=np.eye(4);prior[:3,:3]=Rotation.from_euler('x',7.,degrees=True).as_matrix()
        self.document['initialCameraToRobotColumnMajor']=prior.flatten(order='F').tolist()
        output,report=self.fit()
        self.assertTrue(report['initializer']['applied'])
        self.assertFalse(report['registrationVerified'])
        self.assertEqual(report['originalSeedCameraToRobotColumnMajor'],prior.flatten(order='F').tolist())
        self.assertGreaterEqual(sum(s['validationOnly'] for s in output['samples']),6)
        self.labels[:]='torso_link'
        with self.assertRaisesRegex(ValueError,'visible torso and base-fixed surfaces'):
            self.fit()

    def test_saved_cad_density_is_bounded_and_default_stays_160(self):
        saved=json.loads((ROOT/'Cerebro/Resources/ShadowPlanner/surfaces.json').read_text())['surfaces']
        planner=SimpleNamespace(clearance=SimpleNamespace(surfaces=saved),q0=np.zeros(1))
        default=MarkerlessEstimator(planner)
        dense=MarkerlessEstimator(planner,surface_samples_per_link=640)
        rigid={'base_link','left_track_link','right_track_link','torso_link','lean_link','rplidar_link'}
        for surface in saved:
            count=len(surface['points'])
            raw_points=np.asarray(surface['points']);raw_normals=np.asarray(surface['normals'])
            for budget,estimator in [(160,default),(640,dense)]:
                selected=np.linspace(0,count-1,min(count,budget),dtype=int)
                points,normals=estimator.surfaces[surface['link']]
                np.testing.assert_array_equal(points,raw_points[selected])
                np.testing.assert_array_equal(normals,raw_normals[selected])
                self.assertEqual(len(np.unique(selected)),len(selected))
                if surface['link'] in rigid:
                    self.assertEqual(len(points),budget)
                    self.assertEqual(len(np.unique(points,axis=0)),budget)
        for invalid in [0,641,-1,True,160.0,None]:
            with self.subTest(samples=invalid),self.assertRaisesRegex(ValueError,'integer.*640'):
                MarkerlessEstimator(planner,surface_samples_per_link=invalid)

    def test_dense_repeated_samples_cannot_manufacture_independent_patches(self):
        # Over1000 CAD rows are still one physical3cm patch. Higher density
        # must not turn adjacent/duplicate support into fit/heldout landmarks.
        self.points=np.repeat(self.points[:1],1024,axis=0)
        self.normals=np.repeat(self.normals[:1],1024,axis=0)
        self.labels=np.repeat(self.labels[:1],1024)
        with self.assertRaisesRegex(ValueError,'spatially separated fit and held-out patches'):
            self.fit()
        self.assertEqual(self.requested_sample_counts,[640])

    def test_dense_torso_only_support_still_needs_base_fixed_surfaces(self):
        self.labels[:]='torso_link'
        with self.assertRaisesRegex(ValueError,'visible torso and base-fixed surfaces'):
            self.fit()

    def test_later_depth_disagreement_rejects(self):
        for frame in self.frames[1:]:
            path=self.root/frame['depthPath'];values=np.frombuffer(path.read_bytes(),dtype='<u2').copy()
            values+=100;path.write_bytes(values.tobytes());frame['captureSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError,'validation|survived'):
            self.fit()

    def test_plane_only_registration_is_underconstrained(self):
        self.points[:,2]=1.2;self.normals[:]=[0,0,1]
        with self.assertRaisesRegex(ValueError,'underconstrained|inconsistent'):
            self.fit()

    def test_frame_hash_and_framing_mismatch_reject(self):
        self.frames[0]['captureSHA256']='0'*64
        with self.assertRaisesRegex(ValueError,'hash'):
            read_capture(self.frames[0],self.root)
        self.frames[0].pop('captureSHA256')
        self.frames[1]['intrinsics'][0]=121
        with self.assertRaisesRegex(ValueError,'framing'):
            self.fit()

    def test_repeated_depth_is_not_independent_capture(self):
        self.frames[1]['depthPath']=self.frames[0]['depthPath']
        self.frames[1]['captureSHA256']=self.frames[0]['captureSHA256']
        with self.assertRaisesRegex(ValueError,'distinct'):
            self.fit()

    def test_proper_half_turn_does_not_become_reflection(self):
        points=np.array([[0,0,1],[1,0,1],[0,1,1],[.2,.4,2.]])
        rotation=np.diag([-1.,-1.,1.]);translation=np.array([.3,-.2,.1])
        matrix=proper_fit(points,points@rotation.T+translation)
        self.assertLess(np.max(np.abs(matrix[:3,:3]-rotation)),1e-9)
        self.assertAlmostEqual(np.linalg.det(matrix[:3,:3]),1)
        self.assertLess(np.max(np.abs(matrix[:3,3]-translation)),1e-9)


if __name__=='__main__':unittest.main()
