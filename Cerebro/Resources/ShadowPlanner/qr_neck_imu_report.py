"""Offline bias-tolerant upper-neck frequency profile from stationary raw IMU.

For each fixed pan/lower group: a(U)=b+u*cos(s*(U-Uref))+v*sin(s*(U-Uref)).
The 3-vector basis absorbs constant offsets and fixed linear axis anisotropy;
b is not an identified pure sensor bias. No assumed 9.81, camera calibration,
URDF, factory rotation, actuator API or applied servo mapping is used.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys

import numpy as np

MINIMUM_SPAN_TARGET_UNITS = 1000
MINIMUM_UNIQUE_LEVELS = 5
LOWER_DEGREES_PER_TARGET = .01
UPPER_DEGREES_PER_TARGET = .12


def read_json(path):
    raw=Path(path).read_bytes()
    if len(raw)>5_000_000:raise ValueError('Input JSON exceeds 5 MB')
    value=json.loads(raw,parse_constant=lambda v:(_ for _ in ()).throw(ValueError('Invalid JSON number '+v)))
    return value,hashlib.sha256(raw).hexdigest()


def load_records(path):
    path=Path(path).resolve();document,digest=read_json(path);records=[];protected={path};sources=[]
    if not isinstance(document,dict) or document.get('schemaVersion')!=1:raise ValueError('Expected version-1 JSON object')
    if document.get('captureKind')=='multi_target_neck_survey':
        if document.get('robotBaseStationary') is not True:raise ValueError('Survey base must be reported stationary')
        session=document.get('sessionID');scene=document.get('sceneContextID')
        for file in sorted(path.parent.glob('discovery-*.json')):
            if not re.fullmatch(r'discovery-\d+-\d+\.json',file.name):continue
            observation,sha=read_json(file)
            if not isinstance(observation,dict):raise ValueError('Discovery record must be an object')
            records.append({'view':observation,'sourceKind':'discovery','sourcePath':str(file)})
            protected.add(file.resolve());sources.append({'path':str(file),'sha256':sha})
        for entry in document.get('captures',[]):
            if not isinstance(entry,dict) or not isinstance(entry.get('capturePath'),str):raise ValueError('Invalid capture manifest entry')
            file=Path(entry['capturePath']);file=(path.parent/file).resolve() if not file.is_absolute() else file.resolve()
            capture,sha=read_json(file)
            if not isinstance(capture,dict) or capture.get('surveySessionID')!=session or capture.get('sceneContextID')!=scene:raise ValueError('Target capture belongs to another survey scene')
            views=capture.get('views')
            if not isinstance(views,list):raise ValueError('Capture has no view list')
            records.extend({'view':view,'sourceKind':'target_capture','sourcePath':str(file)} for view in views)
            protected.add(file);sources.append({'path':str(file),'sha256':sha})
    elif isinstance(document.get('views'),list):
        records=[{'view':view,'sourceKind':'target_capture','sourcePath':str(path)} for view in document['views']]
        sources.append({'path':str(path),'sha256':digest})
    else:raise ValueError('Expected a survey manifest or a QR capture')
    if len(records)>4000:raise ValueError('IMU report exceeds 4000 view records')
    return records,{'inputSHA256':digest,'inputPath':str(path),'sessionID':document.get('sessionID'),
                    'sceneContextID':document.get('sceneContextID'),'surveyStatusAtRead':document.get('status'),'sources':sources},protected


def vector(value,name):
    if not isinstance(value,list) or len(value)!=3 or any(type(v) not in (int,float) or not math.isfinite(v) for v in value):raise ValueError(name+' must be a finite 3-vector')
    return np.array(value,dtype=float)


def quality_record(record):
    view=record['view']
    if not isinstance(view,dict):raise ValueError('View must be an object')
    pan,lower,upper=view.get('neckPanDegrees'),view.get('lowerTarget'),view.get('neckUpperTarget')
    if type(pan) not in (int,float) or not math.isfinite(pan) or abs(pan)>180 or type(lower) is not int or type(upper) is not int or not 1<=lower<=16383 or not 1<=upper<=16383:raise ValueError('Invalid accepted neck targets')
    imu=view.get('imu')
    if not isinstance(imu,dict) or imu.get('stationary') is not True or imu.get('axes')!='sensor_native' or imu.get('gravity_source')!='stationary_accelerometer_mean':raise ValueError('No stationary native accelerometer mean')
    a=vector(imu.get('gravity_mps2'),'gravity_mps2');gyro=vector(imu.get('gyro_rad_s'),'gyro_rad_s');sd=vector(imu.get('gravity_std_mps2'),'gravity_std_mps2')
    age,window,count=imu.get('age_milliseconds'),imu.get('window_milliseconds'),imu.get('sample_count')
    if any(type(v) not in (int,float) or not math.isfinite(v) for v in (age,window)) or not 0<=age<=750 or not 100<=window<=2000 or type(count) is not int or count<5:raise ValueError('Stale or insufficient IMU window')
    if not 5<=np.linalg.norm(a)<=15 or np.min(sd)<0 or np.linalg.norm(sd)>.25 or np.linalg.norm(gyro)>.03:raise ValueError('IMU norm, variability or gyro exceeds diagnostic quality bounds')
    return {'pan':round(float(pan),6),'lower':lower,'upper':upper,'a':a,'sd':sd,'gyroNorm':float(np.linalg.norm(gyro)),
            'windowMilliseconds':float(window),'sampleCount':count,'sourceKind':record.get('sourceKind','target_capture')}


def design(upper,reference,slope):
    angle=np.radians(slope*(np.array(upper,dtype=float)-reference))
    return np.column_stack((np.ones(len(angle)),np.cos(angle),np.sin(angle)))


def profile_cost(slope,groups,include_predictions=False):
    total=0.;outputs=[]
    for group in groups:
        X=design(group['trainingUpper'],group['referenceUpper'],slope);Y=group['trainingAcceleration']
        coefficients,_,rank,singular=np.linalg.lstsq(X,Y,rcond=None)
        residual=Y-X@coefficients
        total+=float(np.sum(residual**2))
        if include_predictions:outputs.append((coefficients,singular,rank))
    return (total,outputs) if include_predictions else total


def golden_minimum(function,left,right):
    ratio=(math.sqrt(5)-1)/2;a=right-ratio*(right-left);b=left+ratio*(right-left);fa,fb=function(a),function(b)
    for _ in range(70):
        if right-left<1e-10:break
        if fa<fb:right,b,fb=b,a,fa;a=right-ratio*(right-left);fa=function(a)
        else:left,a,fa=a,b,fb;b=left+ratio*(right-left);fb=function(b)
    x=(left+right)/2;return x,function(x)


def analyze(records):
    accepted=[];rejected=[]
    for index,record in enumerate(records):
        try:accepted.append(quality_record(record))
        except (ValueError,TypeError,KeyError) as error:rejected.append({'recordIndex':index,'reason':str(error)})
    grouped={}
    for row in accepted:grouped.setdefault((row['pan'],row['lower']),[]).append(row)
    usable=[];coverage=[]
    for (pan,lower),rows in sorted(grouped.items()):
        discovery=[row for row in rows if row['sourceKind']=='discovery']
        discovery_levels={row['upper'] for row in discovery}
        use_discovery=len(discovery_levels)>=MINIMUM_UNIQUE_LEVELS and max(discovery_levels)-min(discovery_levels)>=MINIMUM_SPAN_TARGET_UNITS
        chosen=discovery if use_discovery else rows
        by_level={}
        for row in chosen:by_level.setdefault(row['upper'],[]).append(row)
        levels=sorted(by_level);span=levels[-1]-levels[0] if levels else 0
        info={'panDegrees':pan,'lowerTarget':lower,'uniqueUpperLevels':len(levels),'upperSpanTargetUnits':span,
              'sourceSelection':'wide_discovery_only' if use_discovery else 'all_available_records',
              'minimumUniqueLevels':MINIMUM_UNIQUE_LEVELS,'minimumSpanTargetUnits':MINIMUM_SPAN_TARGET_UNITS}
        if len(levels)<MINIMUM_UNIQUE_LEVELS or span<MINIMUM_SPAN_TARGET_UNITS:
            info.update(status='unavailable',reason='Need five distinct upper levels spanning at least 1000 raw target units');coverage.append(info);continue
        heldout=levels[len(levels)//2];training=[level for level in levels if level!=heldout]
        all_by_level={}
        for row in rows:all_by_level.setdefault(row['upper'],[]).append(row)
        validation=[level for level in sorted(all_by_level) if level not in training]
        train_a=np.array([np.median([r['a'] for r in by_level[level]],axis=0) for level in training])
        valid_a=np.array([np.median([r['a'] for r in all_by_level[level]],axis=0) for level in validation])
        info.update(status='usable',trainingUpperLevels=training,heldOutUpperLevels=validation,
                    primaryHeldOutUpperLevel=heldout,referenceUpper=training[0])
        coverage.append(info)
        usable.append({**info,'trainingUpper':training,'trainingAcceleration':train_a,'validationUpper':validation,
                       'validationAcceleration':valid_a,'rows':rows})
    base={'schemaVersion':1,'status':'imu_upper_profile_unavailable','registrationVerified':False,'candidateURDFReady':False,
          'acceptedRecordCount':len(accepted),'rejectedRecordCount':len(rejected),'rejectedRecords':rejected,
          'coverage':coverage,'usableGroupCount':len(usable),
          'mechanicalComparisonPriorDegreesPerTargetBounds':[LOWER_DEGREES_PER_TARGET,UPPER_DEGREES_PER_TARGET],
          'assumedGravityMagnitude':None,'factoryRotationUsed':False,'cameraIntrinsicsUsed':False,
          'model':'a(U) = b + u cos[s(U-Uref)] + v sin[s(U-Uref)] in raw native sensor axes; vectors b/u/v fitted separately for each fixed pan/lower group.',
          'limitations':['The constant term b includes sensor offset and gravity parallel to the rotation axis; it is not an identified pure accelerometer bias.',
                         'Fixed linear anisotropy is absorbed by the ellipse basis; changing bias, servo hysteresis or nonlinear motion can still invalidate the model.',
                         'Median acceleration per commanded upper level is used; overlapping IMU windows and repeated video frames are not counted as independent angle evidence.',
                         'Conditional uncertainty assumes the sinusoidal mapping and independent isotropic level residuals; it is not hardware calibration uncertainty.',
                         'No gain, zero, factory transform, gravity magnitude, URDF or world registration is applied.']}
    if not usable:return base
    grid=np.linspace(LOWER_DEGREES_PER_TARGET,UPPER_DEGREES_PER_TARGET,1101);costs=np.array([profile_cost(value,usable) for value in grid])
    minima=[i for i in range(1,len(grid)-1) if costs[i]<=costs[i-1] and costs[i]<=costs[i+1]]
    minima.extend([0,len(grid)-1]);candidates=[]
    for index in minima:
        if index in (0,len(grid)-1):candidates.append((float(grid[index]),float(costs[index])))
        else:candidates.append(golden_minimum(lambda x:profile_cost(x,usable),float(grid[index-1]),float(grid[index+1])))
    candidates.sort(key=lambda item:item[1]);slope,cost=candidates[0];cost,solutions=profile_cost(slope,usable,True)
    train_coordinates=sum(len(g['trainingUpper'])*3 for g in usable);dof=max(1,train_coordinates-9*len(usable)-1);variance=cost/dof
    h=max(1e-7,slope*1e-4);curvature=(profile_cost(slope+h,usable)-2*cost+profile_cost(slope-h,usable))/(h*h)
    sigma=math.sqrt(2*variance/curvature) if curvature>0 else None
    at_bound=min(slope-LOWER_DEGREES_PER_TARGET,UPPER_DEGREES_PER_TARGET-slope)<1e-6
    band=grid[costs<=cost+3.841458820694124*variance]
    intervals=[]
    if len(band):
        start=previous=float(band[0])
        for value in band[1:]:
            if value-previous>.000101:intervals.append([start,previous]);start=float(value)
            previous=float(value)
        intervals.append([start,previous])
    groups=[];heldout_residuals=[];plane_normals=[]
    for group,(coefficients,singular,rank) in zip(usable,solutions):
        predicted=design(group['validationUpper'],group['referenceUpper'],slope)@coefficients
        errors=group['validationAcceleration']-predicted;heldout_residuals.extend(errors.tolist())
        ellipse=coefficients[1:].T;ellipse_singular=np.linalg.svd(ellipse,compute_uv=False);normal=np.cross(coefficients[1],coefficients[2]);normal/=max(np.linalg.norm(normal),1e-30);plane_normals.append(normal)
        baseline=group['trainingAcceleration'][0].copy();baseline/=np.linalg.norm(baseline)
        naive=[]
        all_levels=sorted(set(row['upper'] for row in group['rows']))
        for upper in all_levels:
            if upper in group['trainingUpper']:
                acceleration=group['trainingAcceleration'][group['trainingUpper'].index(upper)]
            else:
                acceleration=group['validationAcceleration'][group['validationUpper'].index(upper)]
            unit=acceleration/np.linalg.norm(acceleration)
            naive.append({'upperTarget':upper,'includedInTraining':upper in group['trainingUpper'],'profileAngleChangeDegrees':abs(slope*(upper-group['referenceUpper'])),
                          'naiveUnitAccelerationDirectionChangeDegrees':math.degrees(math.acos(float(np.clip(unit@baseline,-1,1))))})
        rows=group['rows']
        groups.append({'panDegrees':group['panDegrees'],'lowerTarget':group['lowerTarget'],'trainingUpperLevels':group['trainingUpper'],
                       'heldOutUpperLevels':group['validationUpper'],'referenceUpperTarget':group['referenceUpper'],
                       'bSensor':coefficients[0].tolist(),'uSensor':coefficients[1].tolist(),'vSensor':coefficients[2].tolist(),
                       'ellipseSemiAxisLengthsMetersPerSecondSquared':ellipse_singular.tolist(),
                       'ellipseAxisRatio':float(ellipse_singular[0]/max(ellipse_singular[1],1e-30)),
                       'ellipsePlaneNormalSensor':normal.tolist(),'designSingularValues':singular.tolist(),
                       'designConditionNumber':float(singular[0]/max(singular[-1],1e-30)),'designRank':int(rank),
                       'heldOutVectorRMSEMetersPerSecondSquared':float(np.sqrt(np.mean(np.sum(errors**2,axis=1)))),
                       'heldOutResidualVectorsMetersPerSecondSquared':errors.tolist(),'naiveVersusProfileAngles':naive,
                       'medianGyroNormRadiansPerSecond':float(np.median([r['gyroNorm'] for r in rows])),
                       'maximumGyroNormRadiansPerSecond':max(r['gyroNorm'] for r in rows),
                       'medianWindowMilliseconds':float(np.median([r['windowMilliseconds'] for r in rows])),
                       'medianRawAccelerationNormMetersPerSecondSquared':float(np.median([np.linalg.norm(r['a']) for r in rows]))})
    normal_agreements=[math.degrees(math.acos(float(np.clip(abs(a@b),-1,1)))) for i,a in enumerate(plane_normals) for b in plane_normals[i+1:]]
    identifiable=any(min(g['ellipseSemiAxisLengthsMetersPerSecondSquared'])>.2 and g['designConditionNumber']<1e4 for g in groups) and curvature>0
    base.update(status='imu_upper_profile_unverified' if identifiable else 'imu_upper_profile_unidentifiable',upperDegreesPerTargetUnit=slope,
                gainRelativeToNominalPoint03Prior=slope/.03,nominalPoint03PriorIsMeasured=False,
                trainingSumSquaredAccelerationResiduals=cost,trainingResidualDegreesOfFreedom=dof,
                conditionalResidualVariancePerCoordinate=variance,
                conditionalOneSigmaDegreesPerTargetUnit=sigma,
                conditionalLocal95PercentIntervalDegreesPerTargetUnit=[max(LOWER_DEGREES_PER_TARGET,slope-1.96*sigma),min(UPPER_DEGREES_PER_TARGET,slope+1.96*sigma)] if sigma is not None else None,
                profile95PercentIntervalsOnGrid=intervals,profileMinimumAtBound=at_bound,
                frequencyIdentifiableConditionally=identifiable,
                identificationLimitations=[] if identifiable else ['Insufficient ellipse excitation or profile curvature; do not interpret the selected frequency as an angle scale.'],
                alternativeProfileMinima=[{'upperDegreesPerTargetUnit':x,'trainingSumSquaredResiduals':y} for x,y in candidates[:8]],
                heldOutVectorRMSEMetersPerSecondSquared=float(np.sqrt(np.mean(np.sum(np.array(heldout_residuals)**2,axis=1)))),
                groups=groups,maximumEllipsePlaneNormalDisagreementDegrees=max(normal_agreements) if normal_agreements else None,
                profile=[{'upperDegreesPerTargetUnit':float(x),'trainingSumSquaredResiduals':float(y)} for x,y in zip(grid,costs)])
    return base


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('input',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args()
    output=args.output.resolve()
    if args.output.suffix.lower()!='.json' or output==args.input.resolve() or Path(__file__).parent.resolve() in output.parents:
        print('Output must be separate JSON outside the protected worker/model directory.',file=sys.stderr);return 2
    validated=False
    try:
        records,provenance,protected=load_records(args.input);validated=True
        if output in protected:print('Output cannot replace a source record.',file=sys.stderr);return 2
        result=analyze(records);result['provenance']=provenance;code=0
    except (ValueError,TypeError,KeyError,OSError,np.linalg.LinAlgError) as error:
        result={'schemaVersion':1,'status':'rejected','registrationVerified':False,'candidateURDFReady':False,'error':str(error)}
        print(str(error),file=sys.stderr);code=2
        if not validated and output.exists():return 2
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n');return code


if __name__=='__main__':raise SystemExit(main())
