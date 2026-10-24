"""Hardware-free provenance and held-pose splitting checks for saved QR assembly."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np

SPEC = importlib.util.spec_from_file_location('saved_qr_assembly', Path(__file__).resolve().parents[1]/'Scripts/assemble-fixed-head-qr-captures.py')
A = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(A)


class SavedCaptureAssemblyTests(unittest.TestCase):
    def test_scope_prevents_cross_body_camera_and_gateway_merge(self):
        scope = {key: 'value-'+key for key in A.IDENTITY_KEYS}
        base = A.scope_identity(scope)
        for key in A.IDENTITY_KEYS:
            changed = dict(scope)
            changed[key] = 'other-'+key
            self.assertNotEqual(base, A.scope_identity(changed), key)
            missing = dict(scope)
            del missing[key]
            with self.assertRaises(ValueError):
                A.scope_identity(missing)

    def test_repeated_commands_share_whole_pose_split_and_training_excitation(self):
        poses = [(p,l,u) for p in (5960,6000,6040) for l,u in ((6211,5666),(6295,5735),(6395,5780),(6495,5900),(6495,6020))]
        split = A.choose_training(poses+poses[:5])
        self.assertEqual(len(split),15)
        self.assertEqual(sum(not value for value in split.values()),3)
        self.assertEqual(A.choose_training(list(reversed(poses))),split)
        training = np.array([pose for pose,flag in split.items() if flag])
        self.assertGreaterEqual(np.ptp(training[:,0]),80)
        self.assertGreaterEqual(np.ptp(training[:,1]),284)
        self.assertGreaterEqual(np.ptp(training[:,2]),354)
        # More repeated frames cannot alter the pose split or its evidence count.
        self.assertEqual(A.choose_training(poses*5),split)

    def fixture(self,directory):
        directory = Path(directory)
        depth_path = directory/'frame-0.depth-u16le'
        depth_path.write_bytes(np.full((32,48),1200,dtype='<u2').tobytes())
        cv2.imwrite(str(directory/'frame-0.jpg'),np.full((32,48),100,np.uint8))
        return {'depthPath':depth_path.name,'captureSHA256':A.digest(depth_path),
                'width':48,'height':32,'previewWidth':48,'previewHeight':32,
                'intrinsics':[40.,40.,24.,16.]}

    def test_sparse_second_marker_keeps_three_training_poses(self):
        poses = [(p,l,u) for p in (5960,6000,6040) for l,u in ((6211,5666),(6295,5735),(6395,5780),(6495,5900),(6495,6020))]
        second = set(poses[3:7])
        visibility = {pose:({'right','left'} if pose in second else {'right'}) for pose in poses}
        split = A.choose_training(poses,visibility)
        self.assertGreaterEqual(sum(split[pose] for pose in second),3)
        self.assertGreaterEqual(sum(not split[pose] for pose in second),1)
        self.assertEqual(sum(not value for value in split.values()),3)

    def test_append_freezes_prior_labels_and_holds_out_new_measurements(self):
        scope = {key:'value-'+key for key in A.IDENTITY_KEYS}
        identity = A.scope_identity(scope)
        def observation(key,split):
            return {'scope':{**scope,**dict(zip(('panTarget','lowerTarget','upperTarget'),key))},'split':split}
        first,second,new = (6000,6495,5780),(6000,6495,5900),(6111,6011,6235)
        reference = {'cameraStreamScopeIdentity':list(identity),'observations':[
            observation(first,'train'),observation(second,'heldout')]}
        split = A.append_heldout_split(reference,identity,[first,second,new])
        self.assertEqual(split,{first:True,second:False,new:False})
        with self.assertRaisesRegex(ValueError,'another exact'):
            A.append_heldout_split(reference,('changed',)+identity[1:],[new])
        reference['observations'].append(observation(first,'heldout'))
        with self.assertRaisesRegex(ValueError,'both splits'):
            A.append_heldout_split(reference,identity,[first])

    def test_raw_depth_millimeters_and_hash_must_match(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            frame = self.fixture(path)
            _,_,_,depth = A.validate_frame(path,frame)
            self.assertTrue(np.allclose(depth,1.2))
            (path/frame['depthPath']).write_bytes(np.full((32,48),1201,dtype='<u2').tobytes())
            with self.assertRaisesRegex(ValueError,'size/hash'):
                A.validate_frame(path,frame)

    def test_mismatched_rgb_and_depth_geometry_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            frame = self.fixture(path)
            cv2.imwrite(str(path/'frame-0.jpg'),np.full((24,48),100,np.uint8))
            with self.assertRaisesRegex(ValueError,'geometry mismatch'):
                A.validate_frame(path,frame)


if __name__ == '__main__':
    unittest.main()
