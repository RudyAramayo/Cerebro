"""Saved-data export: frozen parameters, explicit roles and worker provenance."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('frozen_probe_export',ROOT/'Scripts/export-frozen-neck-probe-evidence.py')
E = importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(E)


class FrozenProbeExportTests(unittest.TestCase):
    def fixture(self,root):
        captures = root/'Captures';captures.mkdir()
        source = root/'worker.py';source.write_text('RGB_OUTPUT_UNDISTORTED=True\n')
        source_sha = E.sha(source)
        model_id = E.read(E.WORKERS/'reference.json')['modelID']
        prior = {'status':'conditional_torso_bundle_candidate_not_registered','registrationVerified':False,
                 'modelID':model_id,'pixelModel':{'fixedDistortionApplied':False},'parameters':{
                     'panScale':1.9,'lowerScale':1.7,'upperScale':1.8,'lowerOffsetRadians':-.2,
                     'cameraDeltaRx':-.08,'cameraDeltaRy':.015,'cameraDeltaRz':-.02,
                     'cameraDistanceFromAssumedUpperCenterMeters':.15,'cameraAzimuthRadians':.1,'cameraElevationRadians':.7}}
        E.write(root/'fit.json',prior)
        depth = {'model':'inverse_scale_bias','registrationVerified':False,'calibrationApplied':False,
                 'parameters':[.9350057615863435,.18777543285332365],
                 'domain':{'rawDepthMinimumMeters':.64,'rawDepthMaximumMeters':1.22}}
        E.write(root/'depth.json',depth)
        roles = [];data = {};ids = []
        K = [150.,150.,80.,60.]
        for i in range(9):
            identifier = 'capture-'+str(i);ids.append(identifier);folder = captures/identifier;folder.mkdir()
            near = i >= 5;marker = 'ROB:TABLE:001' if near else 'ROB:FLOOR:R01'
            split = 'heldout' if i in (3,4,8) else 'train'
            scope = {'modelID':model_id,'geometryID':'geometry','mappingID':'right','cameraGeneration':'generation',
                     'gatewaySessionGeneration':1,'displayCorrectionIdentity':'manual:body:epoch',
                     'intrinsicsIdentity':'native','panTarget':6000+i*10,'lowerTarget':6011 if near else 6495,'upperTarget':5900}
            roles.append({**{k:scope[k] for k in ('panTarget','lowerTarget','upperTarget')},'markerIDs':[marker],'split':split})
            frames = [];views = [];observations = []
            z = .7 if near else 1.18
            R = cv2.Rodrigues(np.array([.05,.12,.02]))[0]@np.diag([1.,-1.,-1.]);t = np.array([.02,.01,z])
            pixels = cv2.projectPoints(E.D.object_corners(.12),cv2.Rodrigues(R)[0],t,
                         np.array([[150.,0,80.],[0,150.,60.],[0,0,1.]]),np.zeros(5))[0].reshape(4,2).tolist()
            for j in range(3):
                name = 'frame-'+str(j);depth_path = folder/(name+'.depth-u16le')
                depth_path.write_bytes(np.full((120,160),round(z*1000),dtype='<u2').tobytes())
                cv2.imwrite(str(folder/(name+'.jpg')),np.full((120,160),100,np.uint8))
                frame = {'depthPath':depth_path.name,'width':160,'height':120,'previewWidth':160,'previewHeight':120,
                    'captureSHA256':E.sha(depth_path),'intrinsics':K,'sequence':i*10+j+1,'capturedAtMilliseconds':2000+i*100+j,
                    'cameraServiceSourceSHA256':source_sha,'rgbOutputUndistorted':True}
                frames.append(frame)
            E.write(folder/'capture-input.json',{'scope':scope,'frames':frames})
            metadata_sha = E.sha(folder/'capture-input.json')
            for j,frame in enumerate(frames):
                evidence = {'capturePath':str(folder),'captureInputSHA256':metadata_sha,
                    'sourceImagePath':str(folder/('frame-'+str(j)+'.jpg')),'sourceImageSHA256':E.sha(folder/('frame-'+str(j)+'.jpg')),
                    'depthPath':str(folder/frame['depthPath']),'depthSHA256':frame['captureSHA256'],
                    'frameSequence':frame['sequence'],'capturedAtMilliseconds':frame['capturedAtMilliseconds'],'scope':scope}
                views.append({'targetID':marker,'sourceEvidence':evidence,'imageSize':[160,120],'cameraMatrix':K,'cornersPixels':pixels})
                observations.append({'id':identifier+'-'+str(j),'markerID':marker,'poseID':str(i),'split':'heldout',
                    'rangeGroup':'near' if near else 'far','width':160,'height':120,'cameraMatrix':K,
                    'cornersPixels':pixels,'markerSizeMeters':.12,'zeroDistortionAssumed':True,**evidence})
            data[identifier] = (marker,views,observations)
        E.write(root/'roles.json',{'schemaVersion':1,'frozenAtMilliseconds':1000,'roles':roles})
        args = argparse.Namespace(evidence_root=root,captures_root=captures,output=root/'Derived',camera_service_source=source,
            camera_service_sha256=source_sha,role_manifest=root/'roles.json',include_capture=ids,requested_capture=ids[5],
            parameter_fit=root/'fit.json',depth_candidate=root/'depth.json',cache=root/'cache')
        def assemble(reference,captures,output,cache,include_capture_ids):
            output.mkdir();manifest = {'captures':[]};depth_observations = []
            for marker in ('ROB:FLOOR:R01','ROB:TABLE:001'):
                name = marker.replace(':','-')+'.json';views = []
                for identifier,(m,v,o) in data.items():
                    if m == marker:views.extend(v);depth_observations.extend(o)
                E.write(output/name,{'views':views});manifest['captures'].append({'refinedCapturePath':name})
            E.write(output/'multi-manifest.json',manifest)
            E.write(output/'depth-observations.json',{'observations':depth_observations})
        return args,assemble

    def test_export_uses_frozen_parameters_and_predeclared_roles_without_refitting(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp);args,assemble = self.fixture(root)
            original = {p:E.sha(p) for p in args.captures_root.rglob('*') if p.is_file()}
            with patch.object(E.A,'assemble',side_effect=assemble),patch.object(E.D,'_fit',side_effect=AssertionError('must not refit')):
                package = E.export(args)
            self.assertEqual(original,{p:E.sha(p) for p in original})
            rgb = E.read(package['rgbInputPath']);depth = E.read(package['depthReportPath'])
            self.assertEqual(sum(o['training'] for o in rgb['observations']),18)
            self.assertEqual(sum(not o['training'] for o in rgb['observations']),9)
            self.assertEqual(depth['parameters'],E.read(args.depth_candidate)['parameters'])
            self.assertFalse(depth['parametersOptimized']);self.assertFalse(depth['candidateValidated'])
            self.assertEqual(rgb['parameterFitEvidenceSHA256'],E.sha(args.parameter_fit))
            self.assertEqual(package['pixelModelContractSHA256'],args.camera_service_sha256)
            self.assertEqual(rgb['scope'],E.read(args.captures_root/args.requested_capture/'capture-input.json')['scope'])

    def test_legacy_false_pipeline_and_wrong_worker_reject_before_detector(self):
        edits = [lambda f:f.pop('cameraServiceSourceSHA256'),lambda f:f.update(cameraServiceSourceSHA256='f'*64),
                 lambda f:f.pop('rgbOutputUndistorted'),lambda f:f.update(rgbOutputUndistorted=False)]
        for edit in edits:
            with self.subTest(edit=edit),tempfile.TemporaryDirectory() as temp:
                args,_ = self.fixture(Path(temp));path = args.captures_root/'capture-0/capture-input.json'
                doc = E.read(path);edit(doc['frames'][0]);E.write(path,doc)
                with patch.object(E.A,'assemble',side_effect=AssertionError('must reject first')),self.assertRaisesRegex(ValueError,'running-worker'):
                    E.export(args)

    def test_changed_epoch_unobserved_requested_pose_and_unfrozen_roles_reject(self):
        for change in ('scope','requested','roles'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as temp:
                args,_ = self.fixture(Path(temp))
                if change == 'requested':args.requested_capture = 'uncaptured'
                elif change == 'scope':
                    path = args.captures_root/'capture-1/capture-input.json';doc = E.read(path)
                    doc['scope']['displayCorrectionIdentity'] = 'body:moved';E.write(path,doc)
                else:
                    doc = E.read(args.role_manifest);doc['frozenAtMilliseconds'] = 9999;E.write(args.role_manifest,doc)
                with patch.object(E.A,'assemble',side_effect=AssertionError('must reject first')),self.assertRaises(ValueError):E.export(args)

    def test_insufficient_whole_pose_roles_and_missing_marker_training_reject(self):
        with tempfile.TemporaryDirectory() as temp:
            args,_ = self.fixture(Path(temp));doc = E.read(args.role_manifest)
            doc['roles'][3]['split'] = 'train';E.write(args.role_manifest,doc)
            with self.assertRaisesRegex(ValueError,'three held-out'):E.export(args)
        with tempfile.TemporaryDirectory() as temp:
            args,assemble = self.fixture(Path(temp));doc = E.read(args.role_manifest)
            doc['roles'][5]['markerIDs'] = ['ROB:WALL:R01'];E.write(args.role_manifest,doc)
            with patch.object(E.A,'assemble',side_effect=assemble),self.assertRaisesRegex(ValueError,'coverage'):E.export(args)

    def test_saved_pose_plan_schema_retains_its_original_pre_acquisition_time(self):
        with tempfile.TemporaryDirectory() as temp:
            args,assemble = self.fixture(Path(temp));doc = E.read(args.role_manifest)
            saved = {'schemaVersion':1,'createdUTC':'1970-01-01T00:00:01+00:00',
                     'parametersFrozenBeforeCapture':True,'poses':doc['roles']}
            E.write(args.role_manifest,saved)
            with patch.object(E.A,'assemble',side_effect=assemble):E.export(args)
            self.assertEqual(E.read(args.output/'roles.json'),saved)


if __name__ == '__main__':unittest.main()
