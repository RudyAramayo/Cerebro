"""Offline bounded QR reprojection fit of ROB's URDF neck command scales.

No hardware, URDF writing or registration APIs. Upper/lower zeros are fixed
gauge conventions; pan zero is a fixed, unvalidated modeling assumption. None
establishes measured hardware zeros.
NumPy's bounded damped least squares is used without requiring SciPy.
"""

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

import cv2
import numpy as np

_SPEC = importlib.util.spec_from_file_location("qr_joint_pose_worker", Path(__file__).with_name("qr_neck_calibration.py"))
QR = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(QR)
ZERO_LOWER = 6011
ZERO_UPPER = 6906
NOMINAL_RADIANS_PER_TARGET = math.pi / 6000
PARAMETER_NAMES = ["panScale", "lowerScale", "upperScale", "cameraDeltaRx", "cameraDeltaRy", "cameraDeltaRz",
                   "cameraX", "cameraY", "cameraZ", "targetRx", "targetRy", "targetRz", "targetX", "targetY", "targetZ"]
SUPPORTED_IDS = {"ROB:TABLE:001", "ROB:FLOOR:L01", "ROB:FLOOR:R01", "ROB:WALL:R01"}


def rigid_inverse(value):
    result = np.eye(4)
    result[:3, :3] = value[:3, :3].T
    result[:3, 3] = -value[:3, :3].T @ value[:3, 3]
    return result


def rotation(axis, angles):
    axis = np.asarray(axis, dtype=np.float64)
    axis = axis / np.linalg.norm(axis)
    x, y, z = axis
    cross = np.array([[0., -z, y], [z, 0., -x], [-y, x, 0.]])
    angles = np.asarray(angles)
    return (np.eye(3) + np.sin(angles)[..., None, None]*cross
            + (1-np.cos(angles))[..., None, None]*(cross @ cross))


class NeckModel:
    def __init__(self, directory):
        directory = Path(directory)
        content = (directory/'model.urdf').read_bytes()
        self.model_id = hashlib.sha256(content).hexdigest()
        reference = json.loads((directory/'reference.json').read_text())
        if reference.get('modelID') != self.model_id or reference.get('simulationOnly') is not True:
            raise ValueError('URDF/reference identity mismatch')
        self.reference = reference['positions']
        self.joints = {}
        for element in ET.fromstring(content).findall('joint'):
            parent, child = element.find('parent'), element.find('child')
            origin, axis = element.find('origin'), element.find('axis')
            xyz = [float(v) for v in origin.get('xyz', '0 0 0').split()] if origin is not None else [0., 0., 0.]
            rpy = [float(v) for v in origin.get('rpy', '0 0 0').split()] if origin is not None else [0., 0., 0.]
            direction = [float(v) for v in axis.get('xyz', '0 0 1').split()] if axis is not None else [0., 0., 1.]
            if len(xyz) != 3 or len(rpy) != 3 or len(direction) != 3 or not np.isfinite(xyz+rpy+direction).all() or np.linalg.norm(direction) <= 0:
                raise ValueError('Invalid URDF origin or axis')
            origin_matrix = QR.transform(rotation([0, 0, 1], rpy[2]) @ rotation([0, 1, 0], rpy[1]) @ rotation([1, 0, 0], rpy[0]), xyz)
            if child.get('link') in self.joints:
                raise ValueError('URDF has duplicate child links')
            self.joints[child.get('link')] = {'name': element.get('name'), 'kind': element.get('type'),
                                            'parent': parent.get('link'), 'origin': origin_matrix, 'axis': direction}
        self.chain = self.path('upper_neck_link')
        if {j['name'] for j in self.chain if j['name'] in ('neck_pan', 'lower_neck', 'upper_neck')} != {'neck_pan', 'lower_neck', 'upper_neck'}:
            raise ValueError('Canonical neck chain is incomplete')
        camera_path = self.path('oak_optical_frame')
        upper_index = next((i for i, j in enumerate(camera_path) if j['name'] == 'upper_neck'), None)
        if upper_index is None:
            raise ValueError('Camera is not mounted to upper neck')
        self.nominal_camera = np.eye(4)
        for joint in camera_path[upper_index+1:]:
            if joint['kind'] != 'fixed':
                raise ValueError('Unexpected moving camera mount')
            self.nominal_camera = self.nominal_camera @ joint['origin']

    def path(self, link):
        result, seen = [], set()
        while link != 'base_link':
            if link in seen or link not in self.joints:
                raise ValueError('Missing or cyclic URDF chain')
            seen.add(link)
            joint = self.joints[link]
            result.append(joint)
            link = joint['parent']
        return list(reversed(result))

    def frames(self, commands, gains):
        commands = np.asarray(commands, dtype=np.float64)
        result = np.broadcast_to(np.eye(4), (len(commands), 4, 4)).copy()
        angles = {'neck_pan': np.radians(commands[:, 0])*gains[0],
                  'lower_neck': (commands[:, 1]-ZERO_LOWER)*NOMINAL_RADIANS_PER_TARGET*gains[1],
                  'upper_neck': -(commands[:, 2]-ZERO_UPPER)*NOMINAL_RADIANS_PER_TARGET*gains[2]}
        for joint in self.chain:
            result = result @ joint['origin']
            if joint['kind'] in ('revolute', 'continuous'):
                q = angles.get(joint['name'], np.full(len(commands), self.reference.get(joint['name'], 0.)))
                motion = np.broadcast_to(np.eye(4), (len(commands), 4, 4)).copy()
                motion[:, :3, :3] = rotation(joint['axis'], q)
                result = result @ motion
        return result


def prepare(document, model):
    if not isinstance(document, dict) or type(document.get('schemaVersion')) is not int or document['schemaVersion'] != 1:
        raise ValueError('Expected schemaVersion 1 object')
    if document.get('targetID') not in SUPPORTED_IDS or document.get('symbolSideMeters') != .12:
        raise ValueError('Expected a supported measured 120 mm ROB target')
    if document.get('modelID', model.model_id) != model.model_id:
        raise ValueError('Capture/URDF identity mismatch')
    views = document.get('views')
    if not isinstance(views, list) or not 12 <= len(views) <= 512 or not all(isinstance(v, dict) for v in views):
        raise ValueError('Expected 12 to 512 captured views')
    poses, commands, groups, split = [], [], {}, []
    ids = set()
    for view in views:
        if view.get('targetID', document['targetID']) != document['targetID']:
            raise ValueError('Mixed fixed marker identities')
        pose = QR.pose_for_view(view)
        if pose['id'] in ids:
            raise ValueError('Duplicate view id')
        ids.add(pose['id'])
        command = [view.get('neckPanDegrees'), view.get('lowerTarget'), view.get('neckUpperTarget')]
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in command) or not -90 <= command[0] <= 90 or not all(1 <= v <= 16383 for v in command[1:]):
            raise ValueError('Invalid recorded neck commands')
        if any(type(v) is not int for v in command[1:]):
            raise ValueError('Pitch targets must be integers')
        distortion = view.get('distortionCoefficients')
        if distortion is not None and len(distortion) not in (4, 5):
            raise ValueError('Joint fitter supports rectified input or 4/5 Brown distortion coefficients')
        key = (round(command[0], 6), int(command[1]), int(command[2]))
        if key in groups and groups[key] != view['training']:
            raise ValueError('The same commanded pose appears in both training and held-out data')
        groups[key] = view['training']
        poses.append(pose); commands.append(command); split.append(view['training'])
    unique_training = np.array([k for k, train in groups.items() if train], dtype=np.float64)
    unique_validation = [k for k, train in groups.items() if not train]
    if len(unique_training) < 10 or len(unique_validation) < 3:
        raise ValueError('Need at least ten distinct training poses and three held-out commanded poses')
    command_angles = unique_training.copy()
    command_angles[:, 0] = np.radians(command_angles[:, 0])
    command_angles[:, 1:] *= NOMINAL_RADIANS_PER_TARGET
    centered = command_angles-np.mean(command_angles, axis=0)
    excitation = np.linalg.svd(centered, compute_uv=False)
    ranges = np.ptp(command_angles, axis=0)
    if np.min(ranges) < math.radians(2.) or excitation[-1] < .003 or excitation[-1] < excitation[0]*.02:
        raise ValueError('Insufficient independent pan/lower/upper excitation; vary all three commands')
    command_array = np.array(commands)
    flags = np.array(split, dtype=bool)
    training_groups = {}
    for i, (command, train) in enumerate(zip(commands, split)):
        if train:
            key = tuple(command)
            training_groups.setdefault(key, []).append(i)
    weights = np.zeros(len(views))
    for indices in training_groups.values():
        weights[indices] = 1/math.sqrt(len(indices))
    return {'views': views, 'poses': poses, 'commands': command_array, 'training': flags,
            'weights': weights, 'excitation': excitation.tolist(), 'ranges': np.degrees(ranges).tolist(),
            'trainingPoseCount': len(unique_training), 'heldOutPoseCount': len(unique_validation)}


def decode(parameters, model):
    camera = QR.transform(model.nominal_camera[:3, :3] @ cv2.Rodrigues(parameters[3:6])[0], parameters[6:9])
    target = QR.transform(cv2.Rodrigues(parameters[9:12])[0], parameters[12:15])
    return camera, target


def projections(parameters, model, data):
    camera, target = decode(parameters, model)
    upper = model.frames(data['commands'], parameters[:3])
    base_camera = upper @ camera
    target_points = (target[:3, :3] @ QR.object_corners().T).T+target[:3, 3]
    points = np.einsum('nji,nkj->nki', base_camera[:, :3, :3], target_points[None, :, :]-base_camera[:, None, :3, 3])
    z = points[:, :, 2]
    xy = points[:, :, :2]/np.maximum(z[:, :, None], .03)
    for i, view in enumerate(data['views']):
        coefficients = view.get('distortionCoefficients')
        if coefficients:
            k1, k2, p1, p2 = coefficients[:4]
            k3 = coefficients[4] if len(coefficients) == 5 else 0.
            x, y = xy[i, :, 0].copy(), xy[i, :, 1].copy()
            radius = x*x+y*y
            radial = 1+k1*radius+k2*radius**2+k3*radius**3
            xy[i, :, 0] = x*radial+2*p1*x*y+p2*(radius+2*x*x)
            xy[i, :, 1] = y*radial+p1*(radius+2*y*y)+2*p2*x*y
        fx, fy, cx, cy = view['cameraMatrix']
        xy[i] = xy[i]*[fx, fy]+[cx, cy]
    return xy, z, base_camera


def residual(parameters, model, data):
    predicted, depth, _ = projections(parameters, model, data)
    observed = np.array([view['cornersPixels'] for view in data['views']])
    selected = data['training']
    weights = data['weights'][selected]
    pixels = (predicted[selected]-observed[selected])*weights[:, None, None]
    # Keep a behind-camera solution from becoming an attractive numerical fit.
    cheirality = np.minimum(depth[selected]-.05, 0)*1000*weights[:, None]
    return np.concatenate((pixels.reshape(-1), cheirality.reshape(-1)))


def robust_cost(values, delta=2.):
    absolute = np.abs(values)
    return float(np.sum(np.where(absolute <= delta, .5*values**2, delta*(absolute-.5*delta))))


def jacobian(parameters, function):
    output = function(parameters)
    columns = []
    for i in range(len(parameters)):
        step = 1e-5 if i < 3 else 1e-6
        plus, minus = parameters.copy(), parameters.copy()
        plus[i] += step; minus[i] -= step
        columns.append((function(plus)-function(minus))/(2*step))
    return output, np.column_stack(columns)


def optimize(initial, lower, upper, function, maximum_iterations=100):
    parameters = np.clip(initial, lower, upper)
    damping, accepted, converged = 1e-3, 0, False
    cost = robust_cost(function(parameters))
    trace = []
    for iteration in range(maximum_iterations):
        values, derivative = jacobian(parameters, function)
        weights = np.minimum(1., 2./np.maximum(np.abs(values), 1e-12))
        weighted = derivative*np.sqrt(weights[:, None])
        gradient = np.einsum('ij,i->j', derivative, weights*values)
        hessian = np.einsum('ni,nj->ij', weighted, weighted)
        scale = np.maximum(np.diag(hessian), 1e-8)
        if float(np.max(np.abs(gradient)/np.sqrt(scale))) < 1e-7:
            converged = True; break
        improved = False
        for _ in range(12):
            try:
                delta = np.linalg.solve(hessian+damping*np.diag(scale), -gradient)
            except np.linalg.LinAlgError:
                damping *= 10; continue
            candidate = np.clip(parameters+delta, lower, upper)
            next_cost = robust_cost(function(candidate))
            if next_cost < cost:
                movement = float(np.linalg.norm(candidate-parameters))
                improvement = cost-next_cost
                parameters, cost = candidate, next_cost
                damping = max(1e-10, damping/3)
                accepted += 1; improved = True
                if movement < 1e-8 or improvement < 1e-10*max(1., cost):
                    converged = True
                break
            damping *= 5
        if iteration % 10 == 0:
            trace.append({'iteration': iteration, 'robustCost': cost, 'damping': damping})
        if converged or not improved:
            break
    return parameters, {'iterations': iteration+1, 'acceptedSteps': accepted, 'convergedNumerically': converged,
                         'robustTrainingCost': cost, 'trace': trace}


def initial_parameters(gains, model, data):
    frames = model.frames(data['commands'], gains)
    training_indices = np.where(data['training'])[0]
    camera = model.nominal_camera.copy()
    inputs = [{**data['poses'][i], 'baseToNeck': frames[i]} for i in training_indices]
    try:
        estimate, _, _ = QR.hand_eye(inputs)
        if np.linalg.norm(estimate[:3, 3]-camera[:3, 3]) < .3:
            camera = estimate
    except (ValueError, cv2.error, np.linalg.LinAlgError):
        pass
    target = QR.mean_transform([frames[i] @ camera @ data['poses'][i]['targetToCamera'] for i in training_indices])
    return np.r_[gains, cv2.Rodrigues(model.nominal_camera[:3, :3].T @ camera[:3, :3])[0].reshape(3),
                 camera[:3, 3], cv2.Rodrigues(target[:3, :3])[0].reshape(3), target[:3, 3]]


def fit(document, model, starts=None, maximum_iterations=100):
    data = prepare(document, model)
    nominal_t = model.nominal_camera[:3, 3]
    lower = np.r_[[.4]*3, [-math.pi/3]*3, nominal_t-.25, [-math.pi]*3, [-2., -3., -.5]]
    upper = np.r_[[2.6]*3, [math.pi/3]*3, nominal_t+.25, [math.pi]*3, [3., 3., 3.]]
    starts = starts or [[1., 1., 1.], [1.5, 1.5, 1.8], [1.8, 1., 1.8]]
    function = lambda p: residual(p, model, data)
    candidates = []
    for seed in starts:
        initial = initial_parameters(np.asarray(seed, dtype=np.float64), model, data)
        candidate, diagnostic = optimize(initial, lower, upper, function, maximum_iterations)
        candidates.append((candidate, diagnostic))
    parameters, optimization = min(candidates, key=lambda pair: pair[1]['robustTrainingCost'])
    camera, target = decode(parameters, model)
    predicted, depths, base_camera = projections(parameters, model, data)
    if np.min(depths) <= .05:
        raise ValueError('Fitted target corners are behind or too near the camera')
    values, derivative = jacobian(parameters, function)
    weights = np.minimum(1., 2./np.maximum(np.abs(values), 1e-12))
    weighted = derivative*np.sqrt(weights[:, None])
    _, singular, right_singular = np.linalg.svd(weighted, full_matrices=False)
    column_norms = np.linalg.norm(weighted, axis=0)
    normalized_singular = np.linalg.svd(weighted/np.maximum(column_norms, 1e-12), compute_uv=False)
    threshold = singular[0]*1e-8
    rank = int(np.sum(singular > threshold))
    active_residual_count = int(np.sum(data['training']))*8
    degrees_of_freedom = max(1, active_residual_count-len(parameters))
    variance = float(np.sum(weights*values**2)/degrees_of_freedom)
    inverse_squared = np.where(singular > threshold, 1/np.maximum(singular, 1e-30)**2, 0.)
    covariance = np.einsum('ki,k,kj->ij', right_singular, inverse_squared, right_singular)*variance
    deviations = np.sqrt(np.maximum(np.diag(covariance), 0))
    boundary = [PARAMETER_NAMES[i] for i in range(len(parameters))
                if min(abs(parameters[i]-lower[i]), abs(upper[i]-parameters[i])) < 1e-4]
    result = {'schemaVersion': 1, 'status': 'joint_neck_fit_unverified', 'registrationVerified': False,
              'candidateURDFReady': False, 'targetID': document['targetID'], 'symbolSideMeters': .12,
              'modelID': model.model_id, 'poseSource': document.get('poseSource', 'accepted_neck_commands'),
              'gauge': {'fixedLowerZeroTarget': ZERO_LOWER, 'fixedUpperZeroTarget': ZERO_UPPER, 'fixedPanZeroDegrees': 0.,
                        'zerosAreMeasured': False, 'panZeroIsAssumedRatherThanExactGauge': True,
                        'exactGaugeConfounding': ['Upper zero can be absorbed by upper-neck-to-camera extrinsic.', 'Lower zero can be absorbed by a global rigid change of target/base reference.'],
                        'note': 'Upper/lower zero conventions are gauge-confounded. Pan zero is fixed as a model assumption and can become observable with varied lower pitch; it was not estimated or measured here.'},
              'scales': dict(zip(['pan', 'lower', 'upper'], map(float, parameters[:3]))),
              'pitchDegreesPerTarget': {'lower': float(parameters[1]*.03), 'upper': float(parameters[2]*.03)},
              'upperNeckToOpticalCamera': camera.reshape(-1).tolist(), 'baseToFixedTarget': target.reshape(-1).tolist(),
              'parameters': dict(zip(PARAMETER_NAMES, map(float, parameters))),
              'parameterBounds': {name: [float(low), float(high)] for name, low, high in zip(PARAMETER_NAMES, lower, upper)},
              'parameterization': 'Gains are dimensionless. Camera delta and target rotation are Rodrigues vectors in radians; camera delta post-multiplies nominal optical rotation. Translations are meters.',
              'robustLoss': 'Huber delta 2 in pose-balanced scaled coordinate residuals; every unique training command pose has equal total weight.',
              'optimization': optimization, 'multiStartTrainingCosts': [d['robustTrainingCost'] for _, d in candidates],
              'excitation': {'independentCommandAngleSingularValuesRadians': data['excitation'], 'commandRangesNominalDegrees': data['ranges'],
                             'uniqueTrainingPoseCount': data['trainingPoseCount'], 'uniqueHeldOutPoseCount': data['heldOutPoseCount']},
              'identifiability': {'jacobianSingularValues': singular.tolist(), 'columnNormalizedJacobianSingularValues': normalized_singular.tolist(),
                                  'numericalRank': rank, 'parameterCount': len(parameters), 'conditionNumber': float(singular[0]/max(singular[-1], 1e-30)),
                                  'parametersAtBounds': boundary, 'approximateCovariance': covariance.tolist(),
                                  'approximateOneSigma': dict(zip(PARAMETER_NAMES, map(float, deviations))) if rank == len(parameters) else None,
                                  'conditionalCovarianceFullRank': rank == len(parameters),
                                  'rankDeficientCovarianceIsPseudoinverseOnly': rank != len(parameters),
                                  'covarianceIsHardwareUncertainty': False, 'residualDegreesOfFreedom': degrees_of_freedom,
                                  'covarianceNote': 'Local linearized residual covariance under fixed model/intrinsics and independent scalar residual assumptions; correlated frames, pose groups, biases and model errors invalidate a physical-confidence interpretation.'},
              'views': [], 'warnings': ['No transform, scale, zero or URDF file is applied or changed.',
                                        'Accepted command poses are not shaft measurements; protractor and independent metric validation remain required.',
                                        'Fixed URDF joint axes/link lengths and supplied RGB intrinsics are assumed; optical framing errors can bias scales.',
                                        'Upper/lower zero offsets are gauge-confounded with mount/target reference; fixed pan zero is an additional unvalidated model assumption.',
                                        'Depth is diagnostic only and never forces an incompatible RGB fit.']}
    observed = np.array([v['cornersPixels'] for v in data['views']])
    per_corner = np.linalg.norm(predicted-observed, axis=2)
    for i, (view, pose) in enumerate(zip(data['views'], data['poses'])):
        pnp_base_target = base_camera[i] @ pose['targetToCamera']
        difference = rigid_inverse(target) @ pnp_base_target
        center_camera = base_camera[i, :3, :3].T @ (target[:3, 3]-base_camera[i, :3, 3])
        observed_depth = pose['centerDepthMeters']
        result['views'].append({'id': view['id'], 'training': view['training'], 'neckPanDegrees': view['neckPanDegrees'],
                                'lowerTarget': view['lowerTarget'], 'upperTarget': view['neckUpperTarget'],
                                'reprojectionRMSEPixels': float(np.sqrt(np.mean(per_corner[i]**2))),
                                'pnpTargetTranslationDriftMeters': float(np.linalg.norm(difference[:3, 3])),
                                'pnpTargetRotationDriftDegrees': QR.rotation_degrees(difference[:3, :3]),
                                'pnpPoseAmbiguous': pose['poseAmbiguous'], 'observedCenterDepthMeters': observed_depth,
                                'fittedCenterDepthMeters': float(center_camera[2]),
                                'fittedCenterDepthResidualMeters': float(center_camera[2]-observed_depth) if observed_depth is not None else None,
                                'pnpCenterDepthResidualMeters': pose['centerDepthResidualMeters']})
    for label, flag in [('training', True), ('heldOut', False)]:
        selected = [view for view in result['views'] if view['training'] == flag]
        result[label+'ReprojectionRMSEPixels'] = float(np.sqrt(np.mean([v['reprojectionRMSEPixels']**2 for v in selected])))
        result[label+'PnPTranslationRMSEMeters'] = float(np.sqrt(np.mean([v['pnpTargetTranslationDriftMeters']**2 for v in selected])))
        depth_errors = [v['fittedCenterDepthResidualMeters'] for v in selected if v['fittedCenterDepthResidualMeters'] is not None]
        result[label+'DepthCenterResidualRMSEMeters'] = float(np.sqrt(np.mean(np.square(depth_errors)))) if depth_errors else None
    if rank < len(parameters) or normalized_singular[-1] < 1e-4:
        result['warnings'].append('The local parameter Jacobian is rank-deficient or poorly conditioned; fitted parameter uniqueness is not established.')
    if boundary:
        result['warnings'].append('One or more fitted parameters reached configured bounds; inspect model mismatch before interpreting the candidate.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path); parser.add_argument('output', type=Path)
    parser.add_argument('--model-dir', type=Path, default=Path(__file__).parent)
    parser.add_argument('--maximum-iterations', type=int, default=100)
    args = parser.parse_args()
    output_path = args.output.resolve()
    model_directory = args.model_dir.resolve()
    if (args.output.suffix.lower() != '.json' or output_path == args.input.resolve()
            or output_path == model_directory or model_directory in output_path.parents):
        print('Output must be a separate JSON file outside the protected model directory.', file=sys.stderr)
        return 2
    try:
        if not 10 <= args.maximum_iterations <= 300:
            raise ValueError('Iteration limit must be from 10 to 300')
        raw = args.input.read_bytes()
        if len(raw) > 5_000_000:
            raise ValueError('Capture exceeds 5 MB')
        document = json.loads(raw, parse_constant=lambda v: (_ for _ in ()).throw(ValueError('Invalid JSON number '+v)))
        result = fit(document, NeckModel(args.model_dir), maximum_iterations=args.maximum_iterations)
        code = 0
    except (ValueError, TypeError, KeyError, OSError, ET.ParseError, cv2.error, np.linalg.LinAlgError) as error:
        result = {'schemaVersion': 1, 'status': 'rejected', 'registrationVerified': False, 'candidateURDFReady': False, 'error': str(error)}
        print(str(error), file=sys.stderr); code = 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False)+'\n')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
