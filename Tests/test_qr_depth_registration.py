"""Metric QR/native-depth recovery and strict whole-observation holdout tests."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('qr_depth_test',ROOT/'Cerebro/Resources/ShadowPlanner/qr_depth_registration.py')
DEPTH=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(DEPTH)


def fixture(directory, ray=False):
    width,height=640,400;fx=fy=488.;cx=320.;cy=200.
    K=np.array([[fx,0,cx],[0,fy,cy],[0,0,1.]])
    observations=[]
    yy,xx=np.mgrid[:height,:width]
    x=(xx-cx)/fx;y=(yy-cy)/fy
    rays=np.stack((x,y,np.ones_like(x)),axis=-1)
    # Distinct whole poses and a wholly unseen marker and intermediate range.
    definitions=[(.48,-.10,-.03),(.65,.12,.04),(1.20,-.20,.10),
                 (1.05,.20,-.10),(.54,.10,.05),(.95,-.12,.02),
                 (.74,-.13,-.02),(.88,.12,.07),(.80,0.,-.07)]
    for i,(distance,tx,ty) in enumerate(definitions):
        perturbation=np.array([.30+.025*i,-.25+.035*i,.10])
        R=cv2.Rodrigues(perturbation)[0]@np.diag([1.,-1.,-1.])
        rvec=cv2.Rodrigues(R)[0];t=np.array([tx,ty,distance]);n=R[:,2]
        true=float(np.dot(n,t))/np.einsum('ijk,k->ij',rays,n)
        if ray:
            a=1.02+.08*x-.04*y;b=.06+.035*x+.025*y
        else:a=1.02;b=.08
        raw=a/(1/true-b)
        data=np.clip(np.round(raw*1000),1,65535).astype('<u2')
        path=Path(directory)/f'depth-{i}.bin';data.tofile(path)
        image_path=Path(directory)/f'synthetic-source-{i}.bin';image_path.write_bytes(f'synthetic RGB provenance {i}'.encode())
        corners=cv2.projectPoints(DEPTH.object_corners(.12),rvec,t,K,np.zeros(5))[0].reshape(4,2)
        assert np.min(corners)>0 and np.max(corners[:,0])<width and np.max(corners[:,1])<height
        train=i<6
        observations.append({'id':f'observation-{i}','markerID':'table' if train and i in (0,1,4) else ('floor' if train else 'unseen-reference'),
            'poseID':f'pose-{i}','split':'train' if train else 'heldout',
            'rangeGroup':('near' if distance<.7 else 'far') if train else 'middle',
            'width':width,'height':height,'cameraMatrix':[fx,fy,cx,cy],
            'zeroDistortionAssumed':True,'cornersPixels':corners.tolist(),'markerSizeMeters':.12,
            'scope':{'cameraGeneration':'synthetic-camera','intrinsicsIdentity':'synthetic-intrinsics','gatewaySessionGeneration':1},
            'depthPath':str(path),'depthSHA256':DEPTH.digest(path),
            'sourceImagePath':str(image_path),'sourceImageSHA256':DEPTH.digest(image_path)})
    return {'schemaVersion':1,'observations':observations}


class QRDepthTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.directory=Path(self.temporary.name)
        self.document=fixture(self.directory)

    def tearDown(self):self.temporary.cleanup()

    def test_recovers_metric_inverse_scale_bias_with_unseen_poses_marker_and_range(self):
        result=DEPTH.fit_document(self.document)
        np.testing.assert_allclose(result['parameters'],[1.02,.08],atol=.0006)
        self.assertTrue(result['candidateValidated'],result['checks'])
        self.assertLess(result['heldOut']['opticalZError']['maximumAbsoluteMeters'],.001)
        self.assertGreater(result['heldOut']['observations'][0]['rawPlaneError']['rmseMeters'],.04)
        self.assertFalse(result['registrationVerified']);self.assertFalse(result['calibrationApplied'])
        self.assertTrue(result['domain']['domainIsObservedPatchUnion'])

    def test_heldout_changes_cannot_change_fitted_parameters(self):
        original=DEPTH.fit_document(self.document)
        changed=copy.deepcopy(self.document)
        for observation in changed['observations']:
            if observation['split']=='heldout':
                path=Path(observation['depthPath']);raw=np.fromfile(path,dtype='<u2')
                (raw+80).astype('<u2').tofile(path);observation['depthSHA256']=DEPTH.digest(path)
        result=DEPTH.fit_document(changed)
        np.testing.assert_array_equal(result['parameters'],original['parameters'])
        self.assertFalse(result['candidateValidated'])
        self.assertGreater(result['heldOut']['opticalZError']['rmseMeters'],.05)

    def test_native_interior_outlier_is_retained_and_blocks_maximum_error(self):
        obs=self.document['observations'][-1]
        path=Path(obs['depthPath']);data=np.fromfile(path,dtype='<u2').reshape(400,640)
        # Odd/odd verifies that no every-other-pixel sampling hides this return.
        u,v=np.round(np.mean(obs['cornersPixels'],axis=0)/2).astype(int)*2+1
        data[v,u]=1500;data.tofile(path);obs['depthSHA256']=DEPTH.digest(path)
        result=DEPTH.fit_document(self.document)
        self.assertFalse(result['checks']['heldOutMaximumError'])
        self.assertGreater(result['heldOut']['opticalZError']['maximumAbsoluteMeters'],.4)
        self.assertGreaterEqual(result['heldOut']['opticalZError']['outliersOver30mm'],1)

    def test_whole_pose_leakage_and_changed_depth_hash_are_rejected(self):
        changed=copy.deepcopy(self.document);changed['observations'][-1]['poseID']='pose-0'
        with self.assertRaisesRegex(ValueError,'Whole-pose holdout'):
            DEPTH.fit_document(changed)
        changed=copy.deepcopy(self.document);changed['observations'][0]['depthSHA256']='0'*64
        result=DEPTH.fit_document(changed)
        self.assertFalse(result['candidateValidated'])
        self.assertIn('hash',result['rejectedObservations'][0]['reason'])

    def test_same_range_is_unidentifiable_and_unseen_dimensions_are_not_claimed(self):
        sample=DEPTH.sample_observation(self.document['observations'][0],self.directory)
        sample['raw'][:]=.6;sample['true'][:]=.55
        _,info=DEPTH._fit([sample,sample],'inverse_scale_bias')
        self.assertEqual(info['rank'],1)
        changed=copy.deepcopy(self.document)
        for obs in changed['observations']:
            if obs['split']=='heldout':obs['markerID']='floor';obs['rangeGroup']='far'
        result=DEPTH.fit_document(changed)
        self.assertEqual(result['independentEvidenceDimensions']['unseenFinalHeldOutMarkers'],[])
        self.assertEqual(result['independentEvidenceDimensions']['unseenFinalHeldOutRangeGroups'],[])
        self.assertTrue(all(a['usesFinalHeldOutPoses'] is False for a in result['trainingOnlyGroupCrossValidation']))
        self.assertTrue(all(a['passed'] for a in result['trainingOnlyGroupCrossValidation']))

    def test_optional_ray_model_is_selected_only_by_training_pose_predictions(self):
        document=fixture(self.directory,ray=True)
        result=DEPTH.fit_document(document,allow_ray=True)
        self.assertEqual(result['model'],'inverse_ray',result['trainingOnlyModelSelection'])
        self.assertLess(result['heldOut']['opticalZError']['maximumAbsoluteMeters'],.002)
        changed=copy.deepcopy(document)
        for obs in changed['observations']:
            if obs['split']=='heldout':
                path=Path(obs['depthPath']);data=np.fromfile(path,dtype='<u2')
                (data+50).astype('<u2').tofile(path);obs['depthSHA256']=DEPTH.digest(path)
        rerun=DEPTH.fit_document(changed,allow_ray=True)
        self.assertEqual(rerun['model'],result['model'])
        np.testing.assert_array_equal(rerun['parameters'],result['parameters'])

    def test_monotonic_and_out_of_domain_corrections_cannot_pass(self):
        samples=[DEPTH.sample_observation(obs,self.directory) for obs in self.document['observations']]
        domain=DEPTH.domain_for(samples)
        self.assertFalse(DEPTH.physical_check('inverse_scale_bias',[-1.,0.],domain,DEPTH.DEFAULT_LIMITS)['passed'])
        self.assertFalse(DEPTH.physical_check('inverse_scale_bias',[1.,1.],domain,DEPTH.DEFAULT_LIMITS)['passed'])
        with self.assertRaisesRegex(ValueError,'behind'):
            DEPTH.corrected_depth(samples[0],'inverse_scale_bias',[-1.,0.])

    def test_camera_epoch_mixing_and_missing_rgb_provenance_are_not_validated(self):
        changed=copy.deepcopy(self.document)
        changed['observations'][-1]['scope']['cameraGeneration']='another-camera-epoch'
        result=DEPTH.fit_document(changed)
        self.assertFalse(result['checks']['singleCameraGeometryScope'])
        self.assertFalse(result['candidateValidated'])
        changed=copy.deepcopy(self.document)
        del changed['observations'][-1]['sourceImagePath']
        result=DEPTH.fit_document(changed)
        self.assertFalse(result['checks']['rgbSourceHashesVerified'])


if __name__=='__main__':unittest.main()
