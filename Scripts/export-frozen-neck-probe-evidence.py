#!/usr/bin/env python3
"""Export fresh saved captures with frozen neck/depth hypotheses; never actuate.

Roles are declared by raw command pose before acquisition, then bound to exact
capture IDs. Original metadata is never changed. The production Swift importer
independently recomputes RGB geometry; this exporter cannot grant registration.
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WORKERS = ROOT/'Cerebro/Resources/ShadowPlanner'


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


A = load_module('frozen_export_assembly', ROOT/'Scripts/assemble-fixed-head-qr-captures.py')
D = load_module('frozen_export_depth', WORKERS/'qr_depth_registration.py')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False)+'\n')
    path.chmod(0o600)


def within(path, root):
    path = Path(path).resolve()
    if not path.is_relative_to(root) or path == root:
        raise ValueError('Evidence must remain inside the explicit evidence root')
    return path


def roles_for(document):
    if document.get('schemaVersion') != 1:
        raise ValueError('Role manifest needs schemaVersion1 and pre-acquisition frozenAtMilliseconds')
    roles = {}
    for role in document.get('roles', document.get('poses', [])):
        key = A.pose_key(role)
        if key in roles or role.get('split') not in ('train', 'heldout'):
            raise ValueError('Duplicate pose or invalid explicit whole-pose role')
        markers = role.get('markerIDs')
        if not isinstance(markers, list) or not markers or len(set(markers)) != len(markers) or any(m not in A.TARGETS for m in markers):
            raise ValueError('Every role needs explicit supported markerIDs')
        roles[key] = role
    if sum(r['split'] == 'train' for r in roles.values()) < 4 or sum(r['split'] == 'heldout' for r in roles.values()) < 3:
        raise ValueError('Use at least four training and three held-out whole poses')
    return roles


def frozen_at(document):
    value = document.get('frozenAtMilliseconds')
    if value is None and document.get('parametersFrozenBeforeCapture') is True:
        value = datetime.fromisoformat(document['createdUTC']).timestamp()*1000
    if not isinstance(value, (int,float)) or not math.isfinite(value) or value <= 0:
        raise ValueError('Role manifest needs a finite pre-acquisition freeze time')
    return value


def frozen_parameters(report):
    if (report.get('status') != 'conditional_torso_bundle_candidate_not_registered'
            or report.get('registrationVerified') is not False
            or report.get('pixelModel', {}).get('fixedDistortionApplied') is not False):
        raise ValueError('Expected the immutable zero-D conditional neck artifact')
    p = report['parameters']
    radius, azimuth, elevation = (p[k] for k in ('cameraDistanceFromAssumedUpperCenterMeters', 'cameraAzimuthRadians', 'cameraElevationRadians'))
    value = {k:p[k] for k in ('panScale','lowerScale','upperScale','lowerOffsetRadians')}
    value['cameraDeltaRotationVector'] = [p['cameraDeltaR'+a] for a in 'xyz']
    value['cameraTranslationMeters'] = [radius*math.cos(elevation)*math.cos(azimuth),
                                       radius*math.cos(elevation)*math.sin(azimuth), radius*math.sin(elevation)]
    if not all(math.isfinite(x) for x in list(value.values())[:4]+value['cameraDeltaRotationVector']+value['cameraTranslationMeters']):
        raise ValueError('Frozen parameters must be finite')
    return value


def pnp_candidates(view):
    k = view['cameraMatrix']
    K = np.array([[k[0],0,k[2]], [0,k[1],k[3]], [0,0,1.]])
    obj = D.object_corners(.12)
    result = cv2.solvePnPGeneric(obj, np.array(view['cornersPixels']), K, np.zeros(5), flags=cv2.SOLVEPNP_IPPE_SQUARE)
    poses = []
    for rv, tv in zip(result[1], result[2]):
        R = cv2.Rodrigues(rv)[0]; t = tv.reshape(3)
        if np.min((obj@R.T+t)[:,2]) > .05 and float(R[:,2]@t) < 0:
            T = np.eye(4);T[:3,:3] = R;T[:3,3] = t
            poses.append(T.reshape(-1).tolist())
    if not poses:
        raise ValueError('Strict source has no front-facing positive-depth QR branch')
    return poses


def export(args):
    root = args.evidence_root.resolve()
    captures = within(args.captures_root, root)
    output = within(args.output, root)
    if output.exists():
        raise ValueError('Output must be a new immutable derived directory')
    contract = args.camera_service_source.resolve()
    if not re.fullmatch('[0-9a-f]{64}', args.camera_service_sha256) or sha(contract) != args.camera_service_sha256:
        raise ValueError('Actual independently pinned camera-service source SHA mismatch')
    role_document = read(args.role_manifest); roles = roles_for(role_document); role_time = frozen_at(role_document)
    identifiers = args.include_capture
    if not identifiers or len(set(identifiers)) != len(identifiers) or args.requested_capture not in identifiers:
        raise ValueError('Use explicit unique fresh capture IDs including the requested view')
    documents = {}; capture_roles = {}; poses = set(); identity = None; geometry = None
    for identifier in identifiers:
        if not re.fullmatch('[A-Za-z0-9-]{1,80}', identifier):
            raise ValueError('Invalid capture ID')
        directory = within(captures/identifier, root); document = read(directory/'capture-input.json')
        scope = document['scope']; key = A.pose_key(scope)
        if key not in roles or key in poses:
            raise ValueError('Every captured pose needs one frozen role; repeated commands cannot create new evidence')
        poses.add(key); capture_roles[identifier] = roles[key]
        current_identity = A.scope_identity(scope)
        if identity is not None and current_identity != identity:
            raise ValueError('Fresh captures cross camera/body/gateway/model scope')
        identity = current_identity
        if not document['frames'] or len(document['frames']) > 256:
            raise ValueError('Missing or excessive original frames')
        for frame in document['frames']:
            if frame.get('cameraServiceSourceSHA256') != args.camera_service_sha256 or frame.get('rgbOutputUndistorted') is not True:
                raise ValueError('Original capture lacks matching actual running-worker source and undistorted flag; legacy data is offline only')
            if frame['capturedAtMilliseconds'] < role_time:
                raise ValueError('Roles must be frozen before acquisition')
            current_geometry = (frame['width'],frame['height'],tuple(frame['intrinsics']))
            if geometry is not None and current_geometry != geometry:
                raise ValueError('Fresh captures change native aligned pixel geometry')
            geometry = current_geometry
            A.validate_frame(directory,frame)
        documents[identifier] = document
    if poses != set(roles):
        raise ValueError('Every frozen role must have a fresh actual capture')
    prior = read(args.parameter_fit); parameters = frozen_parameters(prior)
    if prior['modelID'] != documents[args.requested_capture]['scope']['modelID']:
        raise ValueError('Frozen neck and current capture model identities differ')
    depth_prior = read(args.depth_candidate)
    if depth_prior.get('model') != 'inverse_scale_bias' or depth_prior.get('registrationVerified') is not False or depth_prior.get('calibrationApplied') is not False:
        raise ValueError('Expected frozen unapplied inverse-scale/bias hypothesis')
    p = np.array(depth_prior['parameters'],dtype=float)
    if p.shape != (2,) or not np.isfinite(p).all():
        raise ValueError('Frozen inverse-depth parameters are invalid')
    output.mkdir(parents=True,mode=0o700)
    assembly = output/'qr'
    A.assemble(captures/args.requested_capture,captures,assembly,args.cache.resolve(),include_capture_ids=identifiers)
    observations = []; observed = set(); marker_training = {}; train = set(); held = set()
    manifest = read(assembly/'multi-manifest.json')
    for item in manifest['captures']:
        document = read(assembly/item['refinedCapturePath'])
        for view in document['views']:
            evidence = view['sourceEvidence']; identifier = Path(evidence['capturePath']).name
            role = capture_roles[identifier]; marker = view['targetID']
            if marker not in role['markerIDs']:
                continue
            training = role['split'] == 'train'; key = A.pose_key(evidence['scope'])
            observed.add(key); (train if training else held).add(key)
            if training: marker_training.setdefault(marker,set()).add(key)
            observations.append({'targetID':marker,'training':training,'scope':evidence['scope'],
                'width':view['imageSize'][0],'height':view['imageSize'][1],'intrinsics':view['cameraMatrix'],
                'distortion':[],'outputPixelModel':'undistorted','pixelModelProvenanceSHA256':args.camera_service_sha256,
                'cornersPixels':view['cornersPixels'],'targetToCameraCandidatesRowMajor':pnp_candidates(view),
                'imageSHA256':evidence['sourceImageSHA256'],'metadataSHA256':evidence['captureInputSHA256'],
                'frameSequence':evidence['frameSequence'],'capturedAtMilliseconds':evidence['capturedAtMilliseconds']})
    all_markers = {o['targetID'] for o in observations}
    if observed != poses or len(train) < 4 or len(held) < 3 or len(all_markers) < 2 or any(len(marker_training.get(m,set())) < 3 for m in all_markers) or not 24 <= len(observations) <= 512:
        raise ValueError('Strict visible data does not fulfill frozen RGB roles/marker coverage')
    depth_document = read(assembly/'depth-observations.json'); samples = []
    for observation in depth_document['observations']:
        identifier = Path(observation['capturePath']).name; role = capture_roles[identifier]
        if observation['markerID'] not in role['markerIDs']:
            continue
        observation['split'] = role['split']
        samples.append(D.sample_observation(observation,assembly))
    training = [s for s in samples if s['metadata']['split'] == 'train']; heldout = [s for s in samples if s['metadata']['split'] == 'heldout']
    if not training or not heldout or len({s['metadata']['rangeGroup'] for s in samples}) < 2:
        raise ValueError('Fresh depth sources need near/far data and both frozen splits')
    domain = D.domain_for(samples)
    domain['rawDepthMinimumMeters'] = max(domain['rawDepthMinimumMeters'],depth_prior['domain']['rawDepthMinimumMeters'])
    domain['rawDepthMaximumMeters'] = min(domain['rawDepthMaximumMeters'],depth_prior['domain']['rawDepthMaximumMeters'])
    if domain['rawDepthMinimumMeters'] >= domain['rawDepthMaximumMeters']:
        raise ValueError('Fresh depth has no overlap with the frozen hypothesis domain')
    physical = D.physical_check('inverse_scale_bias',p,domain,D.DEFAULT_LIMITS)
    if not physical['passed']:
        raise ValueError('Frozen depth hypothesis fails bounded physical check')
    report = {'schemaVersion':1,'kind':'qr_native_depth_correction_diagnostic','model':'inverse_scale_bias',
        'parameters':p.tolist(),'candidateValidated':False,'registrationVerified':False,'calibrationApplied':False,
        'parametersOptimized':False,'frozenCandidateSHA256':sha(args.depth_candidate),'physicalBounds':physical,'domain':domain,
        'training':D.evaluate(training,'inverse_scale_bias',p),'heldOut':D.evaluate(heldout,'inverse_scale_bias',p),
        'sources':[{k:v for k,v in s['metadata'].items() if k != 'targetToCameraColumnMajor'} for s in samples],
        'limitations':['Frozen estimated hypothesis; fresh errors are reported without selecting parameters.',
                       'No measured depth/world/grasp authority; all raw occupied returns must be retained.']}
    rgb = {'schemaVersion':1,'kind':'neck_bundle','scope':documents[args.requested_capture]['scope'],
        'symbolSideMeters':.12,'parameters':parameters,'parameterFitEvidenceSHA256':sha(args.parameter_fit),
        'parameterPositionAllowanceMeters':.014,'observations':observations}
    # Copy only immutable hypothesis/source artifacts, never original captures.
    for name,path in [('frozen-neck-parameters.json',args.parameter_fit),('camera-service-source.py',contract),('frozen-depth-candidate.json',args.depth_candidate)]:
        (output/name).write_bytes(Path(path).read_bytes());(output/name).chmod(0o600)
    write(output/'roles.json',role_document);write(output/'neck-rgb-input.json',rgb);write(output/'depth-report.json',report)
    package = {'schemaVersion':1,'kind':'estimated_fixed_head_raw_corrected_union','purpose':'empty_right_estimated_probe',
               'captureDirectory':str(captures)}
    for key,name in [('rgbInput','neck-rgb-input.json'),('depthReport','depth-report.json'),
                     ('parameterFit','frozen-neck-parameters.json'),('pixelModelContract','camera-service-source.py')]:
        package[key+'Path'] = str(output/name);package[key+'SHA256'] = sha(output/name)
    write(output/'estimated-probe-package.json',package)
    write(output/'export-report.json',{'schemaVersion':1,'registrationVerified':False,'sourceCaptureIDs':identifiers,
        'roleManifestSHA256':sha(args.role_manifest),'sourceSHA256':sha(__file__),'trainingPoses':len(train),'heldOutPoses':len(held),
        'strictObservations':len(observations),'neckParametersOptimized':False,'depthParametersOptimized':False,
        'packageSHA256':sha(output/'estimated-probe-package.json')})
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('captures-root','role-manifest','parameter-fit','depth-candidate','camera-service-source','output'):
        parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--camera-service-sha256',required=True)
    parser.add_argument('--requested-capture',required=True)
    parser.add_argument('--include-capture',action='append',required=True)
    parser.add_argument('--evidence-root',type=Path,default=Path.home()/'Library/Application Support/Cerebro')
    parser.add_argument('--cache',type=Path,default=Path.home()/'Library/Application Support/Cerebro/FixedHeadRegistration/OfflineQRCache')
    args = parser.parse_args(); export(args)
    print(json.dumps({'package':str(args.output/'estimated-probe-package.json'),'registrationVerified':False,'parametersOptimized':False}))


if __name__ == '__main__':
    main()
