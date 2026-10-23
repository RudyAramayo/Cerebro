"""Offline shared neck/camera fit from a fresh stationary multi-target survey.

Fits three command scales and one camera extrinsic shared by all targets, plus
an independent fixed pose for each printed marker. No hardware, URDF writes,
scene-memory reuse or calibration promotion. Floor/wall checks are diagnostics.
"""

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import time

import cv2
import numpy as np

_SPEC = importlib.util.spec_from_file_location('qr_multi_joint_worker', Path(__file__).with_name('qr_neck_joint_calibration.py'))
JOINT = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(JOINT)
QR = JOINT.QR
MAX_TOTAL_VIEWS = 512


def read_json(path, maximum_bytes=5_000_000):
    raw = Path(path).read_bytes()
    if len(raw) > maximum_bytes:
        raise ValueError('JSON input exceeds the bounded file size')
    value = json.loads(raw, parse_constant=lambda v: (_ for _ in ()).throw(ValueError('Invalid JSON number '+v)))
    return value, hashlib.sha256(raw).hexdigest()


def load_manifest(path):
    path = Path(path).resolve()
    document, digest = read_json(path, 100_000)
    if (not isinstance(document, dict) or type(document.get('schemaVersion')) is not int or document['schemaVersion'] != 1
            or document.get('captureKind') != 'multi_target_neck_survey'
            or document.get('robotBaseStationary') is not True or document.get('registrationVerified') is not False):
        raise ValueError('Expected an unverified version-1 stationary multi-target survey manifest')
    if any(not isinstance(document.get(key), str) or not 1 <= len(document[key]) <= 128 for key in ('sessionID','sceneContextID')):
        raise ValueError('Survey needs sessionID and sceneContextID')
    entries = document.get('captures')
    if not isinstance(entries, list) or not 2 <= len(entries) <= 4:
        raise ValueError('Need two to four distinct target captures')
    seen_ids, seen_paths, loaded, protected = set(), set(), [], {path}
    for entry in entries:
        if not isinstance(entry, dict) or entry.get('targetID') not in JOINT.SUPPORTED_IDS or entry['targetID'] in seen_ids:
            raise ValueError('Target IDs must be supported and unique')
        if entry.get('status') not in ('complete', 'partial'):
            raise ValueError('Capture status must be complete or partial')
        source = entry.get('capturePath')
        chosen = entry.get('refinedCapturePath', source)
        if not isinstance(source, str) or not source or not isinstance(chosen, str) or not chosen:
            raise ValueError('Each capture needs a source path and optional refined path')
        source = Path(source)
        chosen = Path(chosen)
        source = (path.parent/source).resolve() if not source.is_absolute() else source.resolve()
        chosen = (path.parent/chosen).resolve() if not chosen.is_absolute() else chosen.resolve()
        if chosen in seen_paths:
            raise ValueError('The same capture path cannot supply two targets')
        original, original_hash = read_json(source)
        capture, capture_hash = read_json(chosen)
        if not isinstance(capture, dict) or not isinstance(original, dict):
            raise ValueError('Capture JSON must be an object')
        for record in (capture, original):
            if record.get('surveySessionID') != document['sessionID'] or record.get('sceneContextID') != document['sceneContextID']:
                raise ValueError('Capture belongs to another survey session or scene')
        if (capture.get('targetID') != entry['targetID'] or original.get('targetID') != entry['targetID']
                or capture.get('registrationVerified') is not False or original.get('registrationVerified') is not False):
            raise ValueError('Manifest/capture target or unverified registration state mismatch')
        if type(entry.get('samples')) is not int or entry['samples'] != len(original.get('views', [])):
            raise ValueError('Manifest sample count does not match the raw capture')
        refinement = capture.get('cornerRefinement')
        if chosen != source:
            if not isinstance(refinement, dict) or refinement.get('sourceCaptureSHA256') != original_hash:
                raise ValueError('Refined capture does not identify its original source hash')
        seen_ids.add(entry['targetID']); seen_paths.add(chosen); protected.update((source, chosen))
        loaded.append({'targetID': entry['targetID'], 'document': capture, 'sourcePath': str(source),
                       'inputPath': str(chosen), 'sourceSHA256': original_hash, 'inputSHA256': capture_hash,
                       'captureStatus': entry['status'], 'refinedInput': chosen != source,
                       'refinementAcceptedViews': refinement.get('acceptedViews') if isinstance(refinement, dict) else None,
                       'refinementRejectedRawRetainedViews': refinement.get('rejectedViews') if isinstance(refinement, dict) else None})
    return document, digest, loaded, protected


def prepare(captures, model):
    """Use the single worker's validation on globally pooled command poses."""
    pooled = {'schemaVersion': 1, 'targetID': 'ROB:TABLE:001', 'symbolSideMeters': .12,
              'modelID': model.model_id, 'views': []}
    marker_indices, marker_counts = [], []
    original_views = []
    for marker_index, item in enumerate(captures):
        document = item['document']
        if (type(document.get('schemaVersion')) is not int or document['schemaVersion'] != 1
                or document.get('symbolSideMeters') != .12 or document.get('modelID', model.model_id) != model.model_id):
            raise ValueError('Every capture must use the same measured target size and canonical URDF')
        views = document.get('views')
        if not isinstance(views, list) or not views or not all(isinstance(v, dict) for v in views):
            raise ValueError('Each target needs captured QR views')
        ids = set()
        marker_counts.append(len(views))
        for view in views:
            if not isinstance(view.get('id'), str) or not 1 <= len(view['id']) <= 120:
                raise ValueError('Each original view needs a bounded string ID')
            if view.get('targetID', item['targetID']) != item['targetID'] or view.get('id') in ids:
                raise ValueError('Duplicate view ID or mixed target within a capture')
            ids.add(view.get('id'))
            copy = dict(view)
            copy['id'] = f'm{marker_index}:'+str(view.get('id', ''))
            copy['targetID'] = 'ROB:TABLE:001'
            pooled['views'].append(copy)
            original_views.append(view)
            marker_indices.append(marker_index)
    if len(pooled['views']) > MAX_TOTAL_VIEWS:
        raise ValueError(f'Multi-target survey exceeds {MAX_TOTAL_VIEWS} total views')
    # JOINT.prepare rejects identical commands assigned to both splits globally.
    data = JOINT.prepare(pooled, model)
    data['originalViews'] = original_views
    data['markerIndices'] = np.array(marker_indices, dtype=int)
    data['captures'] = captures
    groups = [{} for _ in captures]
    for index, (view, marker) in enumerate(zip(original_views, marker_indices)):
        if view['training']:
            key = (round(view['neckPanDegrees'], 6), view['lowerTarget'], view['neckUpperTarget'])
            groups[marker].setdefault(key, []).append(index)
    counts = np.array([len(group) for group in groups])
    if np.min(counts) < 3:
        raise ValueError('Every target needs at least three distinct training poses')
    average = float(np.mean(counts))
    data['weights'] = np.zeros(len(original_views))
    for count, group in zip(counts, groups):
        for indices in group.values():
            data['weights'][indices] = math.sqrt(average/(count*len(indices)))
    data['perMarkerTrainingPoseCounts'] = counts.tolist()
    return data


def decode(parameters, model, marker_count):
    camera = QR.transform(model.nominal_camera[:3, :3] @ cv2.Rodrigues(parameters[3:6])[0], parameters[6:9])
    targets = [QR.transform(cv2.Rodrigues(parameters[9+6*i:12+6*i])[0], parameters[12+6*i:15+6*i])
               for i in range(marker_count)]
    return camera, targets


def project(parameters, model, data):
    camera, targets = decode(parameters, model, len(data['captures']))
    frames = model.frames(data['commands'], parameters[:3])
    base_camera = frames @ camera
    points_target = np.stack([(target[:3, :3] @ QR.object_corners().T).T+target[:3, 3] for target in targets])
    world_points = points_target[data['markerIndices']]
    points = np.einsum('nji,nkj->nki', base_camera[:, :3, :3], world_points-base_camera[:, None, :3, 3])
    depth = points[:, :, 2]
    pixels = points[:, :, :2]/np.maximum(depth[:, :, None], .03)
    for index, view in enumerate(data['views']):
        coefficients = view.get('distortionCoefficients')
        if coefficients:
            k1, k2, p1, p2 = coefficients[:4]; k3 = coefficients[4] if len(coefficients) == 5 else 0.
            x, y = pixels[index, :, 0].copy(), pixels[index, :, 1].copy(); radius = x*x+y*y
            radial = 1+k1*radius+k2*radius**2+k3*radius**3
            pixels[index, :, 0] = x*radial+2*p1*x*y+p2*(radius+2*x*x)
            pixels[index, :, 1] = y*radial+p1*(radius+2*y*y)+2*p2*x*y
        fx, fy, cx, cy = view['cameraMatrix']; pixels[index] = pixels[index]*[fx, fy]+[cx, cy]
    return pixels, depth, base_camera


def residual(parameters, model, data):
    pixels, depths, _ = project(parameters, model, data)
    selected = data['training']; weights = data['weights'][selected]
    observed = np.array([view['cornersPixels'] for view in data['views']])
    errors = (pixels[selected]-observed[selected])*weights[:, None, None]
    behind = np.minimum(depths[selected]-.05, 0)*1000*weights[:, None]
    return np.r_[errors.reshape(-1), behind.reshape(-1)]


def initial_parameters(gains, model, data):
    frames = model.frames(data['commands'], gains)
    camera_estimates = []
    for marker in range(len(data['captures'])):
        indices = np.where(data['training'] & (data['markerIndices'] == marker))[0]
        inputs = [{**data['poses'][i], 'baseToNeck': frames[i]} for i in indices]
        try:
            estimate, _, _ = QR.hand_eye(inputs)
            if np.linalg.norm(estimate[:3, 3]-model.nominal_camera[:3, 3]) <= .3:
                camera_estimates.append(estimate)
        except (ValueError, cv2.error, np.linalg.LinAlgError):
            pass
    camera = QR.mean_transform(camera_estimates) if camera_estimates else model.nominal_camera.copy()
    parameters = [*gains, *cv2.Rodrigues(model.nominal_camera[:3, :3].T @ camera[:3, :3])[0].reshape(3), *camera[:3, 3]]
    for marker in range(len(data['captures'])):
        indices = np.where(data['training'] & (data['markerIndices'] == marker))[0]
        target = QR.mean_transform([frames[i] @ camera @ data['poses'][i]['targetToCamera'] for i in indices])
        parameters.extend([*cv2.Rodrigues(target[:3, :3])[0].reshape(3), *target[:3, 3]])
    return np.array(parameters)


def surface_checks(targets, captures):
    lookup = {item['targetID']: target for item, target in zip(captures, targets)}
    result = {'status': 'diagnostic_only', 'constraintsAppliedToFit': False, 'baseZIsMeasuredGravity': False}
    normals = {identifier: target[:3, 2] for identifier, target in lookup.items()}
    result['targetNormalsBase'] = {identifier: value.tolist() for identifier, value in normals.items()}
    result['inclinationFromBaseHorizontalDegrees'] = {identifier: math.degrees(math.acos(float(np.clip(abs(value[2]), -1, 1)))) for identifier, value in normals.items()}
    left, right = 'ROB:FLOOR:L01', 'ROB:FLOOR:R01'
    if left in lookup and right in lookup:
        displacement = lookup[right][:3, 3]-lookup[left][:3, 3]
        a, b = normals[left], normals[right]
        result['floorLeftRight'] = {'normalAngleDegrees': math.degrees(math.acos(float(np.clip(abs(a @ b), -1, 1)))),
                                    'centerSeparationMeters': float(np.linalg.norm(displacement)),
                                    'leftPlaneToRightCenterMeters': float(abs(a @ displacement)),
                                    'rightPlaneToLeftCenterMeters': float(abs(b @ displacement))}
    wall = 'ROB:WALL:R01'
    if wall in lookup:
        result['wallToFloorAnglesDegrees'] = {identifier: math.degrees(math.acos(float(np.clip(abs(normals[wall] @ normals[identifier]), -1, 1))))
                                              for identifier in (left, right) if identifier in lookup}
    result['limitations'] = ['Floor flatness and wall verticality are not forced into this fit.',
                             'Coplanarity can diagnose consistency but cannot establish measured robot-to-world or camera-to-arm registration.',
                             'A printed marker pose samples its local supporting surface, not the entire room plane.']
    return result



def imu_validation(view, pose, source_folder=None):
    """Independent observations only; never contributes an optimizer residual."""
    imu = view.get('imu')
    if imu is None:
        return None
    result = {'status': 'unavailable', 'usedInOptimization': False}
    try:
        if not isinstance(imu, dict) or imu.get('stationary') is not True:
            raise ValueError('Stationary IMU window is unavailable')
        if imu.get('axes') != 'sensor_native' or imu.get('gravity_source') != 'stationary_accelerometer_mean':
            raise ValueError('IMU axes or gravity source is not the recorded stationary sensor mean')
        acceleration = QR.numeric_array(imu.get('gravity_mps2'), (3,), 'gravity_mps2')
        norm = float(np.linalg.norm(acceleration))
        if not 5 <= norm <= 15:
            raise ValueError('IMU acceleration norm is outside diagnostic bounds')
        rotation = QR.numeric_array(imu.get('imu_to_rgb_rotation'), (9,), 'imu_to_rgb_rotation').reshape(3,3)
        if not np.allclose(rotation.T@rotation,np.eye(3),atol=1e-5,rtol=0) or abs(np.linalg.det(rotation)-1)>1e-5:
            raise ValueError('Factory IMU-to-RGB rotation is not rigid')
        age = imu.get('age_milliseconds')
        if type(age) not in (int,float) or not math.isfinite(age) or not 0<=age<=1000:
            raise ValueError('IMU window is stale or has invalid age')
        count = imu.get('sample_count')
        if type(count) is not int or count<5:
            raise ValueError('IMU stationary mean has insufficient samples')
        unit = rotation @ acceleration/norm
        qr_normal = pose['targetToCamera'][:3,2]
        result.update(status='stationary_observation_unverified', sensor=imu.get('sensor'), sampleCount=count,
                      accelerationNormMetersPerSecondSquared=norm, windowAgeMilliseconds=age,
                      imuUnitDirectionOptical=unit.tolist(),
                      qrNormalVersusImuUnsignedDegrees=math.degrees(math.acos(float(np.clip(abs(qr_normal@unit),-1,1)))))
        if source_folder is not None:
            spec = importlib.util.spec_from_file_location('qr_multi_plane_probe',Path(__file__).with_name('qr_upper_neck_report.py'))
            plane_worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(plane_worker)
            try:
                plane = plane_worker.plane_for_view(view,source_folder)
                if plane is not None:
                    normal=np.array(plane['normalOptical'])
                    result['depthNormalVersusImuUnsignedDegrees']=math.degrees(math.acos(float(np.clip(abs(normal@unit),-1,1))))
                    result['depthPlaneRMSEMeters']=plane['orthogonalRMSEMeters']
                    result['depthPlaneInlierCount']=plane['inlierCount']
                else:
                    result['depthPlaneStatus']='unavailable'
            except (ValueError,KeyError,OSError,cv2.error,np.linalg.LinAlgError) as error:
                result['depthPlaneStatus']='unavailable: '+str(error)
    except (ValueError,TypeError,KeyError,np.linalg.LinAlgError) as error:
        result['reason']=str(error)
    return result


def summarize_imu(data, per_view):
    result={'status':'diagnostic_only','usedInOptimization':False,'availableViews':0,'markerComparisons':[],'relativeGravityChanges':[]}
    for marker,item in enumerate(data['captures']):
        indices=[i for i in range(len(per_view)) if data['markerIndices'][i]==marker
                 and per_view[i] is not None and per_view[i].get('status')=='stationary_observation_unverified']
        result['availableViews']+=len(indices)
        qr_angles=[per_view[i]['qrNormalVersusImuUnsignedDegrees'] for i in indices]
        depth_angles=[per_view[i]['depthNormalVersusImuUnsignedDegrees'] for i in indices if 'depthNormalVersusImuUnsignedDegrees' in per_view[i]]
        result['markerComparisons'].append({'targetID':item['targetID'],'sampleCount':len(indices),
                                           'medianQRNormalVersusImuUnsignedDegrees':float(np.median(qr_angles)) if qr_angles else None,
                                           'medianDepthNormalVersusImuUnsignedDegrees':float(np.median(depth_angles)) if depth_angles else None})
        holds={}
        for i in indices:
            view=data['originalViews'][i]
            step=view.get('stepIndex',view['id'].rsplit('-',1)[0])
            key=(round(view['neckPanDegrees'],6),view['lowerTarget'],view['neckUpperTarget'],step)
            holds.setdefault(key,[]).append(i)
        baselines={}
        for (pan,lower,upper,step), members in holds.items():
            gravity=np.mean([per_view[i]['imuUnitDirectionOptical'] for i in members],axis=0)
            gravity=gravity/np.linalg.norm(gravity)
            pose=QR.mean_transform([data['poses'][i]['targetToCamera'] for i in members])
            key=(pan,lower)
            if key not in baselines:
                baselines[key]=(upper,step,gravity,pose[:3,:3])
            base_upper,base_step,base_gravity,base_rotation=baselines[key]
            result['relativeGravityChanges'].append({'targetID':item['targetID'],'panDegrees':pan,'lowerTarget':lower,
                                                     'upperTarget':upper,'stepIndex':step,'referenceUpperTarget':base_upper,'referenceStepIndex':base_step,
                                                     'unsignedGravityDirectionChangeDegrees':math.degrees(math.acos(float(np.clip(gravity@base_gravity,-1,1)))),
                                                     'qrApparentRotationChangeDegrees':QR.rotation_degrees(pose[:3,:3]@base_rotation.T)})
    result['limitations']=['Factory IMU/RGB orientation, accelerometer bias and stationary-window timing are not independently commissioned.',
                           'Acceleration is normalized as observed; no assumed 9.81 rescaling or gravity constraint is applied.',
                           'Unsigned normal alignment is expected near zero for local horizontal surfaces and near ninety for vertical surfaces, if sensor frame/bias and placement are correct.',
                           'Gravity-direction change is an independent tilt observation; it can understate rotation about an axis near gravity and does not certify servo angle by itself.']
    return result


def fit(captures, model, maximum_iterations=100, maximum_seconds=120, starts=None):
    started = time.monotonic(); deadline = started+maximum_seconds
    data = prepare(captures, model); count = len(captures)
    nominal_t = model.nominal_camera[:3, 3]
    lower = np.r_[[.4]*3, [-math.pi/3]*3, nominal_t-.25, np.tile(np.r_[[-math.pi]*3, [-3., -3., -.5]], count)]
    upper = np.r_[[2.6]*3, [math.pi/3]*3, nominal_t+.25, np.tile(np.r_[[math.pi]*3, [3., 3., 3.]], count)]
    def function(parameters):
        if time.monotonic() >= deadline:
            raise ValueError('Multi-target optimization exceeded its wall-clock limit')
        return residual(parameters, model, data)
    solutions = []
    for seed in (starts or [[1., 1., 1.], [1.5, 1.5, 1.8], [1.8, 1., 1.8]]):
        initial = initial_parameters(np.asarray(seed), model, data)
        parameters, info = JOINT.optimize(initial, lower, upper, function, maximum_iterations)
        solutions.append((parameters, info))
    parameters, info = min(solutions, key=lambda pair: pair[1]['robustTrainingCost'])
    camera, targets = decode(parameters, model, count)
    predicted, depth, base_camera = project(parameters, model, data)
    if np.min(depth) <= .05:
        raise ValueError('Fitted marker corners are behind or too near a camera')
    values, jacobian = JOINT.jacobian(parameters, function)
    weights = np.minimum(1., 2./np.maximum(np.abs(values), 1e-12)); weighted = jacobian*np.sqrt(weights[:, None])
    _, singular, vt = np.linalg.svd(weighted, full_matrices=False)
    normalized = np.linalg.svd(weighted/np.maximum(np.linalg.norm(weighted, axis=0), 1e-12), compute_uv=False)
    rank = int(np.sum(singular > singular[0]*1e-8)); full_rank = rank == len(parameters)
    variance = float(np.sum(weights*values**2)/max(1, int(data['training'].sum())*8-len(parameters)))
    inverse_squared = np.where(singular > singular[0]*1e-8, 1/np.maximum(singular, 1e-30)**2, 0.)
    covariance = np.einsum('ki,k,kj->ij', vt, inverse_squared, vt)*variance
    names = JOINT.PARAMETER_NAMES[:9]+[f'{item["targetID"]}.{component}' for item in captures for component in ['rx','ry','rz','x','y','z']]
    result = {'schemaVersion': 1, 'status': 'multi_target_neck_fit_unverified', 'registrationVerified': False, 'candidateURDFReady': False,
              'modelID': model.model_id, 'poseSource': 'accepted_neck_commands', 'targetCount': count, 'sampleCount': len(data['views']),
              'scales': dict(zip(['pan','lower','upper'], map(float, parameters[:3]))),
              'pitchDegreesPerTarget': {'lower': float(.03*parameters[1]), 'upper': float(.03*parameters[2])},
              'upperNeckToOpticalCamera': camera.reshape(-1).tolist(),
              'gauge': {'fixedLowerZeroTarget': JOINT.ZERO_LOWER, 'fixedUpperZeroTarget': JOINT.ZERO_UPPER, 'fixedPanZeroDegrees': 0.,
                        'zerosAreMeasured': False, 'panZeroIsAssumedRatherThanExactGauge': True,
                        'exactConfounding': ['Upper zero versus camera extrinsic', 'Lower zero versus global marker/base reference']},
              'weighting': 'Each marker has equal total training weight; each unique commanded training pose within that marker has equal total weight; repeated frames divide that pose weight.',
              'robustLoss': 'Huber delta 2 in marker/pose-balanced coordinate residual units.',
              'optimization': info, 'multiStartTrainingCosts': [entry['robustTrainingCost'] for _, entry in solutions],
              'parameters': dict(zip(names, map(float, parameters))), 'parameterBounds': {name:[float(a),float(b)] for name,a,b in zip(names,lower,upper)},
              'identifiability': {'numericalRank': rank, 'parameterCount': len(parameters), 'conditionalCovarianceFullRank': full_rank,
                                  'jacobianSingularValues': singular.tolist(), 'columnNormalizedJacobianSingularValues': normalized.tolist(),
                                  'conditionNumber': float(singular[0]/max(singular[-1],1e-30)),
                                  'approximateOneSigma': dict(zip(names,map(float,np.sqrt(np.maximum(np.diag(covariance),0))))) if full_rank else None,
                                  'covarianceIsHardwareUncertainty': False,
                                  'note': 'Conditional local residual covariance assumes fixed intrinsics/URDF and independent residuals; correlated images and model bias are not physical confidence.'},
              'excitation': {'uniqueGlobalTrainingPoseCount': data['trainingPoseCount'], 'uniqueGlobalHeldOutPoseCount': data['heldOutPoseCount'],
                             'nominalCommandRangesDegrees': data['ranges'], 'centeredCommandSingularValuesRadians': data['excitation'],
                             'perMarkerTrainingPoseCounts': data['perMarkerTrainingPoseCounts']},
              'surfaceValidation': surface_checks(targets, captures), 'markers': [],
              'warnings': ['This is a fresh scene fit. No marker position from an older robot/base layout was reused.',
                           'A shared numerical model is not measured servo calibration or camera-to-arm registration.',
                           'Supplied intrinsics, rigid URDF axes/link lengths and stationary base/markers are assumptions.',
                           'All fitted values remain offline candidates; no zero, scale, world map or URDF change is applied.']}
    observed = np.array([view['cornersPixels'] for view in data['views']]); errors = np.sum((predicted-observed)**2,axis=2)
    imu_observations=[imu_validation(view,pose,Path(item['sourcePath']).parent if item.get('sourcePath') else None)
                      for view,pose,marker in zip(data['originalViews'],data['poses'],data['markerIndices'])
                      for item in [captures[marker]]]
    result['independentImuValidation']=summarize_imu(data,imu_observations)
    for marker, (item, target) in enumerate(zip(captures, targets)):
        indices = np.where(data['markerIndices']==marker)[0]
        entry = {key:value for key,value in item.items() if key!='document'}
        entry.update(baseToFixedTarget=target.reshape(-1).tolist(), sampleCount=len(indices), views=[])
        for index in indices:
            pose, original = data['poses'][index], data['originalViews'][index]
            marker_from_pnp = base_camera[index] @ pose['targetToCamera']; difference = JOINT.rigid_inverse(target) @ marker_from_pnp
            camera_center = base_camera[index,:3,:3].T @ (target[:3,3]-base_camera[index,:3,3]); supplied_depth = pose['centerDepthMeters']
            entry['views'].append({'id':original['id'],'training':original['training'],
                                   'neckPanDegrees':original['neckPanDegrees'],'lowerTarget':original['lowerTarget'],'upperTarget':original['neckUpperTarget'],
                                   'reprojectionRMSEPixels':float(np.sqrt(errors[index].mean())),
                                   'imuValidation':imu_observations[index],
                                   'pnpTargetTranslationDriftMeters':float(np.linalg.norm(difference[:3,3])),
                                   'pnpTargetRotationDriftDegrees':QR.rotation_degrees(difference[:3,:3]),
                                   'pnpPoseAmbiguous':pose['poseAmbiguous'], 'observedCenterDepthMeters':supplied_depth,
                                   'fittedCenterDepthResidualMeters':float(camera_center[2]-supplied_depth) if supplied_depth is not None else None})
        for label, flag in [('training',True),('heldOut',False)]:
            selected=[view for view in entry['views'] if view['training']==flag]
            entry[label+'SampleCount']=len(selected)
            entry[label+'ReprojectionRMSEPixels']=float(np.sqrt(np.mean([v['reprojectionRMSEPixels']**2 for v in selected]))) if selected else None
            entry[label+'PnPTranslationRMSEMeters']=float(np.sqrt(np.mean([v['pnpTargetTranslationDriftMeters']**2 for v in selected]))) if selected else None
            depths=[v['fittedCenterDepthResidualMeters'] for v in selected if v['fittedCenterDepthResidualMeters'] is not None]
            entry[label+'DepthCenterResidualRMSEMeters']=float(np.sqrt(np.mean(np.square(depths)))) if depths else None
        result['markers'].append(entry)
    for label, flag in [('training',True),('heldOut',False)]:
        selected=data['training']==flag
        result[label+'ReprojectionRMSEPixels']=float(np.sqrt(np.mean(errors[selected])))
    result['parametersAtBounds']=[names[i] for i in range(len(parameters)) if min(abs(parameters[i]-lower[i]),abs(upper[i]-parameters[i]))<1e-4]
    if result['parametersAtBounds']:
        result['warnings'].append('Some numerical parameters reached bounds; inspect mismatch before interpreting the result.')
    if not full_rank or normalized[-1] < 1e-4:
        result['warnings'].append('The conditional parameter Jacobian is rank-deficient or poorly conditioned.')
    result['elapsedSeconds']=time.monotonic()-started
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('manifest',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--model-dir',type=Path,default=Path(__file__).parent);parser.add_argument('--maximum-iterations',type=int,default=100)
    parser.add_argument('--maximum-seconds',type=float,default=120.)
    args=parser.parse_args();output=args.output.resolve();model_directory=args.model_dir.resolve()
    if args.output.suffix.lower()!='.json' or output==args.manifest.resolve() or output==model_directory or model_directory in output.parents:
        print('Output must be separate JSON outside the protected model directory.',file=sys.stderr);return 2
    validated_protected_paths = False
    try:
        if not 10<=args.maximum_iterations<=250 or not 10<=args.maximum_seconds<=600:
            raise ValueError('Invalid optimization iteration/time limit')
        document,digest,captures,protected=load_manifest(args.manifest)
        validated_protected_paths = True
        if output in protected:
            print('Output cannot overwrite a capture or manifest.',file=sys.stderr);return 2
        result=fit(captures,JOINT.NeckModel(args.model_dir),maximum_iterations=args.maximum_iterations,maximum_seconds=args.maximum_seconds)
        result['surveyProvenance']={'manifestSHA256':digest,'sessionID':document.get('sessionID'),'sceneContextID':document.get('sceneContextID'),
                                    'robotBaseStationaryReported':True,'basePoseIndependentlyMeasured':False,'manifestCaptureKind':document['captureKind']}
        code=0
    except (ValueError,TypeError,KeyError,OSError,JOINT.ET.ParseError,cv2.error,np.linalg.LinAlgError) as error:
        result={'schemaVersion':1,'status':'rejected','registrationVerified':False,'candidateURDFReady':False,'error':str(error)}
        print(str(error),file=sys.stderr);code=2
        if not validated_protected_paths and output.exists():
            return 2
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n');return code


if __name__=='__main__':
    raise SystemExit(main())
