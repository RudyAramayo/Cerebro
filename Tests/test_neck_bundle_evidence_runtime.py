"""Swift RGB evidence checked against independent OpenCV/synthetic kinematics."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('bundle_evidence_synthetic',ROOT/'Tests/test_qr_neck_constrained_bundle.py')
S=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(S)
B=S.BUNDLE


def fixture():
    captures,seed,camera,gravity=S.dataset()
    model=B.MeasuredOrderModel(S.DIRECTORY);model.lower_offset=-.2
    identity=hashlib.sha256(b'[2000,2000,700,700,1000,1000]').hexdigest()
    scope={'modelID':model.model_id,'geometryID':'synthetic-geometry','mappingID':'physical-right-mapping',
           'cameraGeneration':'510BBD88-78E8-49E4-89B9-B94487515983','gatewaySessionGeneration':42,
           'displayCorrectionIdentity':'manual:body:synthetic-epoch','panTarget':6000,'lowerTarget':6011,
           'upperTarget':6056,'intrinsicsIdentity':identity}
    observations=[]
    for capture in captures:
        # Keep every pose on an actual integer Maestro target, and regenerate
        # image pixels independently rather than rounding pose coordinates.
        target_id=capture['targetID']
        tilt=cv2.Rodrigues(np.array([.04,.03,0.]))[0]
        position={'ROB:FLOOR:L01':[.55,.10,0.],'ROB:FLOOR:R01':[.55,-.10,0.],'ROB:TABLE:001':[.60,0.,.10]}[target_id]
        target=B.QR.transform(tilt@np.array([[0.,1,0],[-1,0,0],[0,0,1.]]),tilt@position)
        for view in capture['document']['views']:
            local=dict(scope,panTarget=6000+round(view['neckPanDegrees']/.03),lowerTarget=view['lowerTarget'],upperTarget=view['neckUpperTarget'])
            command=[(local['panTarget']-6000)*.03,local['lowerTarget'],local['upperTarget']]
            C=model.frames([command],[1.9,1.7,1.8])[0]@camera
            pose=B.JOINT.rigid_inverse(C)@target
            K=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
            pixels=cv2.projectPoints(B.QR.object_corners(),cv2.Rodrigues(pose[:3,:3])[0],pose[:3,3],K,np.zeros(5))[0].reshape(4,2)
            identifier=target_id+':'+view['id']
            observations.append({'targetID':target_id,'training':view['training'],'scope':local,
                'width':2000,'height':2000,'intrinsics':[700,700,1000,1000],'distortion':[],
                'outputPixelModel':'undistorted','pixelModelProvenanceSHA256':'b'*64,
                'cornersPixels':pixels.tolist(),'targetToCameraCandidatesRowMajor':[pose.reshape(-1).tolist()],
                'imageSHA256':hashlib.sha256(identifier.encode()).hexdigest(),
                'metadataSHA256':hashlib.sha256((identifier+':metadata').encode()).hexdigest(),
                'frameSequence':len(observations)+1,'capturedAtMilliseconds':1700000000000+len(observations)*200})
    C=model.frames([[0,6011,6056]],[1.9,1.7,1.8])[0]@camera
    return {'input':{'schemaVersion':1,'kind':'neck_bundle','scope':scope,'parameterFitEvidenceSHA256':'a'*64,
        'symbolSideMeters':.12,'parameters':{'panScale':1.9,'lowerScale':1.7,'upperScale':1.8,
            'lowerOffsetRadians':-.2,'cameraDeltaRotationVector':[-.08,.015,-.02],
            'cameraTranslationMeters':[.11,.006,.12]},'observations':observations,'parameterPositionAllowanceMeters':.012},
        'nominalRowMajor':model.nominal_camera.reshape(-1).tolist(),'expectedCameraToTorsoRowMajor':C.reshape(-1).tolist()}


class NeckBundleEvidenceRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=tempfile.TemporaryDirectory(prefix='neck-bundle-evidence-',dir='/private/tmp')
        cls.binary=Path(cls.directory.name)/'evidence'
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',
            '-module-cache-path','/private/tmp/cerebro-swift-module-cache',
            str(ROOT/'Cerebro/ROBFixedHeadRegistration.swift'),str(ROOT/'Cerebro/ROBNeckBundleEvidence.swift'),
            str(ROOT/'Tests/ROBNeckBundleEvidenceFixture.swift'),'-o',str(cls.binary)],check=True)
        cls.input=fixture()

    @classmethod
    def tearDownClass(cls):cls.directory.cleanup()

    def run_fixture(self,document,mode=None):
        path=Path(self.directory.name)/'fixture.json';path.write_text(json.dumps(document))
        process=subprocess.run([str(self.binary),str(path)]+([mode] if mode else []),text=True,capture_output=True)
        self.assertEqual(process.returncode,0,process.stdout+process.stderr)
        return process.stdout.strip()

    def test_metric_recovery_has_no_depth_authority_and_matches_python_chain(self):
        result=json.loads(self.run_fixture(self.input))
        self.assertFalse(result['hasDepthAuthority'])
        self.assertLess(result['trainingPixels'],1e-5);self.assertLess(result['heldOutPixels'],1e-5)
        self.assertLess(result['heldOutMarkerDriftMaximumMeters'],1e-6)

    def test_source_verification_is_required(self):
        self.assertIn('Rejected:',self.run_fixture(self.input,'reject-source'))

    def test_changed_scope_provenance_domain_rotation_and_split_reject(self):
        changes=[lambda d:d['input'].update(kind='cad_point_pairs'),
            lambda d:d['input'].update(symbolSideMeters=.10),
            lambda d:d['input']['observations'][0]['scope'].update(mappingID='other-arm'),
            lambda d:d['input']['observations'][0]['scope'].update(lowerTarget=6495),
            lambda d:d['input']['observations'][0]['scope'].update(displayCorrectionIdentity='body-moved'),
            lambda d:d['input']['observations'][0].update(imageSHA256='bad'),
            lambda d:d['input']['scope'].update(upperTarget=6500),
            lambda d:d['input']['observations'][0]['intrinsics'].__setitem__(0,710),
            lambda d:d['input']['observations'][0].update(distortion=[.01,0,0,0]),
            lambda d:d['input']['observations'][0].update(outputPixelModel='native_distorted'),
            lambda d:d['input']['observations'][0].update(pixelModelProvenanceSHA256='bad'),
            lambda d:d['input']['observations'][0]['targetToCameraCandidatesRowMajor'][0].__setitem__(0,2.),
            lambda d:d['input']['observations'][0].update(training=not d['input']['observations'][0]['training'])]
        for change in changes:
            with self.subTest(change=change):
                document=copy.deepcopy(self.input);change(document)
                self.assertIn('Rejected:',self.run_fixture(document,'reject'))

    def test_heldout_pixels_never_refit_training_marker_pose(self):
        changed=copy.deepcopy(self.input)
        K=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
        for view in changed['input']['observations']:
            if not view['training']:
                pixels=np.array(view['cornersPixels'])+[2.,-.7]
                vector,tvec=cv2.solvePnP(B.QR.object_corners(),pixels,K,np.zeros(5),flags=cv2.SOLVEPNP_IPPE_SQUARE)[1:]
                pose=B.QR.transform(cv2.Rodrigues(vector)[0],tvec.reshape(3))
                view['cornersPixels']=pixels.tolist();view['targetToCameraCandidatesRowMajor']=[pose.reshape(-1).tolist()]
        before=json.loads(self.run_fixture(self.input));after=json.loads(self.run_fixture(changed))
        for name in before['markers']:np.testing.assert_allclose(before['markers'][name],after['markers'][name],atol=1e-12)
        self.assertGreater(after['heldOutPixels'],2.)

    def test_consistent_images_cannot_hide_inconsistent_physical_floor_or_table(self):
        _,_,camera,_=S.dataset()
        model=B.MeasuredOrderModel(S.DIRECTORY);model.lower_offset=-.2
        K=np.array([[700.,0,1000],[0,700.,1000],[0,0,1.]])
        for marker in ['ROB:TABLE:001','ROB:FLOOR:L01']:
            changed=copy.deepcopy(self.input)
            for view in changed['input']['observations']:
                if view['targetID']!=marker:continue
                s=view['scope'];C=model.frames([[(s['panTarget']-6000)*.03,s['lowerTarget'],s['upperTarget']]],[1.9,1.7,1.8])[0]@camera
                target=C@np.array(view['targetToCameraCandidatesRowMajor'][0]).reshape(4,4)
                if marker=='ROB:TABLE:001':target[:3,:3]=target[:3,:3]@cv2.Rodrigues(np.array([.1,0,0]))[0]
                else:target[:3,3]+=.05*target[:3,2]
                pose=B.JOINT.rigid_inverse(C)@target
                view['cornersPixels']=cv2.projectPoints(B.QR.object_corners(),cv2.Rodrigues(pose[:3,:3])[0],pose[:3,3],K,np.zeros(5))[0].reshape(4,2).tolist()
                view['targetToCameraCandidatesRowMajor']=[pose.reshape(-1).tolist()]
            self.assertIn('Rejected:',self.run_fixture(changed,'reject'))


if __name__=='__main__':unittest.main()
