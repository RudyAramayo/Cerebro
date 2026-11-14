#!/usr/bin/env python3
"""Assemble saved fixed-head RGB-D captures into unverified QR diagnostics.

No camera, servo, registration-promotion, or calibration-write APIs. Native Vision
only reads saved JPEGs. Exact printed-module refinement is mandatory for strict
outputs; decoded but occluded symbols remain in the raw/rejection evidence.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
import cv2
import numpy as np
cv2.setNumThreads(1)

ROOT = Path(__file__).resolve().parents[1]
WORKERS = ROOT/'Cerebro/Resources/ShadowPlanner'
TARGETS = {'ROB:TABLE:001': 'table', 'ROB:FLOOR:L01': 'floor-left',
           'ROB:FLOOR:R01': 'floor-right', 'ROB:WALL:R01': 'wall-right'}
PRINTED_SCALE_EVIDENCE = ('User reports a bar labelled120mm measures120mm. Generated120mm '
                          'dimension bars span the black QR symbol; a separate100mm scale-check '
                          'ruler exists. Absolute dimensions are conditional on identification '
                          'of the measured bar.')
IDENTITY_KEYS = ('cameraGeneration', 'displayCorrectionIdentity', 'gatewaySessionGeneration',
                 'geometryID', 'intrinsicsIdentity', 'mappingID', 'modelID')
SWIFT = r'''import Foundation
import Vision
import ImageIO
var records:[[String:Any]]=[]
for name in CommandLine.arguments.dropFirst() {
 let url=URL(fileURLWithPath:name)
 guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { fatalError("Unreadable saved JPEG") }
 let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
 try VNImageRequestHandler(cgImage:image,orientation:.up).perform([request])
 for o in request.results ?? [] {
  records.append(["image":url.lastPathComponent,"payload":o.payloadStringValue ?? "","confidence":o.confidence,"cornersPixels":[o.topLeft,o.topRight,o.bottomRight,o.bottomLeft].map{[Double($0.x)*Double(image.width),(1-Double($0.y))*Double(image.height)]}])
 }
}
print(String(data:try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys]),encoding:.utf8)!)
'''


def module(name):
    spec = importlib.util.spec_from_file_location(name, WORKERS/(name+'.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False)+'\n')
    path.chmod(0o600)


def scope_identity(scope):
    """No missing identity fields and no cross-camera/body/gateway merging."""
    if not isinstance(scope, dict) or any(key not in scope for key in IDENTITY_KEYS):
        raise ValueError('Incomplete fixed-head source scope')
    return tuple(scope[key] for key in IDENTITY_KEYS)


def pose_key(scope):
    values = tuple(scope[key] for key in ('panTarget', 'lowerTarget', 'upperTarget'))
    if any(type(value) is not int for value in values):
        raise ValueError('Raw neck targets must be integers')
    return values


def pose_id(key):
    return 'P%d-L%d-U%d' % key


def choose_training(poses, markers_by_pose=None):
    """Reserve entire command poses, choosing a split with training excitation.

    Exact repeated commands always share a split. For >=13 distinct poses, hold
    out three while maximizing the minimum training singular value. This split
    uses commands and marker visibility only, never image residuals or held-out
    fitting performance. Where possible every marker keeps three training poses
    and a marker visible at four poses has at least one whole-pose holdout.
    """
    poses = sorted(set(poses))
    held_count = 3 if len(poses) >= 13 else max(1, len(poses)//4)
    if len(poses) <= 1:
        return {key: True for key in poses}
    angles = np.array([[(p-6000)*.03, (l-6011)*.03, -(u-6906)*.03] for p,l,u in poses])
    best = None
    for held in itertools.combinations(range(len(poses)), held_count):
        train = np.delete(angles, held, axis=0)
        visible_markers = set().union(*(markers_by_pose.values())) if markers_by_pose else set()
        train_keys = [key for i,key in enumerate(poses) if i not in held]
        marker_count = min((sum(marker in markers_by_pose.get(key,set()) for key in train_keys)
                            for marker in visible_markers),default=3)
        validation_markers = {marker for marker in visible_markers
                              if sum(marker in markers_by_pose.get(key,set()) for key in poses) >= 4}
        held_keys = [poses[i] for i in held]
        held_marker_count = min((sum(marker in markers_by_pose.get(key,set()) for key in held_keys)
                                 for marker in validation_markers),default=1)
        if len(train) < 2:
            score = (-1., -1., -1., -1.)
        else:
            singular = np.linalg.svd(np.radians(train-train.mean(0)), compute_uv=False)
            smallest = singular[-1] if len(singular) == 3 else 0.
            score = (min(marker_count,3), min(held_marker_count,1),
                     min(float(np.min(np.ptp(train,axis=0))), 2.), float(smallest))
        if best is None or score > best[0]:
            best = (score, held)
    held = set(best[1])
    return {key: i not in held for i,key in enumerate(poses)}


def append_heldout_split(reference, identity, observable):
    """Freeze a prior derived split; newly collected commands are held out.

    This permits fitting a provisional dataset and subsequently predicting new
    measurements without relabelling previously trained poses as validation.
    """
    if reference.get('cameraStreamScopeIdentity') != list(identity):
        raise ValueError('Split reference belongs to another exact camera/body scope')
    previous = {}
    for observation in reference.get('observations',[]):
        if scope_identity(observation['scope']) != tuple(identity):
            raise ValueError('Reference observation has a conflicting exact scope')
        key = pose_key(observation['scope'])
        flag = observation.get('split')
        if flag not in ('train','heldout'):
            raise ValueError('Invalid reference observation split')
        if key in previous and previous[key] != (flag == 'train'):
            raise ValueError('Reference assigns one command pose to both splits')
        previous[key] = flag == 'train'
    if not previous:
        raise ValueError('Split reference has no observations')
    return {key:previous.get(key,False) for key in observable}


def validate_frame(directory, frame):
    depth_path = directory/frame['depthPath']
    # Basenames only prevent saved metadata from escaping its capture directory.
    if depth_path.parent != directory or depth_path.suffix != '.depth-u16le':
        raise ValueError('Unexpected saved depth path')
    width,height = frame['width'],frame['height']
    raw = depth_path.read_bytes()
    if len(raw) != width*height*2 or digest(depth_path) != frame['captureSHA256']:
        raise ValueError('Saved depth size/hash does not match capture evidence')
    image_path = depth_path.with_suffix('.jpg')
    image = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if image is None or list(image.shape) != [height,width]:
        raise ValueError('Saved JPEG/depth geometry mismatch')
    if [frame['previewWidth'],frame['previewHeight']] != [width,height]:
        raise ValueError('RGB/depth alignment dimensions differ')
    k = np.array(frame['intrinsics'], dtype=float)
    if k.shape != (4,) or not np.isfinite(k).all() or np.any(k[:2] <= 0):
        raise ValueError('Invalid recorded optical intrinsics')
    depth = np.frombuffer(raw, dtype='<u2').reshape(height,width)*.001
    return image_path,image,depth_path,depth


def depth_summary(depth, corners, k, target_to_camera):
    mask = np.zeros(depth.shape, np.uint8)
    cv2.fillConvexPoly(mask, np.rint(corners).astype(np.int32), 1)
    mask = cv2.erode(mask, np.ones((7,7),np.uint8))
    valid = (mask > 0) & (depth >= .05) & (depth <= 10.)
    yy,xx = np.where(valid); z = depth[yy,xx]
    result = {'interiorErosionPixels':3, 'interiorPixelCount':int(np.count_nonzero(mask)),
              'validPixelCount':len(z), 'validFraction':float(len(z)/max(1,np.count_nonzero(mask)))}
    if len(z) < 20:
        return result
    xyz = np.column_stack(((xx-k[2])*z/k[0],(yy-k[3])*z/k[1],z))
    normal = target_to_camera[:3,2]
    center = target_to_camera[:3,3]
    residual = np.einsum('ij,j->i',xyz-center,normal)
    selected = np.ones(len(z),dtype=bool)
    for _ in range(3):
        mean = xyz[selected].mean(0)
        _,_,vt = np.linalg.svd(xyz[selected]-mean,full_matrices=False)
        fitted = vt[-1]
        deviations = np.einsum('ij,j->i',xyz-mean,fitted)
        median = np.median(deviations[selected])
        mad = np.median(abs(deviations[selected]-median))
        proposed = abs(deviations-median) <= max(.003,3*1.4826*mad)
        if np.count_nonzero(proposed) < 20:
            break
        selected = proposed
    fitted *= 1 if np.sum(fitted*normal) >= 0 else -1
    result.update(rawDepthMedianMeters=float(np.median(z)),
                  rawDepthP05Meters=float(np.percentile(z,5)),rawDepthP95Meters=float(np.percentile(z,95)),
                  qrPlaneSignedResidualMedianMeters=float(np.median(residual)),
                  qrPlaneAbsoluteResidualP95Meters=float(np.percentile(abs(residual),95)),
                  rawDepthPlaneNormalOptical=fitted.tolist(),
                  rawDepthPlaneHeightMeters=float(abs(np.sum(fitted*mean))),
                  rawDepthPlaneRobustInliers=int(np.count_nonzero(selected)),
                  rawDepthPlaneNormalDifferenceDegrees=float(np.degrees(np.arccos(np.clip(np.sum(fitted*normal),-1,1)))),
                  outlierPolicy='All valid interior samples retained in source depth; robust subset only describes raw plane')
    return result


def detect(directory, image_paths, cache, swift_path):
    key = hashlib.sha256(('native-Vision-v1:'+''.join(digest(p) for p in image_paths)).encode()).hexdigest()
    cache_path = cache/(key+'.json')
    if cache_path.exists():
        return read_json(cache_path)
    # Existing native detections are accepted only as detector seeds. Strict
    # printed-pattern/image verification still runs against current image hash.
    saved = directory/'offline-qr-detections.json'
    if saved.exists():
        detections = read_json(saved)
    else:
        result = subprocess.run(['xcrun','swift',str(swift_path),*[str(p) for p in image_paths]],
                                check=True,capture_output=True,text=True,timeout=90)
        detections = json.loads(result.stdout)
    if not isinstance(detections,list):
        raise ValueError('Native detector output must be an array')
    write_json(cache_path,detections)
    return detections


def assemble(reference, captures_root, output, cache, split_reference=None, include_capture_ids=None):
    if output.exists():
        raise ValueError('Output must be a new directory; derived snapshots are immutable')
    output.mkdir(parents=True,mode=0o700)
    cache.mkdir(parents=True,exist_ok=True,mode=0o700)
    qr,refine,joint = (module(name) for name in ('qr_neck_calibration','qr_corner_refinement','qr_neck_joint_calibration'))
    # Locate the canonical resources using the same model expected by fit workers.
    model_dir = next(p.parent for p in (ROOT/'Cerebro/Resources').rglob('reference.json') if (p.parent/'model.urdf').exists())
    model = joint.NeckModel(model_dir)
    reference_input = read_json(reference/'capture-input.json')
    identity = scope_identity(reference_input['scope'])
    selected,excluded = [],[]
    include_capture_ids = set(include_capture_ids) if include_capture_ids is not None else None
    for path in sorted(captures_root.glob('*/capture-input.json')):
        if include_capture_ids is not None and path.parent.name not in include_capture_ids:
            excluded.append({'capturePath':str(path.parent),'reason':'outside explicit immutable capture ID snapshot'})
            continue
        document = read_json(path)
        if scope_identity(document['scope']) == identity:
            selected.append((path.parent,document))
        else:
            excluded.append({'capturePath':str(path.parent),'reason':'different exact fixed-head camera/body/gateway/model scope'})
    if not selected:
        raise ValueError('No matching captures')
    if include_capture_ids is not None and {path.name for path,_ in selected} != include_capture_ids:
        raise ValueError('Explicit capture ID unavailable or belongs to another exact scope')
    if model.model_id != reference_input['scope']['modelID']:
        raise ValueError('Recorded model identity differs from canonical solver model')
    split = choose_training([pose_key(doc['scope']) for _,doc in selected])
    session = str(uuid.uuid4())
    raw_by_target = {target:[] for target in TARGETS}
    strict_by_target = {target:[] for target in TARGETS}
    evidence,rejected,source_records = [],[],[]
    with tempfile.TemporaryDirectory(prefix='rob-saved-qr-') as temp:
        swift_path = Path(temp)/'detect.swift';swift_path.write_text(SWIFT)
        for directory,document in selected:
            scope = document['scope'];key = pose_key(scope)
            frames = document['frames']
            if any(frames[i]['sequence'] >= frames[i+1]['sequence'] or
                   frames[i]['capturedAtMilliseconds'] >= frames[i+1]['capturedAtMilliseconds'] for i in range(len(frames)-1)):
                raise ValueError('Non-monotonic saved frame sequence/time')
            validated = [validate_frame(directory,frame) for frame in frames]
            detections = detect(directory,[v[0] for v in validated],cache,swift_path)
            source_records.append({'capturePath':str(directory),'captureInputSHA256':digest(directory/'capture-input.json'),
                                   'scope':scope,'frameCount':len(frames)})
            commands = [[(key[0]-6000)*.03,key[1],key[2]]]
            neck_prior = model.frames(commands,np.ones(3))[0].reshape(-1).tolist()
            for frame_index,(frame,(image_path,image,depth_path,depth)) in enumerate(zip(frames,validated)):
                matching = [o for o in detections if o.get('image') == image_path.name and o.get('payload') in TARGETS]
                counts = Counter(o['payload'] for o in matching)
                for observed in matching:
                    target = observed['payload']
                    identifier = directory.name+'-'+str(frame_index)
                    source = {'capturePath':str(directory),'captureInputSHA256':digest(directory/'capture-input.json'),
                              'sourceImagePath':str(image_path),'sourceImageSHA256':digest(image_path),
                              'depthPath':str(depth_path),'depthSHA256':frame['captureSHA256'],
                              'frameSequence':frame['sequence'],'capturedAtMilliseconds':frame['capturedAtMilliseconds'],
                              'scope':scope}
                    view = {'id':identifier,'targetID':target,'training':split[key],
                            'cameraMatrix':frame['intrinsics'],'imageSize':[frame['width'],frame['height']],
                            'cornersPixels':observed['cornersPixels'],'lowerTarget':key[1],
                            'neckUpperTarget':key[2],'neckPanDegrees':commands[0][0],
                            'baseToNeck':neck_prior,'baseToNeckSource':'canonical_unverified_command_prior_for_legacy_parser',
                            'poseID':pose_id(key),'imuObservationAvailable':False,'sourceEvidence':source}
                    raw_by_target[target].append(view)
                    reject = {'id':identifier,'targetID':target,**source,'rawCornersPixels':observed['cornersPixels']}
                    try:
                        if counts[target] != 1:
                            raise ValueError('Target ID occurs more than once in the same image')
                        refine_key = hashlib.sha256((source['sourceImageSHA256']+target+json.dumps(observed['cornersPixels'])+digest(WORKERS/'qr_corner_refinement.py')).encode()).hexdigest()
                        refined_cache = cache/(refine_key+'.refined.json')
                        if refined_cache.exists():
                            cached = read_json(refined_cache)
                            if 'reason' in cached:
                                raise ValueError(cached['reason'])
                            corners,quality = np.array(cached['cornersPixels']),cached['quality']
                        else:
                            try:
                                corners,quality = refine.refine_image(image,np.array(observed['cornersPixels']),target)
                            except ValueError as exc:
                                write_json(refined_cache,{'reason':str(exc)})
                                raise
                            write_json(refined_cache,{'cornersPixels':corners.tolist(),'quality':quality})
                        strict = {**view,'cornersPixels':corners.tolist(),'rawCornersPixelsBeforeRefinement':observed['cornersPixels'],
                                  'cornerRefinement':{'status':'accepted_diagnostic',**quality,'sourceImageSHA256':source['sourceImageSHA256']}}
                        pose = qr.pose_for_view(strict)
                        if pose['poseAmbiguous']:
                            raise ValueError('QR PnP is ambiguous by existing worker criterion')
                        transform = pose['targetToCamera'];normal = transform[:3,2]
                        summary = depth_summary(depth,corners,frame['intrinsics'],transform)
                        strict['depthObservation'] = summary
                        if 'rawDepthMedianMeters' in summary:
                            # Center patch is distinct from full-interior median.
                            center = np.mean(corners,axis=0).round().astype(int)
                            patch = depth[max(0,center[1]-2):center[1]+3,max(0,center[0]-2):center[0]+3]
                            z = patch[(patch>=.05)&(patch<=10)]
                            if len(z): strict['centerDepthMeters'] = float(np.median(z))
                        strict_by_target[target].append(strict)
                        evidence.append({'id':identifier+'-'+TARGETS[target],'markerID':target,'poseID':pose_id(key),
                                         'split':'train' if split[key] else 'heldout',
                                         'rangeGroup':'far' if 'FLOOR' in target else ('near' if 'TABLE' in target else 'wall'),
                                         'width':frame['width'],'height':frame['height'],'cameraMatrix':frame['intrinsics'],
                                         'cornersPixels':corners.tolist(),'markerSizeMeters':.12,
                                         'zeroDistortionAssumed':True,'cornerEvidence':strict['cornerRefinement'],
                                         'printedScaleEvidence':PRINTED_SCALE_EVIDENCE,
                                         'targetToCameraColumnMajor':transform.T.reshape(-1).tolist(),
                                         'qrReprojectionRMSPixels':pose['reprojectionRMSEPixels'],
                                         'qrAlternativePoses':pose['alternativePoses'],
                                         'qrFloorNormalOptical':normal.tolist() if 'FLOOR' in target else None,
                                         'conditionalCameraHeightAbovePlaneMeters':float(abs(np.sum(normal*transform[:3,3]))),
                                         'conditionalOpticalAxisDepressionDegrees':float(np.degrees(np.arcsin(np.clip(-normal[2],-1,1)))) if 'FLOOR' in target else None,
                                         'depthSummary':summary,**source})
                    except ValueError as exc:
                        rejected.append({**reject,'reason':str(exc)})
    # A command with no accepted symbol cannot supply either split. In
    # particular, an occluded-only pose must not consume a held-out slot while
    # a visible pose is unnecessarily reserved for training. Choose the final
    # split from strict observable commands, using command excitation only.
    observable = {pose_key(observation['scope']) for observation in evidence}
    markers_by_pose = {key:{o['markerID'] for o in evidence if pose_key(o['scope']) == key}
                       for key in observable}
    observable_split = choose_training(observable,markers_by_pose)
    if split_reference is not None:
        observable_split = append_heldout_split(read_json(split_reference),identity,observable)
    split = {key:observable_split.get(key,True) for key in split}
    split_by_id = {pose_id(key):value for key,value in split.items()}
    for views in list(raw_by_target.values())+list(strict_by_target.values()):
        for view in views:
            view['training'] = split_by_id[view['poseID']]
    for observation in evidence:
        observation['split'] = 'train' if split_by_id[observation['poseID']] else 'heldout'
    manifest = {'schemaVersion':1,'captureKind':'multi_target_neck_survey','robotBaseStationary':True,
                'registrationVerified':False,'sessionID':session,'sceneContextID':session,'captures':[]}
    for target,slug in TARGETS.items():
        raw_views,strict_views = raw_by_target[target],strict_by_target[target]
        if not raw_views: continue
        base = {'schemaVersion':1,'targetID':target,'symbolSideMeters':.12,'modelID':model.model_id,
                'registrationVerified':False,'surveySessionID':session,'sceneContextID':session,
                'poseSource':'recorded_raw_commands_unverified_geometry','imuObservationAvailable':False,
                'physicalScaleEvidence':PRINTED_SCALE_EVIDENCE}
        raw_path,strict_path = output/(slug+'.raw.json'),output/(slug+'.strict.json')
        write_json(raw_path,{**base,'views':raw_views})
        write_json(strict_path,{**base,'views':strict_views,'cornerRefinement':{
            'status':'diagnostic_only','method':'exact_printed_modules_ECC_homography','methodVersion':2,
            'sourceCaptureSHA256':digest(raw_path),'acceptedViews':len(strict_views),'rejectedViews':len(raw_views)-len(strict_views),
            'rejectedViewsExcludedFromStrictSolver':True,'minimumCorrelation':refine.MINIMUM_CORRELATION,
            'minimumOrientationCorrelationMargin':refine.MINIMUM_ORIENTATION_MARGIN}})
        if strict_views:
            manifest['captures'].append({'targetID':target,'status':'partial' if len(strict_views)<len(raw_views) else 'complete',
                                         'capturePath':raw_path.name,'refinedCapturePath':strict_path.name,'samples':len(raw_views)})
    blockers = []
    if len(manifest['captures']) >= 2:
        write_json(output/'multi-manifest.json',manifest)
        try:
            multi = module('qr_neck_multi_calibration')
            _,_,loaded,_ = multi.load_manifest(output/'multi-manifest.json')
            prepared = multi.prepare(loaded,model)
            readiness = {key:prepared[key] for key in ('trainingPoseCount','heldOutPoseCount','ranges','excitation','perMarkerTrainingPoseCounts')}
        except ValueError as exc:
            blockers.append(str(exc));readiness = None
    else:
        blockers.append('Fewer than two target IDs have strict accepted observations; no solver-ready multi-manifest emitted')
        readiness = None
    write_json(output/'depth-observations.json',{'schemaVersion':1,'registrationVerified':False,'observations':evidence,
                                               'cameraStreamScopeIdentity':scope_identity(reference_input['scope']),
                                               'splitReferenceSHA256':digest(split_reference) if split_reference else None,
                                               'newPoseSplitPolicy':'heldout' if split_reference else 'commands_and_visibility_only',
                                               'stereoSettingsMetadataAvailable':False,
                                               'imuObservationAvailable':False})
    report = {'schemaVersion':1,'registrationVerified':False,'sourceScope':reference_input['scope'],
              'sourceCaptures':source_records,'excludedCaptures':excluded,'rawObservationCounts':{k:len(v) for k,v in raw_by_target.items()},
              'strictObservationCounts':{k:len(v) for k,v in strict_by_target.items()},'rejectedObservations':rejected,
              'commandPoseSplit':{pose_id(key):('train' if value else 'heldout') if key in observable else 'not_strictly_observed' for key,value in split.items()},
              'strictUniqueCommandPoseCount':len(observable),
              'strictTrainingCommandPoseCount':sum(observable_split.values()),
              'strictHeldOutCommandPoseCount':len(observable_split)-sum(observable_split.values()),
              'splitReferencePath':str(split_reference) if split_reference else None,
              'splitReferenceSHA256':digest(split_reference) if split_reference else None,
              'solverReadiness':readiness,'solverBlockers':blockers,
              'limitations':['No measured base XYZ or yaw; fixed floor QR planes supply orientation and conditional height only.',
                             'No registration promotion, pixel/depth correction, hardware control, or invented IMU observations.',
                             'All absolute lengths conditional on actual120mm black symbol size; generated dimension bars span that boundary.']}
    write_json(output/'assembly-report.json',report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-capture',required=True,type=Path)
    parser.add_argument('--captures-root',type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--cache',type=Path,default=Path.home()/'Library/Application Support/Cerebro/FixedHeadRegistration/OfflineQRCache')
    parser.add_argument('--split-reference',type=Path,help='Prior depth-observations.json: preserve its exact splits and hold out all newly collected command poses')
    parser.add_argument('--include-capture',action='append',help='Exact saved capture directory ID to include; repeat to freeze an explicit snapshot rather than include every matching scope')
    args = parser.parse_args()
    reference = args.reference_capture.expanduser().resolve()
    report = assemble(reference,(args.captures_root or reference.parent).expanduser().resolve(),args.output.expanduser().resolve(),args.cache.expanduser().resolve(),
                      args.split_reference.expanduser().resolve() if args.split_reference else None,
                      args.include_capture)
    print(json.dumps({'output':str(args.output),'strictObservationCounts':report['strictObservationCounts'],
                      'solverReadiness':report['solverReadiness'],'solverBlockers':report['solverBlockers']},indent=2))


if __name__ == '__main__':
    main()
