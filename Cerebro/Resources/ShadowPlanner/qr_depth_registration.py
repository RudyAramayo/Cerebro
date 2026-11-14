"""Offline QR/RGB-to-native-depth calibration; no hardware or profile writes.

The metric reference is each printed QR's independently estimated optical
plane, not a fitted world floor. All valid interior returns, including outliers,
enter the reported error. Training is robust and observation-balanced; held-out
observations never select parameters or the optional ray-dependent model.

Input schemaVersion=1 has observations with id, markerID, poseID, split,
rangeGroup, width, height, cameraMatrix=[fx,fy,cx,cy], cornersPixels in printed
TL/TR/BR/BL order, markerSizeMeters, depthPath/depthSHA256 and
sourceImageSHA256. Distortion is explicit (coefficients, or
zeroDistortionAssumed=true). Paths resolve against the input document.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import cv2
import numpy as np

cv2.setNumThreads(1)


SCHEMA_VERSION = 1
MODELS = {"inverse_scale_bias": 2, "inverse_ray": 6}
DEFAULT_LIMITS = {"maximumHeldOutRMSEMeters": .010,
                  "maximumHeldOutAbsoluteErrorMeters": .030,
                  "minimumTrainingRangeSpanMeters": .20,
                  "minimumTrainingPoses": 2, "minimumHeldOutPoses": 2,
                  "minimumHeldOutMarkers": 1, "minimumHeldOutRanges": 1,
                  "maximumPnPRMSEPixels": .8,
                  "maximumHeldOutPlaneNormalErrorDegrees": 3.,
                  "minimumInverseScaleCoefficient": .5, "maximumInverseScaleCoefficient": 1.5,
                  "maximumAbsoluteInverseBiasPerMeter": .5,
                  "minimumCorrectedToRawRatio": .65,
                  "maximumCorrectedToRawRatio": 1.35}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _finite(value, shape, label):
    out = np.asarray(value, dtype=float)
    if out.shape != shape or not np.isfinite(out).all():
        raise ValueError(label+" must be finite with shape "+str(shape))
    return out


def _sha(value, label):
    if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError(label+" must be a lower-case SHA256")
    return value


def _mv(matrix,vector):
    # Explicit contraction avoids platform BLAS floating-status leakage on
    # these short, strided optical ray vectors.
    return np.einsum('ij,j->i',matrix,vector)


def _stats(errors):
    values = np.asarray(errors, dtype=float)
    if not len(values):
        return {"count": 0}
    absolute = np.abs(values)
    return {"count": int(len(values)), "rmseMeters": float(np.sqrt(np.mean(values**2))),
            "medianSignedMeters": float(np.median(values)),
            "medianAbsoluteMeters": float(np.median(absolute)),
            "p95AbsoluteMeters": float(np.percentile(absolute, 95)),
            "maximumAbsoluteMeters": float(np.max(absolute)),
            "outliersOver30mm": int(np.sum(absolute > .030))}


def object_corners(size):
    # IPPE_SQUARE mandates this order. Printed TL has +Y in marker coordinates.
    h = size/2
    return np.array([[-h,h,0.], [h,h,0.], [h,-h,0.], [-h,-h,0.]])


def estimate_plane(observation):
    width, height = observation['width'], observation['height']
    corners = _finite(observation['cornersPixels'], (4, 2), 'cornersPixels')
    if width < 16 or height < 16 or np.any(corners < 0) or np.any(corners[:,0] >= width) or np.any(corners[:,1] >= height):
        raise ValueError('QR corners lie outside the source image')
    edges = np.roll(corners, -1, axis=0)-corners
    cross = edges[:,0]*np.roll(edges[:,1],-1)-edges[:,1]*np.roll(edges[:,0],-1)
    if not np.all(cross > 1.) or min(np.linalg.norm(edges,axis=1)) < 12:
        raise ValueError('QR corners must be a nondegenerate clockwise printed quadrilateral')
    fx, fy, cx, cy = _finite(observation['cameraMatrix'], (4,), 'cameraMatrix')
    if min(fx,fy) <= 0:
        raise ValueError('Camera focal length must be positive')
    K = np.array([[fx,0,cx],[0,fy,cy],[0,0,1.]])
    distortion = observation.get('distortionCoefficients')
    if distortion is None:
        if observation.get('zeroDistortionAssumed') is not True:
            raise ValueError('Explicit distortion or zeroDistortionAssumed is required')
        distortion = []
    distortion = np.asarray(distortion,dtype=float)
    if len(distortion) not in (0,4,5,8,12,14) or not np.isfinite(distortion).all():
        raise ValueError('Invalid OpenCV optical distortion')
    size = float(observation['markerSizeMeters'])
    if not .03 <= size <= .5:
        raise ValueError('Printed black symbol size must be between 30 and 500 mm')
    obj = object_corners(size)
    solved = cv2.solvePnPGeneric(obj,corners,K,distortion,flags=cv2.SOLVEPNP_IPPE_SQUARE)
    branches = []
    for rv,tv in zip(solved[1],solved[2]):
        R = cv2.Rodrigues(rv)[0]
        points = obj@R.T+tv.reshape(1,3)
        if np.min(points[:,2]) <= .05:
            continue
        projected = cv2.projectPoints(obj,rv,tv,K,distortion)[0].reshape(4,2)
        error = float(np.sqrt(np.mean(np.sum((projected-corners)**2,axis=1))))
        branches.append((error,R,tv.reshape(3)))
    if not branches:
        raise ValueError('QR has no positive-depth metric PnP branch')
    branches.sort(key=lambda x:x[0])
    error,R,t = branches[0]
    # This is an independent plane per frame. Do not force table/floor normals.
    n = R[:,2]
    branch_planes = [{"cornerRMSEPixels": e, "normalOptical": r[:,2].tolist(),
                      "centerOpticalMeters": p.tolist()} for e,r,p in branches]
    return K,distortion,corners,n,float(n@t),{
        "cornerRMSEPixels": error,"normalOptical": n.tolist(),
        "centerOpticalMeters": t.tolist(), "branches": branch_planes,
        "branchRMSEMarginPixels": float(branches[1][0]-error) if len(branches)>1 else None,
        "metricScaleConditionalOnPrintedSymbolSize": True}


def sample_observation(observation, base_directory, inset_fraction=.15, sample_step=1):
    K,distortion,corners,n,d,pnp = estimate_plane(observation)
    path = Path(observation['depthPath'])
    if not path.is_absolute():
        path = Path(base_directory)/path
    expected = _sha(observation['depthSHA256'],'depthSHA256')
    if digest(path) != expected:
        raise ValueError('Native depth hash does not match immutable source')
    _sha(observation['sourceImageSHA256'],'sourceImageSHA256')
    image_path=observation.get('sourceImagePath')
    image_verified=False
    if image_path:
        image_path=Path(image_path)
        if not image_path.is_absolute():image_path=Path(base_directory)/image_path
        if digest(image_path)!=observation['sourceImageSHA256']:
            raise ValueError('RGB source hash does not match immutable source')
        image_verified=True
    width,height = observation['width'],observation['height']
    raw = np.fromfile(path,dtype='<u2')
    if len(raw) != width*height:
        raise ValueError('Native depth dimensions/UInt16 encoding do not match')
    raw = raw.reshape(height,width)
    # Erode in printed coordinates, preserving a projective interior margin.
    unit = np.array([[0,0],[1,0],[1,1],[0,1]],dtype=np.float32)
    H = cv2.getPerspectiveTransform(unit,corners.astype(np.float32))
    a,b=inset_fraction,1-inset_fraction
    polygon = cv2.perspectiveTransform(np.array([[[a,a],[b,a],[b,b],[a,b]]]),H)[0]
    mask = np.zeros((height,width),dtype=np.uint8)
    cv2.fillConvexPoly(mask,np.round(polygon).astype(np.int32),1)
    yy,xx=np.mgrid[0:height:sample_step,0:width:sample_step]
    interior=mask[yy,xx]!=0
    uv=np.column_stack((xx[interior],yy[interior])).astype(float)
    z=raw[uv[:,1].astype(int),uv[:,0].astype(int)].astype(float)*.001
    valid=z>0
    valid_count=int(np.sum(valid))
    uv,z=uv[valid],z[valid]
    if len(z)<20:
        raise ValueError('Fewer than 20 valid native returns inside the QR interior')
    xy=cv2.undistortPoints(uv.reshape(-1,1,2),K,distortion).reshape(-1,2)
    rays=np.column_stack((xy,np.ones(len(xy))))
    denominators=_mv(rays,n)
    true_z=d/denominators
    if not np.isfinite(true_z).all() or np.any(true_z <= .05):
        raise ValueError('QR optical plane does not intersect all interior forward rays')
    # The alternative planar-PnP solution is evaluated, never silently averaged.
    alternative_disagreements=[]
    for branch in pnp['branches'][1:]:
        bn=np.array(branch['normalOptical']);bt=np.array(branch['centerOpticalMeters'])
        bz=float(np.dot(bn,bt))/_mv(rays,bn)
        alternative_disagreements.append(float(np.max(np.abs(bz-true_z))))
    return {"metadata": dict(observation), "pnp":pnp,"uv":uv,"xy":xy,
            "raw":z,"true":true_z,"normal":n,"planeOffset":d,
            "rays":rays,"interiorPixelCount":int(np.sum(interior)),
            "interiorPolygonPixels":polygon,
            "validDepthCount":valid_count,
            "sourceImageHashVerified":image_verified,
            "alternativePlaneMaximumDepthDisagreementMeters":max(alternative_disagreements,default=0.)}


def design(sample, model):
    inv=1/sample['raw'];x,y=sample['xy'].T
    if model=='inverse_scale_bias':
        return np.column_stack((inv,np.ones(len(inv))))
    if model=='inverse_ray':
        return np.column_stack((inv,x*inv,y*inv,np.ones(len(inv)),x,y))
    raise ValueError('Unknown depth correction model')


def corrected_depth(sample, model, parameters):
    denominator=_mv(design(sample,model),parameters)
    if np.any(denominator <= 0) or not np.isfinite(denominator).all():
        raise ValueError('Depth correction maps a measured return behind the camera')
    return 1/denominator


def _fit(samples,model):
    X=np.concatenate([design(s,model) for s in samples])
    y=np.concatenate([1/s['true'] for s in samples])
    # No frame's dense pixels outweigh an independent held view.
    pose_counts={s['metadata']['poseID']:sum(t['metadata']['poseID']==s['metadata']['poseID'] for t in samples) for s in samples}
    weights=np.concatenate([np.full(len(s['raw']),1/math.sqrt(len(s['raw'])*pose_counts[s['metadata']['poseID']])) for s in samples])
    p=np.linalg.lstsq(X*weights[:,None],y*weights,rcond=None)[0]
    for _ in range(20):
        residual=_mv(X,p)-y
        # Robustness is for optimization only. Reporting retains every return.
        sigma=max(.001,1.4826*float(np.median(np.abs(residual-np.median(residual)))))
        robust=np.minimum(1.,1.5*sigma/np.maximum(np.abs(residual),1e-12))
        w=weights*np.sqrt(robust)
        new=np.linalg.lstsq(X*w[:,None],y*w,rcond=None)[0]
        if np.linalg.norm(new-p)<1e-10:
            p=new;break
        p=new
    norms=np.linalg.norm(X*weights[:,None],axis=0)
    normalized=X*weights[:,None]/np.maximum(norms,1e-12)
    singular=np.linalg.svd(normalized,compute_uv=False)
    rank=int(np.sum(singular>singular[0]*1e-6))
    return p,{"rank":rank,"parameterCount":MODELS[model],
              "normalizedDesignCondition":float(singular[0]/max(singular[-1],1e-15)),
              "smallestNormalizedSingularValue":float(singular[-1])}


def evaluate(samples,model,parameters):
    observations=[];all_plane=[];all_z=[]
    for s in samples:
        z=corrected_depth(s,model,parameters)
        plane=_mv(s['rays']*z[:,None],s['normal'])-s['planeOffset']
        z_error=z-s['true']
        raw_plane=_mv(s['rays']*s['raw'][:,None],s['normal'])-s['planeOffset']
        all_plane.extend(plane);all_z.extend(z_error)
        # A fitted raw point plane diagnoses tilt independently of plane bias.
        xyz=s['rays']*z[:,None]
        _,_,V=np.linalg.svd(xyz-np.median(xyz,axis=0),full_matrices=False)
        angle=math.degrees(math.acos(np.clip(abs(V[-1]@s['normal']),-1,1)))
        raw_xyz=s['rays']*s['raw'][:,None]
        _,_,raw_V=np.linalg.svd(raw_xyz-np.median(raw_xyz,axis=0),full_matrices=False)
        raw_angle=math.degrees(math.acos(np.clip(abs(raw_V[-1]@s['normal']),-1,1)))
        observations.append({"id":s['metadata']['id'],"markerID":s['metadata']['markerID'],
            "poseID":s['metadata']['poseID'],"rangeGroup":s['metadata']['rangeGroup'],
            "split":s['metadata']['split'],"medianRawDepthMeters":float(np.median(s['raw'])),
            "medianPnPDepthMeters":float(np.median(s['true'])),
            "rawPlaneError":_stats(raw_plane),"correctedPlaneError":_stats(plane),
            "correctedOpticalZError":_stats(z_error),"correctedPlaneNormalErrorDegrees":angle,
            "rawPlaneNormalErrorDegrees":raw_angle,
            "pnp":s['pnp'],"interiorPixelCount":s['interiorPixelCount'],
            "validDepthCount":s['validDepthCount'],
            "alternativePlaneMaximumDepthDisagreementMeters":s['alternativePlaneMaximumDepthDisagreementMeters']})
    return {"planeError":_stats(all_plane),"opticalZError":_stats(all_z),"observations":observations}


def domain_for(samples):
    uv=np.concatenate([s['uv'] for s in samples]);xy=np.concatenate([s['xy'] for s in samples]);z=np.concatenate([s['raw'] for s in samples])
    return {"uvMinimum":np.min(uv,axis=0).tolist(),"uvMaximum":np.max(uv,axis=0).tolist(),
            "normalizedRayMinimum":np.min(xy,axis=0).tolist(),"normalizedRayMaximum":np.max(xy,axis=0).tolist(),
            "rawDepthMinimumMeters":float(np.min(z)),"rawDepthMaximumMeters":float(np.max(z)),
            "domainIsObservedPatchUnion":True,
            "boundingExtentsAreNotAnAdmittedBox":True,
            "patches":[{"id":s['metadata']['id'],"uvMinimum":np.min(s['uv'],axis=0).tolist(),
                        "uvMaximum":np.max(s['uv'],axis=0).tolist(),
                        "interiorPolygonPixels":s['interiorPolygonPixels'].tolist(),
                        "rawDepthMinimumMeters":float(np.min(s['raw'])),
                        "rawDepthMaximumMeters":float(np.max(s['raw']))} for s in samples]}


def physical_check(model,p,domain,limits):
    corners=np.array([[x,y] for x in (domain['normalizedRayMinimum'][0],domain['normalizedRayMaximum'][0])
                      for y in (domain['normalizedRayMinimum'][1],domain['normalizedRayMaximum'][1])])
    if model=='inverse_scale_bias':
        scales=np.full(4,p[0]);biases=np.full(4,p[1])
    else:
        scales=p[0]+_mv(corners,p[1:3]);biases=p[3]+_mv(corners,p[4:6])
    ratios=[]
    for z in (domain['rawDepthMinimumMeters'],domain['rawDepthMaximumMeters']):
        denominator=scales+biases*z
        ratios.extend((1/denominator).tolist() if np.all(denominator>0) else [1e30])
    checks={"positiveMonotonicDerivative":bool(np.min(scales)>0),
            "boundedInverseScaleCoefficient":bool(np.min(scales)>=limits['minimumInverseScaleCoefficient'] and np.max(scales)<=limits['maximumInverseScaleCoefficient']),
            "boundedInverseBias":bool(np.max(np.abs(biases))<=limits['maximumAbsoluteInverseBiasPerMeter']),
            "boundedCorrectionRatio":bool(min(ratios)>=limits['minimumCorrectedToRawRatio'] and max(ratios)<=limits['maximumCorrectedToRawRatio'])}
    return {"passed":all(checks.values()),"checks":checks,"inverseScaleCoefficientRange":[float(min(scales)),float(max(scales))],
            "inverseBiasRangePerMeter":[float(min(biases)),float(max(biases))],
            "correctedToRawRatioRange":[float(min(ratios)),float(max(ratios))]}


def alignment_diagnostic(samples):
    """Image translations are diagnostics, never selected as calibration.

    At a single flat patch, range bias and pixel shift are confounded. Testing
    fixed +/-2,4px on all rays makes that limitation visible without using the
    heldout residual to move the depth image or change correspondences.
    """
    result=[]
    for dx,dy in ((0,0),(-4,0),(-2,0),(2,0),(4,0),(0,-4),(0,-2),(0,2),(0,4)):
        errors=[]
        for s in samples:
            fx,fy,cx,cy=s['metadata']['cameraMatrix']
            if s['metadata'].get('distortionCoefficients'):
                K=np.array([[fx,0,cx],[0,fy,cy],[0,0,1.]])
                xy=cv2.undistortPoints((s['uv']+[dx,dy]).reshape(-1,1,2),K,np.array(s['metadata']['distortionCoefficients'])).reshape(-1,2)
            else:
                xy=s['xy']+np.array([dx/fx,dy/fy])
            rays=np.column_stack((xy,np.ones(len(xy))))
            errors.extend(_mv(rays*s['raw'][:,None],s['normal'])-s['planeOffset'])
        result.append({"assumedDepthPixelOffset":[dx,dy],"rawPlaneError":_stats(errors)})
    return {"applied":False,"flatPatchCannotIndependentlyIdentifyPixelAlignment":True,
            "fixedOffsetSensitivity":result}


def pose_jackknife(samples,model,parameters,prediction_samples):
    """Empirical repeat-fit sensitivity, explicitly not metrology covariance."""
    poses=sorted({s['metadata']['poseID'] for s in samples})
    records=[]
    for pose in poses:
        remaining=[s for s in samples if s['metadata']['poseID']!=pose]
        try:
            fitted,information=_fit(remaining,model)
            differences=np.concatenate([corrected_depth(s,model,fitted)-corrected_depth(s,model,parameters) for s in prediction_samples])
            records.append({"omittedPoseID":pose,"parameters":fitted.tolist(),"rank":information['rank'],
                            "predictionChange":_stats(differences)})
        except ValueError as exc:records.append({"omittedPoseID":pose,"reason":str(exc)})
    return {"records":records,"isHardwareOrPrintedScaleUncertainty":False,
            "predictionDomain":"observed QR patch union only; no extrapolation assurance",
            "maximumPredictionChangeMeters":max((r['predictionChange']['maximumAbsoluteMeters'] for r in records if 'predictionChange'in r),default=None)}


def group_cross_validation(samples,model,field):
    """Withhold each entire TRAIN marker/range; finalheldposes remain untouched."""
    groups=sorted({s['metadata'][field] for s in samples})
    records=[]
    if len(groups)<2:
        return {"grouping":field,"available":False,"reason":"Only one training group; no independent group prediction is possible","folds":[]}
    for group in groups:
        train=[s for s in samples if s['metadata'][field]!=group]
        validation=[s for s in samples if s['metadata'][field]==group]
        try:
            p,information=_fit(train,model)
            result=evaluate(validation,model,p)
            training_depths=[float(np.median(s['true'])) for s in train]
            validation_depths=[float(np.median(s['true'])) for s in validation]
            bias=float(np.median([np.median(1/s['true']-1/s['raw']) for s in train]))
            records.append({"withheldGroup":group,"trainingPoseCount":len({s['metadata']['poseID'] for s in train}),
                "parameters":p.tolist(),"identifiability":information,"opticalZError":result['opticalZError'],
                "planeError":result['planeError'],"observations":result['observations'],
                "fixedScaleBiasOnlyOpticalZError":evaluate(validation,'inverse_scale_bias',np.array([1.,bias]))['opticalZError'],
                "extrapolatesTrainingCenterDepthRange":min(validation_depths)<min(training_depths) or max(validation_depths)>max(training_depths)})
        except (ValueError,np.linalg.LinAlgError) as exc:
            records.append({"withheldGroup":group,"reason":str(exc)})
    return {"grouping":field,"available":True,"usesFinalHeldOutPoses":False,"folds":records}


def _group_prediction_passed(audit,model,limits):
    return audit['available'] and all(
        'opticalZError' in f and f['identifiability']['rank']==MODELS[model]
        and f['identifiability']['normalizedDesignCondition']<1000
        and f['trainingPoseCount']>=limits['minimumTrainingPoses']
        and f['opticalZError']['rmseMeters']<=limits['maximumHeldOutRMSEMeters']
        and f['opticalZError']['maximumAbsoluteMeters']<=limits['maximumHeldOutAbsoluteErrorMeters']
        and all(o['correctedPlaneNormalErrorDegrees']<=limits['maximumHeldOutPlaneNormalErrorDegrees'] for o in f['observations'])
        for f in audit['folds'])


def local_heldout_domains(samples,model,parameters,limits):
    """Expose useful local evidence without promoting the global correction."""
    records=[]
    for marker in sorted({s['metadata']['markerID'] for s in samples}):
        local=[s for s in samples if s['metadata']['markerID']==marker]
        result=evaluate(local,model,parameters)
        poses=sorted({s['metadata']['poseID'] for s in local})
        domain=domain_for(local)
        keys=[tuple(s['metadata'].get('scope',{}).get(k) for k in ('cameraGeneration','intrinsicsIdentity','gatewaySessionGeneration')) for s in local]
        checks={"independentHeldOutPoseCount":len(poses)>=limits['minimumHeldOutPoses'],
                "physicalMonotonicBounds":physical_check(model,parameters,domain,limits)['passed'],
                "rgbSourceHashesVerified":all(s['sourceImageHashVerified'] for s in local),
                "singleCameraGeometryScope":all(all(v is not None for v in key) for key in keys) and len(set(keys))==1,
                "pnpCornerFit":all(s['pnp']['cornerRMSEPixels']<=limits['maximumPnPRMSEPixels'] for s in local),
                "opticalZRMSE":result['opticalZError']['rmseMeters']<=limits['maximumHeldOutRMSEMeters'],
                "opticalZMaximum":result['opticalZError']['maximumAbsoluteMeters']<=limits['maximumHeldOutAbsoluteErrorMeters'],
                "planeNormal":all(o['correctedPlaneNormalErrorDegrees']<=limits['maximumHeldOutPlaneNormalErrorDegrees'] for o in result['observations'])}
        records.append({"markerID":marker,"heldOutPoses":poses,"conditionalLocalPredictionPassed":all(checks.values()),
            "checks":checks,"opticalZError":result['opticalZError'],"domain":domain,
            "maximumPlaneNormalErrorDegrees":max(o['correctedPlaneNormalErrorDegrees'] for o in result['observations']),
            "isWorldOrArmRegistration":False,"includesReferenceMetrologyUncertainty":False})
    return records


def fit_document(document,base_directory='.',allow_ray=False):
    if document.get('schemaVersion') != SCHEMA_VERSION:
        raise ValueError('Expected QR depth dataset schemaVersion 1')
    limits=dict(DEFAULT_LIMITS);limits.update(document.get('limits',{}))
    if any(not isinstance(v,(int,float)) or not math.isfinite(v) or v<=0 for v in limits.values()):
        raise ValueError('Quality limits must be finite and positive')
    samples=[];rejected=[];ids=set();source_roles={}
    for observation in document['observations']:
        try:
            identifier=observation['id']
            if identifier in ids:raise ValueError('Duplicate observation id')
            ids.add(identifier)
            if observation['split'] not in ('train','heldout'):
                raise ValueError('Explicit train/heldout split is required')
            for key in ('markerID','poseID','rangeGroup'):
                if not isinstance(observation[key],str) or not observation[key]:raise ValueError('Missing '+key)
            source=(observation['sourceImageSHA256'],observation['depthSHA256'])
            if source in source_roles and source_roles[source]!=observation['split']:
                raise ValueError('Same immutable RGBD source appears in both splits')
            source_roles[source]=observation['split']
            samples.append(sample_observation(observation,base_directory))
        except (ValueError,KeyError,TypeError,OSError) as exc:
            rejected.append({"id":observation.get('id'),"reason":str(exc)})
    train=[s for s in samples if s['metadata']['split']=='train'];held=[s for s in samples if s['metadata']['split']=='heldout']
    if len(train)<2 or not held:
        raise ValueError('At least two usable training observations and one heldout observation are required: '+json.dumps(rejected))
    train_poses={s['metadata']['poseID'] for s in train};held_poses={s['metadata']['poseID'] for s in held}
    if train_poses&held_poses:
        raise ValueError('Whole-pose holdout violated: '+str(sorted(train_poses&held_poses)))
    domain=domain_for(samples)
    training_domain=domain_for(train)
    model='inverse_scale_bias';p,identifiability=_fit(train,model)
    baseline_parameters=p.copy()
    comparisons=[]
    # The optional model is selected on leave-one-TRAIN-pose-out prediction.
    # Heldout data is used only after the model decision is frozen.
    if allow_ray:
        ray,ray_id=_fit(train,'inverse_ray')
        for candidate,parameters,information in ((model,p,identifiability),('inverse_ray',ray,ray_id)):
            folds=[]
            for pose in sorted(train_poses):
                subset=[s for s in train if s['metadata']['poseID']!=pose]
                validation=[s for s in train if s['metadata']['poseID']==pose]
                try:
                    fitted,info=_fit(subset,candidate)
                    prediction=evaluate(validation,candidate,fitted)
                    folds.append({"poseID":pose,"planeError":prediction['planeError'],"rank":info['rank']})
                except ValueError as exc:folds.append({"poseID":pose,"reason":str(exc)})
            complete=all('planeError' in fold and fold['rank']==MODELS[candidate] for fold in folds)
            score=float(np.mean([f['planeError']['rmseMeters'] for f in folds])) if complete else None
            comparisons.append({"model":candidate,"fullTrainingParameters":parameters.tolist(),
                "identifiability":information,"physicalBoundsOnTrainingDomain":physical_check(candidate,parameters,training_domain,limits),
                "trainingPoseCrossValidationRMSEMeters":score,"folds":folds})
        a,b=comparisons
        if (b['trainingPoseCrossValidationRMSEMeters'] is not None and a['trainingPoseCrossValidationRMSEMeters'] is not None
                and b['trainingPoseCrossValidationRMSEMeters'] < .8*a['trainingPoseCrossValidationRMSEMeters']
                and ray_id['rank']==6 and ray_id['normalizedDesignCondition']<1000
                and physical_check('inverse_ray',ray,training_domain,limits)['passed']):
            model,p,identifiability='inverse_ray',ray,ray_id
    training=evaluate(train,model,p);validation=evaluate(held,model,p)
    baseline_validation=evaluate(held,'inverse_scale_bias',baseline_parameters)
    # A single offset is reported as a separate parsimonious hypothesis. It
    # does not get selected by heldout residuals or broaden the admitted domain.
    bias_only=float(np.median([np.median(1/s['true']-1/s['raw']) for s in train]))
    bias_validation=evaluate(held,'inverse_scale_bias',np.array([1.,bias_only]))
    physical=physical_check(model,p,domain,limits)
    train_markers={s['metadata']['markerID'] for s in train};held_markers={s['metadata']['markerID'] for s in held}
    train_ranges={s['metadata']['rangeGroup'] for s in train};held_ranges={s['metadata']['rangeGroup'] for s in held}
    span=float(np.ptp([np.median(s['true']) for s in train]))
    group_audits=[group_cross_validation(train,model,field) for field in ('markerID','rangeGroup')]
    for audit in group_audits:audit['passed']=bool(_group_prediction_passed(audit,model,limits))
    camera_scopes=[s['metadata'].get('scope',{}) for s in samples]
    camera_keys=[(scope.get('cameraGeneration'),scope.get('intrinsicsIdentity'),scope.get('gatewaySessionGeneration')) for scope in camera_scopes]
    optical_geometries={(s['metadata']['width'],s['metadata']['height'],tuple(s['metadata']['cameraMatrix']),
                         tuple(s['metadata'].get('distortionCoefficients',[])),s['metadata'].get('zeroDistortionAssumed')) for s in samples}
    checks={"identifiable":identifiability['rank']==MODELS[model] and identifiability['normalizedDesignCondition']<1000,
            "rgbSourceHashesVerified":all(s['sourceImageHashVerified'] for s in samples),
            "singleCameraGeometryScope":all(all(v is not None for v in key) for key in camera_keys) and len(set(camera_keys))==1 and len(optical_geometries)==1,
            "physicalMonotonicBounds":physical['passed'],
            "trainingPoseDiversity":len(train_poses)>=limits['minimumTrainingPoses'],
            "wholeHeldOutPoseDiversity":len(held_poses)>=limits['minimumHeldOutPoses'],
            "wholeMarkerPrediction":len(held_markers-train_markers)>=limits['minimumHeldOutMarkers'] or group_audits[0]['passed'],
            "wholeRangeGroupPrediction":len(held_ranges-train_ranges)>=limits['minimumHeldOutRanges'] or group_audits[1]['passed'],
            "trainingMetricRangeSpan":span>=limits['minimumTrainingRangeSpanMeters'],
            "pnpCornerFit":all(s['pnp']['cornerRMSEPixels']<=limits['maximumPnPRMSEPixels'] for s in samples),
            "trainingRMSE":training['opticalZError']['rmseMeters']<=limits['maximumHeldOutRMSEMeters'],
            "trainingMaximumError":training['opticalZError']['maximumAbsoluteMeters']<=limits['maximumHeldOutAbsoluteErrorMeters'],
            "heldOutRMSE":validation['opticalZError']['rmseMeters']<=limits['maximumHeldOutRMSEMeters'],
            "heldOutMaximumError":validation['opticalZError']['maximumAbsoluteMeters']<=limits['maximumHeldOutAbsoluteErrorMeters'],
            "heldOutPlaneNormal":all(o['correctedPlaneNormalErrorDegrees']<=limits['maximumHeldOutPlaneNormalErrorDegrees'] for o in validation['observations']),
            "trainingPlaneNormal":all(o['correctedPlaneNormalErrorDegrees']<=limits['maximumHeldOutPlaneNormalErrorDegrees'] for o in training['observations']),
            "noRejectedEvidence":not rejected}
    checks['complexModelHeldOutImprovement']=(model!='inverse_ray' or
        (validation['opticalZError']['rmseMeters'] < .8*baseline_validation['opticalZError']['rmseMeters']
         and all(a['correctedOpticalZError']['rmseMeters']<=b['correctedOpticalZError']['rmseMeters']+.002
                 for a,b in zip(validation['observations'],baseline_validation['observations']))))
    # PnP branch ambiguity is a separate measured uncertainty, not hidden by a
    # good raw-depth fit.  A branch separated by >.5px is considered resolved.
    checks['pnpPlaneBranchResolved']=all(s['pnp']['branchRMSEMarginPixels'] is None or s['pnp']['branchRMSEMarginPixels']>.5 or s['alternativePlaneMaximumDepthDisagreementMeters']<=.005 for s in samples)
    return {"schemaVersion":1,"kind":"qr_native_depth_correction_diagnostic",
        "candidateValidated":all(checks.values()),"registrationVerified":False,"calibrationApplied":False,
        "model":model,"parameters":p.tolist(),"parameterOrder":['inverseScale','inverseBiasPerMeter'] if model=='inverse_scale_bias' else ['inverseScale','inverseRayXScale','inverseRayYScale','inverseBiasPerMeter','inverseRayXBiasPerMeter','inverseRayYBiasPerMeter'],
        "formula":"correctedZ = 1 / (a/rawZ + b)" if model=='inverse_scale_bias' else 'correctedZ = 1 / ((a0+ax*x+ay*y)/rawZ + b0+bx*x+by*y)',
        "identifiability":identifiability,"physicalBounds":physical,"domain":domain,
        "cameraGeometryScopes":[dict(zip(('cameraGeneration','intrinsicsIdentity','gatewaySessionGeneration'),key)) for key in sorted(set(camera_keys),key=str)],
        "checks":checks,"limits":limits,"trainingRangeSpanMeters":span,
        "independentEvidenceDimensions":{"unseenFinalHeldOutMarkers":sorted(held_markers-train_markers),
            "unseenFinalHeldOutRangeGroups":sorted(held_ranges-train_ranges),
            "finalHeldOutPoses":sorted(held_poses),"trainingPoses":sorted(train_poses)},
        "training":training,"heldOut":validation,"baselineHeldOut":baseline_validation,
        "inverseBiasOnlyDiagnostic":{"inverseScaleFixed":1.,"inverseBiasPerMeter":bias_only,"heldOut":bias_validation},
        "trainingPoseJackknife":pose_jackknife(train,model,p,samples),
        "trainingOnlyGroupCrossValidation":group_audits,
        "localHeldOutDomains":local_heldout_domains(held,model,p,limits),
        "trainingOnlyModelSelection":comparisons,
        "pixelAlignmentDiagnostic":alignment_diagnostic(samples),"rejectedObservations":rejected,
        "outlierPolicy":"All valid interior native returns retained in every error statistic; no truncation or floor flattening.",
        "scopeLimitations":["PnP metric scale is conditional on measured printed black-symbol size.",
            "Residuals and jackknife do not include a surveyed optical-center, printed-size or corner-localization uncertainty bound.",
            "A plane-only fit does not establish pixel alignment at discontinuities or object edges.",
            "Observed QR patch union does not validate unobserved UV/depth combinations, can surfaces, arm mounts or world registration.",
            "No correction outside the explicit observed patch union is admitted by this diagnostic."],
        "sources":[{k:v for k,v in s['metadata'].items() if k not in ('targetToCameraColumnMajor',)} for s in samples]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input',type=Path);parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--allow-ray',action='store_true',help='Consider six-parameter ray model only via training-pose cross-validation')
    args=parser.parse_args()
    document=json.loads(args.input.read_text())
    result=fit_document(document,args.input.parent,args.allow_ray)
    result['inputSHA256']=digest(args.input)
    result['workerSHA256']=digest(__file__)
    args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print(json.dumps({k:result[k] for k in ('candidateValidated','model','parameters','checks')}))


if __name__=='__main__':main()
