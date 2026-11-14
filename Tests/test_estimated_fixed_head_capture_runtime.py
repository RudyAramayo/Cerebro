"""Estimated-package provenance, immutable scope and raw/corrected union."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('estimated_source_fixture',ROOT/'Tests/test_neck_bundle_evidence_runtime.py')
SOURCE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(SOURCE)


def digest(value):return hashlib.sha256(value).hexdigest()
def write_json(path,value):
    data=json.dumps(value).encode();path.write_bytes(data);return digest(data)


def build_fixture(root):
    raw=SOURCE.fixture();input=raw['input']
    K=[210.,210.,320.,200.]
    identity=digest(b'[640,400,210,210,320,200]')
    input['scope']['intrinsicsIdentity']=identity
    for o in input['observations']:
        pixels=np.array(o['cornersPixels'])
        o.update(width=640,height=400,intrinsics=K,cornersPixels=((pixels-[1000,1000])*.3+[320,200]).tolist())
        o['scope']['intrinsicsIdentity']=identity
        assert np.min(o['cornersPixels'])>=0 and np.max(np.array(o['cornersPixels'])[:,0])<640 and np.max(np.array(o['cornersPixels'])[:,1])<400
    # The recorded pipeline flag and independently pinned bytes are the
    # contract; source-code substring matching cannot establish geometry.
    contract=root/'contract.py';contract.write_text('RGB_OUTPUT_UNDISTORTED=True\nrgb_output=rgb_camera.requestOutput(frame_size, enableUndistortion=RGB_OUTPUT_UNDISTORTED)\n')
    contract_hash=digest(contract.read_bytes())
    params=input['parameters'];xyz=np.array(params['cameraTranslationMeters']);r=float(np.linalg.norm(xyz))
    fit={'status':'conditional_torso_bundle_candidate_not_registered','modelID':input['scope']['modelID'],
         'registrationVerified':False,'pixelModel':{'fixedDistortionApplied':False},
         'parameters':{'panScale':params['panScale'],'lowerScale':params['lowerScale'],'upperScale':params['upperScale'],
            'lowerOffsetRadians':params['lowerOffsetRadians'],'cameraDeltaRx':params['cameraDeltaRotationVector'][0],
            'cameraDeltaRy':params['cameraDeltaRotationVector'][1],'cameraDeltaRz':params['cameraDeltaRotationVector'][2],
            'cameraDistanceFromAssumedUpperCenterMeters':r,'cameraAzimuthRadians':float(np.arctan2(xyz[1],xyz[0])),
            'cameraElevationRadians':float(np.arcsin(xyz[2]/r))}}
    fit_hash=write_json(root/'fit.json',fit);input['parameterFitEvidenceSHA256']=fit_hash
    captures=root/'Captures';captures.mkdir()
    groups={}
    for o in input['observations']:
        key=tuple(o['scope'][k] for k in ['panTarget','lowerTarget','upperTarget'])
        groups.setdefault(key,[]).append(o)
    depth_bytes=np.full((400,640),1000,dtype='<u2').tobytes();depth_hash=digest(depth_bytes)
    sources=[];patches=[]
    for index,(pose,group) in enumerate(groups.items()):
        folder=captures/str(index);folder.mkdir()
        (folder/'frame-0.depth-u16le').write_bytes(depth_bytes)
        image=('synthetic-camera-source:'+str(pose)).encode();(folder/'frame-0.jpg').write_bytes(image)
        sequence=index+1;time=1700000000000+index*200
        metadata={'scope':group[0]['scope'],'frames':[{'depthPath':'frame-0.depth-u16le','width':640,'height':400,
            'intrinsics':K,'sequence':sequence,'capturedAtMilliseconds':time,'captureSHA256':depth_hash,
            'rgbOutputUndistorted':True,'cameraServiceSourceSHA256':contract_hash}]}
        metadata_hash=write_json(folder/'capture-input.json',metadata)
        for o in group:
            o.update(imageSHA256=digest(image),metadataSHA256=metadata_hash,frameSequence=sequence,
                     capturedAtMilliseconds=time,pixelModelProvenanceSHA256=contract_hash)
            identifier=str(index)+':'+o['targetID']
            sources.append({'id':identifier,'scope':o['scope'],'frameSequence':sequence,'capturedAtMilliseconds':time,
                'sourceImageSHA256':digest(image),'depthSHA256':depth_hash,'captureInputSHA256':metadata_hash,
                'cameraMatrix':K,'width':640,'height':400,'zeroDistortionAssumed':True,
                'rangeGroup':'near' if o['targetID']=='ROB:TABLE:001' else 'far','split':'train' if o['training'] else 'heldout'})
            patches.append({'id':identifier,'interiorPolygonPixels':[[100,100],[200,100],[200,200],[100,200]],
                            'rawDepthMinimumMeters':.8,'rawDepthMaximumMeters':1.2})
    report={'schemaVersion':1,'kind':'qr_native_depth_correction_diagnostic','model':'inverse_scale_bias',
            'candidateValidated':False,'registrationVerified':False,'calibrationApplied':False,'parameters':[.9,.15],
            'physicalBounds':{'passed':True},'domain':{'rawDepthMinimumMeters':.6,'rawDepthMaximumMeters':1.3,'patches':patches},
            'sources':sources}
    report_hash=write_json(root/'depth.json',report)
    rgb_hash=write_json(root/'rgb.json',input)
    package={'schemaVersion':1,'kind':'estimated_fixed_head_raw_corrected_union','purpose':'empty_right_estimated_probe',
        'rgbInputPath':'rgb.json','rgbInputSHA256':rgb_hash,'depthReportPath':'depth.json','depthReportSHA256':report_hash,
        'parameterFitPath':'fit.json','parameterFitSHA256':fit_hash,'pixelModelContractPath':'contract.py',
        'pixelModelContractSHA256':contract_hash,'captureDirectory':'Captures'}
    write_json(root/'package.json',package)
    torso=np.eye(4);torso[:3,:3]=cv2.Rodrigues(np.array([.02,-.03,.1]))[0];torso[:3,3]=[.1,-.04,.65]
    config={'model':{'physicalSide':'right','modelID':input['scope']['modelID'],'geometryID':input['scope']['geometryID'],
        'mappingID':input['scope']['mappingID'],'referenceID':'pinned-model-reference',
        'torsoToModelRowMajor':torso.reshape(-1).tolist(),'nominalUpperToOpticalRowMajor':raw['nominalRowMajor']},
        'scope':input['scope'],'expectedCameraToModelRowMajor':(torso@np.array(raw['expectedCameraToTorsoRowMajor']).reshape(4,4)).reshape(-1).tolist(),
        'assertSyntheticPatch':True,'verifiedCameraServiceSourceSHA256':[contract_hash]}
    write_json(root/'config.json',config)


class EstimatedCaptureRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=tempfile.TemporaryDirectory(prefix='estimated-capture-',dir='/private/tmp')
        cls.base=Path(cls.directory.name);cls.pristine=cls.base/'pristine';cls.pristine.mkdir();build_fixture(cls.pristine)
        cls.binary=cls.base/'capture'
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',
            '-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(ROOT/'Cerebro/ROBFixedHeadRegistration.swift'),
            str(ROOT/'Cerebro/ROBNeckBundleEvidence.swift'),str(ROOT/'Cerebro/ROBEstimatedFixedHeadCapture.swift'),
            str(ROOT/'Tests/ROBEstimatedFixedHeadCaptureFixture.swift'),'-o',str(cls.binary)],check=True)

    @classmethod
    def tearDownClass(cls):cls.directory.cleanup()

    def run_case(self,mutate=None,reject=False):
        with tempfile.TemporaryDirectory(prefix='case-',dir=self.base) as temporary:
            case=Path(temporary)/'evidence';shutil.copytree(self.pristine,case)
            if mutate:mutate(case)
            p=subprocess.run([str(self.binary),str(case/'package.json'),str(case),str(case/'config.json')]+(['reject'] if reject else []),text=True,capture_output=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            return p.stdout.strip()

    def test_raw_corrected_union_is_explicitly_estimated_and_context_is_immutable(self):
        result=json.loads(self.run_case())
        self.assertFalse(result['measured_registration_verified']);self.assertFalse(result['grasp_authorized'])
        self.assertFalse(result['depth_candidate_validated'])
        self.assertTrue(result['rgb_output_undistorted'])
        self.assertEqual(result['camera_service_source_sha256'],json.loads((self.pristine/'package.json').read_text())['pixelModelContractSHA256'])
        self.assertEqual(len(result['id']),64)

    def test_artifact_or_original_image_depth_metadata_changes_reject(self):
        mutations=[lambda p:(p/'fit.json').write_text('{}'),lambda p:(p/'depth.json').write_text('{}'),
            lambda p:(p/'Captures/0/frame-0.jpg').write_bytes(b'changed'),
            lambda p:(p/'Captures/0/frame-0.depth-u16le').write_bytes(b'bad'),
            lambda p:(p/'Captures/0/capture-input.json').write_text('{}')]
        for mutate in mutations:
            with self.subTest(mutate=mutate):self.assertIn('Rejected:',self.run_case(mutate,True))

    def test_stale_camera_and_wrong_arm_do_not_rebind(self):
        def changed(path,edit):
            data=json.loads((path/'config.json').read_text());edit(data);write_json(path/'config.json',data)
        for edit in [lambda d:d['scope'].update(cameraGeneration='00000000-0000-0000-0000-000000000001'),
                     lambda d:d['scope'].update(displayCorrectionIdentity='other:body:other'),
                     lambda d:d['model'].update(physicalSide='left')]:
            self.assertIn('Rejected:',self.run_case(lambda path:changed(path,edit),True))

    def test_package_cannot_claim_registration_or_escape_evidence_root(self):
        def altered(p):
            report=json.loads((p/'depth.json').read_text());report['registrationVerified']=True
            sha=write_json(p/'depth.json',report);package=json.loads((p/'package.json').read_text())
            package['depthReportSHA256']=sha;write_json(p/'package.json',package)
        self.assertIn('Rejected:',self.run_case(altered,True))
        def escape(p):
            package=json.loads((p/'package.json').read_text());package['pixelModelContractPath']='/etc/hosts'
            write_json(p/'package.json',package)
        self.assertIn('Rejected:',self.run_case(escape,True))

    def test_bundle_hash_is_independent_of_package_self_assertion(self):
        for trusted in [[],['f'*64]]:
            def change(p):
                config=json.loads((p/'config.json').read_text());config['verifiedCameraServiceSourceSHA256']=trusted
                write_json(p/'config.json',config)
            self.assertIn('independently verified',self.run_case(change,True))

    def test_rehashed_legacy_or_mismatched_frame_provenance_still_rejects(self):
        changes=[lambda f:f.pop('cameraServiceSourceSHA256'),
                 lambda f:f.update(cameraServiceSourceSHA256='f'*64),
                 lambda f:f.pop('rgbOutputUndistorted'),
                 lambda f:f.update(rgbOutputUndistorted=False)]
        for edit in changes:
            def change(p):
                metadata=p/'Captures/0/capture-input.json';old=digest(metadata.read_bytes())
                value=json.loads(metadata.read_text());edit(value['frames'][0]);new=write_json(metadata,value)
                rgb=json.loads((p/'rgb.json').read_text())
                for observation in rgb['observations']:
                    if observation['metadataSHA256']==old:observation['metadataSHA256']=new
                report=json.loads((p/'depth.json').read_text())
                for observation in report['sources']:
                    if observation['captureInputSHA256']==old:observation['captureInputSHA256']=new
                package=json.loads((p/'package.json').read_text())
                package['rgbInputSHA256']=write_json(p/'rgb.json',rgb)
                package['depthReportSHA256']=write_json(p/'depth.json',report)
                write_json(p/'package.json',package)
            self.assertIn('Legacy captures are offline analysis only',self.run_case(change,True))


if __name__=='__main__':unittest.main()
