"""Offline measured-order neck bundle; never commands hardware or installs a fit.

The torso is the coordinate gauge. Marker world coordinates are nuisance
variables, not assumed known. The virtual vertical pan frame is located at the
CAD lower-pitch pivot; its XYZ is an explicit 20mm mounting assumption.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import time

import cv2
import numpy as np
from scipy.optimize import least_squares

_SPEC = importlib.util.spec_from_file_location('constrained_multi', Path(__file__).with_name('qr_neck_multi_calibration.py'))
MULTI = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(MULTI)
JOINT, QR = MULTI.JOINT, MULTI.QR
CAD_PIVOT_TORSO = np.array([-.0207044288303, 0., .355408962871])
LINK_METERS = .15579
GLASS_RADIUS_INTERVAL = [.0685, .2615]
OPTICAL_CENTER_ALLOWANCE_METERS = .015


def unit(value):
    value = np.asarray(value, dtype=float)
    length = np.linalg.norm(value)
    if not np.isfinite(length) or length < 1e-10:
        raise ValueError('A finite nonzero direction is required')
    return value / length


def angular_degrees(a, b, unsigned=False):
    cosine = float(unit(a) @ unit(b))
    return math.degrees(math.acos(np.clip(abs(cosine) if unsigned else cosine, -1., 1.)))


class MeasuredOrderModel(JOINT.NeckModel):
    """Pan then parallel pitch axes; fixed torso frame, no body-pose fiction."""
    def __init__(self, directory):
        super().__init__(directory)
        self.lower_offset = 0.
        self.anchor = QR.transform(np.eye(3), CAD_PIVOT_TORSO)
        self.link = QR.transform(np.eye(3), [0, 0, LINK_METERS])

    def frames(self, commands, gains):
        c = np.asarray(commands, dtype=float)
        def rotate(axis, angles):
            out = np.broadcast_to(np.eye(4), (len(c), 4, 4)).copy()
            out[:, :3, :3] = JOINT.rotation(axis, angles)
            return out
        pan = np.radians(c[:, 0]) * gains[0]
        lower = (c[:, 1]-6011) * JOINT.NOMINAL_RADIANS_PER_TARGET * gains[1] + self.lower_offset
        upper = -(c[:, 2]-6906) * JOINT.NOMINAL_RADIANS_PER_TARGET * gains[2]
        return self.anchor @ rotate([0, 0, 1], pan) @ rotate([0, 1, 0], lower) @ self.link @ rotate([0, 1, 0], upper)


def camera_xyz(parameters):
    radius, azimuth, elevation = parameters[6:9]
    return radius*np.array([math.cos(elevation)*math.cos(azimuth),
                            math.cos(elevation)*math.sin(azimuth), math.sin(elevation)])


def camera_parameters(xyz):
    radius = float(np.linalg.norm(xyz))
    return [radius, math.atan2(xyz[1], xyz[0]), math.asin(float(xyz[2]/max(radius, 1e-12)))]


def decode(parameters, model, count):
    camera = QR.transform(model.nominal_camera[:3, :3] @ cv2.Rodrigues(parameters[3:6])[0], camera_xyz(parameters))
    targets = [QR.transform(cv2.Rodrigues(parameters[9+6*i:12+6*i])[0], parameters[12+6*i:15+6*i]) for i in range(count)]
    # Gravity is a fitted direction in torso coordinates, not assumed base Z.
    tilt_x, tilt_y = parameters[-5:-3]
    gravity = cv2.Rodrigues(np.array([tilt_x, tilt_y, 0.]))[0] @ np.array([0., 0., 1.])
    return camera, targets, gravity


def project(parameters, model, data, distortion):
    camera, targets, gravity = decode(parameters, model, len(data['captures']))
    model.lower_offset = float(parameters[-6])
    torso_camera = model.frames(data['commands'], parameters[:3]) @ camera
    world = np.stack([(t[:3, :3] @ QR.object_corners().T).T + t[:3, 3] for t in targets])[data['markerIndices']]
    optical = np.einsum('nji,nkj->nki', torso_camera[:, :3, :3], world-torso_camera[:, None, :3, 3])
    xy = optical[:, :, :2] / np.maximum(optical[:, :, 2:3], .03)
    if distortion is not None and (len(distortion)<=8 or not any(distortion[8:])):
        d=np.pad(np.asarray(distortion,dtype=float),(0,max(0,8-len(distortion))))
        x,y=xy[:,:,0],xy[:,:,1];r2=x*x+y*y
        k1,k2,p1,p2,k3,k4,k5,k6=d[:8]
        radial=(1+k1*r2+k2*r2**2+k3*r2**3)/(1+k4*r2+k5*r2**2+k6*r2**3)
        K=np.array([v['cameraMatrix'] for v in data['views']])
        pixels=np.empty_like(xy)
        pixels[:,:,0]=(x*radial+2*p1*x*y+p2*(r2+2*x*x))*K[:,None,0]+K[:,None,2]
        pixels[:,:,1]=(y*radial+p1*(r2+2*y*y)+2*p2*x*y)*K[:,None,1]+K[:,None,3]
        return pixels,optical[:,:,2],torso_camera,targets,gravity
    pixels = np.empty_like(xy)
    for i, view in enumerate(data['views']):
        d = distortion if distortion is not None else view.get('distortionCoefficients', [])
        if d:
            # Full OpenCV rational/thin-prism/tilt model; no silently dropped coefficients.
            K = np.array([[view['cameraMatrix'][0], 0, view['cameraMatrix'][2]], [0, view['cameraMatrix'][1], view['cameraMatrix'][3]], [0, 0, 1.]])
            pixels[i] = cv2.projectPoints(optical[i], np.zeros(3), np.zeros(3), K, np.array(d))[0].reshape(-1, 2)
        else:
            fx, fy, cx, cy = view['cameraMatrix']
            pixels[i] = xy[i] * [fx, fy] + [cx, cy]
    return pixels, optical[:, :, 2], torso_camera, targets, gravity


def imu_observations(data):
    groups = {}
    for i, view in enumerate(data['originalViews']):
        imu = view.get('imu') or {}
        try:
            if imu.get('stationary') is not True or imu.get('axes') != 'sensor_native' or imu.get('sample_count', 0) < 5:
                continue
            if not 0 <= float(imu['age_milliseconds']) <= 1000:
                continue
            R = np.array(imu['imu_to_rgb_rotation'], dtype=float).reshape(3, 3)
            if not np.allclose(R.T@R, np.eye(3), atol=1e-5) or abs(np.linalg.det(R)-1) > 1e-5:
                continue
            vector = R @ np.array(imu['gravity_mps2'])
            if not np.isfinite(vector).all() or not 5 <= np.linalg.norm(vector) <= 15:
                continue
            key = (*data['commands'][i], bool(data['training'][i]))
            groups.setdefault(key, []).append((i, vector))
        except (ValueError, KeyError, TypeError):
            continue
    # Overlapping 50-sample windows do not become independent observations.
    return [(members[0][0], np.median([v for _, v in members], axis=0)) for members in groups.values()]


def huber_coordinates(values, delta=2.):
    absolute = np.abs(values)
    return np.sign(values)*np.sqrt(np.where(absolute <= delta, values*values, 2*delta*absolute-delta*delta))


def physical_residual(targets, gravity, captures, imu, torso_camera, training, uncertainties, bias, camera_distance):
    lookup = {c['targetID']: t for c, t in zip(captures, targets)}
    terms = []
    floor_ids = [name for name in ('ROB:FLOOR:L01', 'ROB:FLOOR:R01') if name in lookup]
    angle_sigma = math.sin(math.radians(uncertainties['surfaceAngleDegrees']))
    for identifier in floor_ids + (['ROB:TABLE:001'] if 'ROB:TABLE:001' in lookup else []):
        terms.extend(np.cross(lookup[identifier][:3, 2], gravity) / angle_sigma)
    if len(floor_ids) == 2:
        terms.append(float(gravity @ (lookup[floor_ids[1]][:3, 3]-lookup[floor_ids[0]][:3, 3])) / uncertainties['floorHeightMeters'])
    imu_sigma = math.sin(math.radians(uncertainties['imuDirectionDegrees']))
    for index, observed in imu:
        if training[index]:
            expected = torso_camera[index, :3, :3].T @ gravity
            # Accelerometer sign is physical and retained; unlike plane normals, no abs/sign flip.
            terms.extend((expected-unit(observed-bias)) / imu_sigma)
    # Fixed optical-frame accelerometer bias, shared across all holds. This
    # weak explicit prior prevents a free bias from disguising bad geometry.
    terms.extend(bias / uncertainties['imuBiasMetersPerSecondSquared'])
    # The operator measured to lens glass from a servo center, whereas the
    # virtual axis origin's shaft coordinate is not surveyed. Treat the full
    # 3-D triangle as a conservative soft datum, never a perpendicular-radius
    # bound or a reason to reject an otherwise useful small-pivot solution.
    low=GLASS_RADIUS_INTERVAL[0]-OPTICAL_CENTER_ALLOWANCE_METERS
    high=GLASS_RADIUS_INTERVAL[1]+OPTICAL_CENTER_ALLOWANCE_METERS
    terms.append((max(low-camera_distance,0.)+max(camera_distance-high,0.))/uncertainties['upperCenterDatumMeters'])
    return np.asarray(terms)


def prepare(captures, model):
    accepted = []
    for capture in captures:
        item = dict(capture)
        document = dict(item['document'])
        views = document['views']
        if item.get('refinedInput'):
            views = [v for v in views if v.get('cornerRefinement', {}).get('status') == 'accepted_diagnostic']
        document['views'] = views
        item['document'] = document
        accepted.append(item)
    return MULTI.prepare(accepted, model)


def apply_fixed_distortion_to_pnp(data, distortion):
    validate_image_models(data,distortion)
    if distortion is not None:
        data['poses']=[QR.pose_for_view({**view,'distortionCoefficients':list(distortion)}) for view in data['views']]


def validate_image_models(data, distortion):
    """EEPROM coefficients never imply distortion of a delivered RGB image."""
    for view in data['originalViews']:
        coefficients=distortion if distortion is not None else view.get('distortionCoefficients',[])
        if coefficients is not None and any(abs(float(x))>1e-15 for x in coefficients):
            evidence=view.get('pixelModelProvenanceSHA256','')
            recorded=view.get('distortionCoefficients')
            if (view.get('rgbOutputUndistorted') is not False or view.get('pixelModel')!='native_distorted'
                    or not isinstance(evidence,str) or len(evidence)!=64
                    or any(c not in '0123456789abcdef' for c in evidence)
                    or recorded is None or not np.array_equal(np.array(recorded),np.array(coefficients))):
                raise ValueError('Nonzero distortion requires explicit per-image native-distorted output provenance and matching recorded coefficients; factory EEPROM D is not output-pixel D')
            source=view.get('sourceEvidence') or {}
            try:
                path=Path(source['capturePath'])/'capture-input.json'
                raw=path.read_bytes()
                if hashlib.sha256(raw).hexdigest()!=evidence or source.get('captureInputSHA256')!=evidence:
                    raise ValueError('Pixel-model source metadata hash changed')
                original=json.loads(raw)
                frames=[record for record in original['frames'] if record.get('sequence')==source['frameSequence']]
                if len(frames)!=1 or frames[0].get('rgbOutputUndistorted') is not False:
                    raise ValueError('Original source frame does not prove native-distorted RGB output')
                if not np.array_equal(np.array(frames[0].get('rgbOutputDistortionCoefficients')),np.array(coefficients)):
                    raise ValueError('Original output-pixel distortion differs from requested coefficients')
            except (KeyError,OSError,TypeError) as error:
                raise ValueError('Native-distorted output requires immutable original per-frame metadata, not a mutable fit option') from error
        if view.get('rgbOutputUndistorted') is True and coefficients is not None and any(abs(float(x))>1e-15 for x in coefficients):
            raise ValueError('Undistorted RGB output requires zero output distortion')


def fit(captures, directory, maximum_seconds=120., starts=3, distortion=None, seed_report=None, uncertainties=None):
    uncertainties = uncertainties or {'surfaceAngleDegrees': .5, 'floorHeightMeters': .003, 'imuDirectionDegrees': 2., 'imuBiasMetersPerSecondSquared': .25, 'upperCenterDatumMeters': .040, 'pixelCoordinates': 1.}
    for name, value in uncertainties.items():
        if not math.isfinite(value) or value <= 0:
            raise ValueError('Uncertainties must be finite and positive: '+name)
    if not 1 <= starts <= 8 or not 1 <= maximum_seconds <= 600:
        raise ValueError('Bounded fit requires 1..8 starts and 1..600 seconds')
    if distortion is not None and (len(distortion) not in (4, 5, 8, 12, 14) or not np.isfinite(distortion).all()):
        raise ValueError('Invalid fixed OpenCV distortion')
    model = MeasuredOrderModel(directory)
    data = prepare(captures, model)
    apply_fixed_distortion_to_pnp(data,distortion)
    count = len(data['captures'])
    names = JOINT.PARAMETER_NAMES[:6]+['cameraDistanceFromAssumedUpperCenterMeters', 'cameraAzimuthRadians', 'cameraElevationRadians']
    names += [c['targetID']+'.'+component for c in data['captures'] for component in ('rx','ry','rz','x','y','z')]
    names += ['lowerOffsetRadians', 'gravityRxRadians', 'gravityRyRadians', 'imuBiasOpticalX', 'imuBiasOpticalY', 'imuBiasOpticalZ']
    lo = np.r_[[.4]*3, [-math.pi]*3, [.001, -math.pi, -math.pi/2],
               np.tile(np.r_[[-math.pi]*3, [-3., -3., -1.]], count), [-math.pi/2, -math.pi/3, -math.pi/3], [-1.]*3]
    hi = np.r_[[2.6]*3, [math.pi]*3, [.5, math.pi, math.pi/2],
               np.tile(np.r_[[math.pi]*3, [3., 3., 3.]], count), [math.pi/2, math.pi/3, math.pi/3], [1.]*3]
    observed = np.array([v['cornersPixels'] for v in data['views']])
    imu = imu_observations(data)
    begin = time.monotonic()
    def residual(parameters):
        if time.monotonic()-begin > maximum_seconds:
            raise TimeoutError('Constrained bundle exceeded bounded fit time')
        pixels, depth, torso_camera, targets, gravity = project(parameters, model, data, distortion)
        selected = data['training']
        pixel = (pixels[selected]-observed[selected])*data['weights'][selected, None, None]/uncertainties['pixelCoordinates']
        physical = physical_residual(targets, gravity, data['captures'], imu, torso_camera, selected, uncertainties,parameters[-3:],parameters[6])
        behind = np.minimum(depth[selected]-.05, 0).reshape(-1)*1000
        return np.r_[huber_coordinates(pixel.reshape(-1)), physical, behind]
    solutions = []
    for start in range(starts):
        offset = math.radians([-20., 0., 20., -40., 40., -60., 60., 10.][start])
        model.lower_offset = offset
        initial = MULTI.initial_parameters(np.array([1.9, 1.8, 1.8]), model, data)
        initial[6:9] = camera_parameters(initial[6:9])
        initial = np.r_[initial, offset, .05, 0., 0., 0., 0.]
        if start == 0 and seed_report is not None:
            # Seed is only numerical initialization; target world poses belong to this session.
            old = seed_report.get('parameters', seed_report)
            for i, name in enumerate(names):
                if name in old and not name.startswith('ROB:'):
                    initial[i] = old[name]
            if all(key in old for key in ('cameraX','cameraY','cameraZ')):
                initial[6:9] = camera_parameters([old['cameraX'],old['cameraY'],old['cameraZ']])
        initial=np.clip(initial,lo+1e-8,hi-1e-8)
        model.lower_offset=float(initial[-6])
        camera,_,_=decode(initial,model,count)
        frames=model.frames(data['commands'],initial[:3])@camera
        for marker in range(count):
            ix=np.where(data['training'] & (data['markerIndices']==marker))[0]
            target=QR.mean_transform([frames[i]@data['poses'][i]['targetToCamera'] for i in ix])
            initial[9+6*marker:15+6*marker]=np.r_[cv2.Rodrigues(target[:3,:3])[0].reshape(3),target[:3,3]]
        result = least_squares(residual, np.clip(initial, lo+1e-8, hi-1e-8), bounds=(lo, hi),
                               x_scale='jac', max_nfev=180, loss='linear', ftol=1e-9, xtol=1e-9, gtol=1e-7)
        solutions.append(result)
        print(json.dumps({'start':start,'trainingCost':float(result.cost),'evaluations':result.nfev}), flush=True)
    best = min(solutions, key=lambda r:r.cost)
    p = best.x
    pixels, depth, cameras, targets, gravity = project(p, model, data, distortion)
    squared = np.sum((pixels-observed)**2, axis=2)
    metrics = {}
    for label, selected in [('training',data['training']),('heldOut',~data['training'])]:
        imu_errors = [angular_degrees(cameras[i,:3,:3].T @ gravity, value-p[-3:]) for i,value in imu if selected[i]]
        range_errors, pnp_drift = [], []
        for i in np.where(selected)[0]:
            marker = data['markerIndices'][i]
            optical_center = cameras[i,:3,:3].T @ (targets[marker][:3,3]-cameras[i,:3,3])
            supplied = data['poses'][i]['centerDepthMeters']
            if supplied is not None:
                range_errors.append(float(optical_center[2]-supplied))
            pnp_drift.append(float(np.linalg.norm((cameras[i] @ data['poses'][i]['targetToCamera'])[:3,3]-targets[marker][:3,3])))
        metrics[label] = {'cornerRMSEPixels':float(np.sqrt(squared[selected].mean())),
                          'imuDirectionRMSEDegrees':float(np.sqrt(np.mean(np.square(imu_errors)))) if imu_errors else None,
                          'centerDepthRMSEMeters':float(np.sqrt(np.mean(np.square(range_errors)))) if range_errors else None,
                          'pnpTargetTranslationRMSEMeters':float(np.sqrt(np.mean(np.square(pnp_drift)))),
                          'pnpTargetTranslationMaximumMeters':max(pnp_drift)}
    _, singular, vt = np.linalg.svd(best.jac, full_matrices=False)
    rank = int(np.sum(singular > singular[0]*1e-8))
    inverse = np.where(singular > singular[0]*1e-8, 1/np.maximum(singular,1e-30)**2, 0)
    covariance = np.einsum('ki,k,kj->ij', vt, inverse, vt)
    surface = MULTI.surface_checks(targets, data['captures'])
    surface.update(constraintsAppliedToFit=True, baseZIsMeasuredGravity=False,
                   fittedGravityDirectionTorso=gravity.tolist(), uncertainties=uncertainties)
    hold_groups = {}
    for i, view in enumerate(data['originalViews']):
        key = (int(data['markerIndices'][i]), view.get('stepIndex'), *data['commands'][i])
        hold_groups.setdefault(key, []).append(i)
    jitter = [float(np.sqrt(np.mean((observed[ix]-np.mean(observed[ix],axis=0))**2))) for ix in hold_groups.values() if len(ix)>1]
    camera, _, _ = decode(p,model,count)
    assumptions = {'frame':'torso_link', 'virtualPanPivotTorsoMeters':CAD_PIVOT_TORSO.tolist(),
                   'CADMountUncertaintyMeters':.020, 'panAxisVerticalInTorso':True,
                   'panToLowerLateralOffsetMetersAssumed':0., 'parallelPitchAxesAssumed':True,
                   'lowerToUpperLinkMeters':LINK_METERS, 'linkDirectionBeforeLowerOffset':'local +Z',
                   'upperZeroTargetCompositeGauge':6906, 'panZeroDegreesAssumed':0.,
                   'glassRadiusTriangleMeters':GLASS_RADIUS_INTERVAL,
                   'opticalCenterAndAxisReferenceAllowanceMeters':OPTICAL_CENTER_ALLOWANCE_METERS,
                   'upperServoCenterToVirtualAxisOriginSurveyed':False,
                   'distanceConstraint':'Soft full3D-distance triangle only; 40mm assumed axial-center datum uncertainty, not perpendicular radius',
                   'bodyLeanAndTorsoYawMeasured':False, 'globalMarkerXYZKnown':False}
    return {'schemaVersion':1,'status':'conditional_torso_bundle_candidate_not_registered',
            'registrationVerified':False,'candidateURDFReady':False,'calibrationApplied':False,
            'modelID':model.model_id,'mechanism':'pan→lower pitch→155.79mm link→upper pitch→camera',
            'assumptions':assumptions,'parameters':dict(zip(names,map(float,p))),
            'parameterBounds':{name:[float(a),float(b)] for name,a,b in zip(names,lo,hi)},
            'parametersAtBounds':[names[i] for i in range(len(p)) if min(p[i]-lo[i],hi[i]-p[i])<1e-5],
            'upperToOpticalCameraRowMajor':camera.reshape(-1).tolist(),
            'cameraPerpendicularUpperAxisRadiusMeters':float(np.linalg.norm(camera[[0,2],3])),
            'targetToTorsoRowMajor':{c['targetID']:t.reshape(-1).tolist() for c,t in zip(data['captures'],targets)},
            'cameraToTorsoByPose':[{'panDegrees':float(c[0]),'lowerTarget':int(c[1]),'upperTarget':int(c[2]),
                                   'training':bool(t),'matrixRowMajor':T.reshape(-1).tolist()} for c,t,T in zip(data['commands'],data['training'],cameras)],
            'quality':metrics,'surfaceValidation':surface,
            'sampleCount':len(data['views']),'uniqueTrainingPoses':data['trainingPoseCount'],
            'uniqueHeldOutPoses':data['heldOutPoseCount'],'imuUniqueCommandObservations':len(imu),
            'trainingCommandDomain':{'minimum':data['commands'][data['training']].min(axis=0).tolist(),
                                     'maximum':data['commands'][data['training']].max(axis=0).tolist(),
                                     'commands':np.unique(data['commands'][data['training']],axis=0).tolist()},
            'imuConstraintAvailable':bool(imu),'imuBiasOpticalMetersPerSecondSquared':p[-3:].tolist(),
            'pixelModel':{'nonzeroDistortionRequiresPerImageNativeOutputProof':True,
                          'fixedDistortionApplied':bool(distortion is not None and any(distortion)),
                          'legacyMissingOutputFlagIsNotImageModelVerification':True},
            'withinHoldCornerCoordinateRMSPixels':{'median':float(np.median(jitter)) if jitter else None,'maximum':max(jitter) if jitter else None},
            'optimization':{'trainingCost':float(best.cost),'success':bool(best.success),'starts':len(solutions),
                            'costs':[float(r.cost) for r in solutions],'elapsedSeconds':time.monotonic()-begin,
                            'selection':'Training objective only; heldout pixels/IMU/depth never enter fit'},
            'identifiability':{'rank':rank,'parameterCount':len(p),'singularValues':singular.tolist(),
                               'conditionNumber':float(singular[0]/max(singular[-1],1e-30)),
                               'conditionalCovariance':covariance.tolist(),
                               'conditionalOneSigma':dict(zip(names,map(float,np.sqrt(np.maximum(np.diag(covariance),0))))),
                               'covarianceIsHardwareUncertainty':False},
            'limitations':['Floor/table constraints and factory IMU orientation have explicit assumed uncertainties, not surveyed truth.',
                           'CAD mount allowance is not optimized away; camera-to-arm also depends on actual arm mapping and mount.',
                           'Glass-distance bounds include an explicit optical-center allowance and do not measure a signed camera vector.',
                           'No per-frame free camera pose absorbs jitter; overlapping IMU windows collapse by unique command.',
                           'No fitted depth correction is applied. Raw depth consistency is held separate from the RGB/IMU fit.',
                           'Conditional covariance excludes correlated images, CAD/mount bias, servo backlash and model inadequacy.',
                           'This offline candidate cannot install a registration, alter a URDF, approve or move an arm.']}


def predict_camera_to_torso(report, commands, directory):
    """Conditional parameter sensitivity, explicitly not physical confidence."""
    if report.get('status')!='conditional_torso_bundle_candidate_not_registered':
        raise ValueError('Expected an offline constrained torso candidate')
    model=MeasuredOrderModel(directory)
    if report['modelID']!=model.model_id:
        raise ValueError('Prediction model differs from fitted model')
    p=np.array(list(report['parameters'].values()))
    covariance=np.array(report['identifiability']['conditionalCovariance'])
    count=len(report['targetToTorsoRowMajor'])
    from scipy.spatial import ConvexHull
    domain=np.array(report['trainingCommandDomain']['commands'])
    center=domain.mean(axis=0);scale=np.maximum(np.ptp(domain,axis=0),1.)
    hull=ConvexHull((domain-center)/scale)
    def pose(parameters,command):
        camera,_,_=decode(parameters,model,count)
        model.lower_offset=float(parameters[-6])
        return model.frames([command],parameters[:3])[0]@camera
    results=[]
    for command in commands:
        command=np.asarray(command,dtype=float)
        if command.shape!=(3,) or not np.isfinite(command).all():
            raise ValueError('Prediction needs finite [panDegrees,lowerRaw,upperRaw]')
        nominal=pose(p,command);jac=np.zeros((6,len(p)))
        for i in range(len(p)):
            varied=p.copy();varied[i]+=1e-6
            moved=pose(varied,command)
            jac[:3,i]=(moved[:3,3]-nominal[:3,3])/1e-6
            delta=nominal[:3,:3].T@moved[:3,:3]
            jac[3:,i]=np.array([delta[2,1]-delta[1,2],delta[0,2]-delta[2,0],delta[1,0]-delta[0,1]])/(2e-6)
        propagated=jac@covariance@jac.T
        sigma=np.sqrt(np.maximum(np.diag(propagated),0))
        inside=bool(np.all(hull.equations[:,:3]@((command-center)/scale)+hull.equations[:,3]<=1e-8))
        results.append({'command':command.tolist(),'matrixRowMajor':nominal.reshape(-1).tolist(),
                        'insideTrainingCommandConvexHull':inside,
                        'conditionalOneSigmaPositionMeters':sigma[:3].tolist(),
                        'conditionalOneSigmaRotationDegrees':np.degrees(sigma[3:]).tolist(),
                        'heldOutMarkerDriftMaximumMeters':report['quality']['heldOut']['pnpTargetTranslationMaximumMeters'],
                        'CADMountAssumptionMeters':report['assumptions']['CADMountUncertaintyMeters'],
                        'physicalErrorBoundEstablished':False,
                        'limitation':'Parameter covariance assumes this mechanism/axes/camera model; CAD, depth bias and unmodeled backlash are not included. Outside convex hull is unvalidated extrapolation.'})
    return results


def validate_frozen_neck(captures, report, directory, distortion=None, maximum_seconds=60.):
    """New scene fits marker poses only; all neck/camera/bias values stay frozen."""
    model=MeasuredOrderModel(directory)
    if report['modelID']!=model.model_id:
        raise ValueError('Validation model differs from fitted model')
    data=prepare(captures,model);count=len(data['captures'])
    apply_fixed_distortion_to_pnp(data,distortion)
    prior=report['parameters'];head_names=list(prior)[:9]
    head=np.array([prior[name] for name in head_names])
    lower=prior['lowerOffsetRadians'];bias=np.array([prior['imuBiasOptical'+axis] for axis in 'XYZ'])
    gravity_parameters=np.array([prior['gravityRxRadians'],prior['gravityRyRadians']])
    model.lower_offset=lower
    stub=np.r_[head,np.zeros(6*count),lower,gravity_parameters,bias]
    camera,_,_=decode(stub,model,count)
    frames=model.frames(data['commands'],head[:3])@camera
    markers=[]
    for marker in range(count):
        ix=np.where(data['training'] & (data['markerIndices']==marker))[0]
        target=QR.mean_transform([frames[i]@data['poses'][i]['targetToCamera'] for i in ix])
        markers.extend([*cv2.Rodrigues(target[:3,:3])[0].reshape(3),*target[:3,3]])
    initial=np.r_[markers,gravity_parameters]
    imu=imu_observations(data);uncertainties=report['surfaceValidation']['uncertainties']
    observed=np.array([v['cornersPixels'] for v in data['views']]);selected=data['training']
    start=time.monotonic()
    def expand(value):return np.r_[head,value[:-2],lower,value[-2:],bias]
    def residual(value):
        if time.monotonic()-start>maximum_seconds:raise TimeoutError('Frozen-neck scene validation exceeded time limit')
        pixels,z,cameras,targets,gravity=project(expand(value),model,data,distortion)
        pixels=(pixels[selected]-observed[selected])*data['weights'][selected,None,None]/uncertainties['pixelCoordinates']
        physical=physical_residual(targets,gravity,data['captures'],imu,cameras,selected,uncertainties,bias,head[6])
        return np.r_[huber_coordinates(pixels.reshape(-1)),physical,np.minimum(z[selected]-.05,0).reshape(-1)*1000]
    result=least_squares(residual,initial,x_scale='jac',max_nfev=100,ftol=1e-9,xtol=1e-9,gtol=1e-7)
    pixels,z,cameras,targets,gravity=project(expand(result.x),model,data,distortion)
    sq=np.sum((pixels-observed)**2,axis=2)
    quality={}
    for label,flag in [('training',selected),('heldOut',~selected)]:
        depth=[];drift=[]
        for i in np.where(flag)[0]:
            target=targets[data['markerIndices'][i]]
            optical=cameras[i,:3,:3].T@(target[:3,3]-cameras[i,:3,3])
            supplied=data['poses'][i]['centerDepthMeters']
            if supplied is not None:depth.append(float(optical[2]-supplied))
            drift.append(float(np.linalg.norm((cameras[i]@data['poses'][i]['targetToCamera'])[:3,3]-target[:3,3])))
        quality[label]={'cornerRMSEPixels':float(np.sqrt(sq[flag].mean())),
                        'rawCenterDepthRMSEMeters':float(np.sqrt(np.mean(np.square(depth)))) if depth else None,
                        'markerTranslationRMSEMeters':float(np.sqrt(np.mean(np.square(drift))))}
    return {'status':'fresh_scene_frozen_neck_validation_only','registrationVerified':False,
            'neckAndCameraParametersOptimized':False,'markerPosesOptimizedOnTrainingOnly':True,
            'gravityRefittedForNewBodyPosture':True,'imuAvailable':bool(imu),
            'sampleCount':len(data['views']),'uniqueTrainingPoses':data['trainingPoseCount'],
            'uniqueHeldOutPoses':data['heldOutPoseCount'],'quality':quality,
            'targetToTorsoRowMajor':{c['targetID']:t.reshape(-1).tolist() for c,t in zip(data['captures'],targets)},
            'frozenNeckAndCameraParameters':{key:prior[key] for key in head_names+['lowerOffsetRadians']},
            'fittedGravityDirectionTorso':gravity.tolist(),
            'trainingCost':float(result.cost),'elapsedSeconds':time.monotonic()-start}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--model',type=Path,default=Path(__file__).parent)
    parser.add_argument('--distortion-file',type=Path)
    parser.add_argument('--seed-report',type=Path)
    parser.add_argument('--starts',type=int,default=3)
    parser.add_argument('--maximum-seconds',type=float,default=120.)
    parser.add_argument('--validate-manifest',type=Path)
    parser.add_argument('--predict-pose',action='append',default=[],help='panDegrees,lowerRaw,upperRaw')
    args = parser.parse_args()
    source_digests={name:hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                    for name in ['qr_neck_constrained_bundle.py','qr_neck_multi_calibration.py','qr_neck_joint_calibration.py','qr_neck_calibration.py','model.urdf','reference.json']}
    document,digest,captures,protected=MULTI.load_manifest(args.manifest)
    fresh_loaded=MULTI.load_manifest(args.validate_manifest) if args.validate_manifest else None
    if fresh_loaded:
        protected=protected|fresh_loaded[3]
    if args.output.resolve() in protected or args.model.resolve() in args.output.resolve().parents:
        raise ValueError('Output cannot overwrite capture evidence')
    distortion_document=json.loads(args.distortion_file.read_text()) if args.distortion_file else None
    distortion=distortion_document.get('rgbDistortionCoefficients') if distortion_document else None
    seed=json.loads(args.seed_report.read_text()) if args.seed_report else None
    report=fit(captures,args.model,args.maximum_seconds,args.starts,distortion,seed)
    report.update(sessionID=document['sessionID'],sceneContextID=document['sceneContextID'],manifestSHA256=digest,
                  sourceSHA256=source_digests['qr_neck_constrained_bundle.py'],
                  solverSourcesSHA256=source_digests,
                  inputs=[{k:v for k,v in item.items() if k!='document'} for item in captures])
    if args.distortion_file:
        report['fixedDistortionSource']={'path':str(args.distortion_file),'sha256':hashlib.sha256(args.distortion_file.read_bytes()).hexdigest()}
    if args.predict_pose:
        report['cameraToTorsoPredictions']=predict_camera_to_torso(report,[[float(v) for v in text.split(',')] for text in args.predict_pose],args.model)
    if fresh_loaded:
        fresh,fresh_digest,fresh_captures,_=fresh_loaded
        report['freshSceneValidation']=validate_frozen_neck(fresh_captures,report,args.model,distortion)
        report['freshSceneValidation'].update(sessionID=fresh['sessionID'],manifestSHA256=fresh_digest)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    print(json.dumps(report['quality']),flush=True)


if __name__=='__main__':
    main()
