#!/usr/bin/env python3
"""Saved-scene pour planning only. Never imports a hardware/transport API."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(DIRECTORY))
from can_pour import (CanGeometry, CupGeometry, GhostPourRobot, PourWorkspace,
                      PourPlanError, PourWaypoint, transform, rigid, vector,
                      upright_can, geometry_path, geometry_audit,
                      fixed_timed_chain, glass_push_plan, convex_table_outline)
from table_planes import floor_anchored_scene


def load(path):
    return json.loads(Path(path).read_text(), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))


def json_default(value):
    if isinstance(value, np.generic): return value.item()
    if isinstance(value, np.ndarray): return value.tolist()
    raise TypeError('Unsupported report value: ' + type(value).__name__)


def prepare_base_and_torso(robot, initial, world_from_scene, advance):
    """Explicit ghost-only drive, then torso alignment; environment stays fixed.

    This is a geometric route hypothesis, not tread demand or calibrated TIC
    counts. Full observed obstacle coverage and stopping distance are absent.
    """
    yaw_index = robot.engine.joints['torso_yaw'].position_start()
    target_yaw = float(np.arctan2(world_from_scene[1,0], world_from_scene[0,0]))
    limits = robot.engine.plant.GetPositionLowerLimits(), robot.engine.plant.GetPositionUpperLimits()
    if not limits[0][yaw_index] <= target_yaw <= limits[1][yaw_index]:
        raise PourPlanError('Perpendicular torso target is outside the model limits')
    baseline = initial.copy()
    if abs(baseline[robot.engine.joints['body_lean'].position_start()]) > 1e-6:
        raise PourPlanError('This floor-aligned approach fixture requires its recorded upright body')
    base = np.eye(4)
    states = []
    for fraction in np.linspace(0, 1, max(2, int(np.ceil(advance/.02))+1)):
        pose = base.copy(); pose[0,3] = advance*fraction
        states.append(('drive', 'Drive toward fixed table · %.0f / %.0f cm' % (advance*fraction*100,advance*100), baseline.copy(), pose))
    base[0,3] = advance
    start_yaw = float(baseline[yaw_index])
    for fraction in np.linspace(0,1,max(2,int(np.ceil(abs(target_yaw-start_yaw)/.025))+1))[1:]:
        pose = baseline.copy(); pose[yaw_index] = start_yaw+(target_yaw-start_yaw)*fraction
        states.append(('torso', 'Turn torso perpendicular to table · %.1f degrees' % np.rad2deg(pose[yaw_index]), pose, base.copy()))
    baseline[yaw_index] = target_yaw
    forward = robot.frame(baseline,'torso_link')[:3,0]
    if abs(np.dot(forward,world_from_scene[:3,1])) > 1e-6 or np.dot(forward,world_from_scene[:3,0]) < .999:
        raise PourPlanError('Torso forward axis is not perpendicular to the observed front edge')
    return baseline,base,states,dict(executable=False,worldFromRobotAtReach=base.tolist(),
        forwardTravelMeters=advance,torsoStartYawRadians=start_yaw,torsoTargetYawRadians=target_yaw,
        tableNormalHeadingRadians=target_yaw,torsoPerpendicularVerifiedInModel=True,
        torsoReferenceMeasured=False,baseRouteChecked=False,
        sequence=['drive toward fixed table','turn torso perpendicular','reach and pour'],
        missingEvidence=['observed complete drive corridor','measured tread stopping distance','current torso zero/reference'])


def grasp_branch_seed(robot, initial, model_from_scene, grasp, raised):
    """Find the low grasp branch by descending from a solved raised pose.

    Numerical continuation only. It adds no physical motion or exemptions.
    """
    seed, report = robot.solve(model_from_scene@grasp, initial)
    if report['solved']: return seed,report
    top, goal = model_from_scene@raised,model_from_scene@grasp
    guess, valid = robot.solve(top,initial)
    if valid['solved']:
        for fraction in np.linspace(0,1,18)[1:]:
            target=goal.copy();target[:3,3]=top[:3,3]*(1-fraction)+goal[:3,3]*fraction
            guess,valid=robot.solve(target,guess)
            if not valid['solved']: break
        if valid['solved']: return guess,valid
    return seed,report


def plan(scene, status, advance=0., hold=.35):
    if not np.isfinite(advance) or not 0 <= advance <= .40:
        raise PourPlanError('Base-advance hypothesis must be between 0 and 0.40 meters')
    robot = GhostPourRobot(DIRECTORY)
    initial = robot.from_status(status)
    can = CanGeometry(**scene['can'])
    cup = CupGeometry(**scene['cup'])
    source = upright_can(scene['canCenter'], scene['openingDirection'])
    approach = vector(scene['graspApproach']); approach[2] = 0
    if np.linalg.norm(approach) < .1: raise PourPlanError('Missing horizontal grasp approach')
    approach /= np.linalg.norm(approach)
    up = np.array([0., 0., 1.])
    grasp_center = vector(scene['canCenter']).copy()
    grasp_offset = float(scene.get('graspHeightOffset', 0.))
    if not np.isfinite(grasp_offset) or abs(grasp_offset) > can.height / 4:
        raise PourPlanError('Grasp center must remain in the middle half of the can')
    grasp_center[2] += grasp_offset
    grasp = transform(np.column_stack([up, np.cross(approach, up), approach]), grasp_center)
    payload_path = geometry_path(can, cup, source, grasp)
    pregrasp = grasp.copy(); pregrasp[:3, 3] -= approach * .08
    steps = [PourWaypoint('Approach open gripper 8 cm before can', source, pregrasp, False,
                          'Entry from current posture requires swept full-robot clearance')]
    steps += payload_path
    retreat = grasp.copy(); retreat[:3, 3] -= approach * .08
    steps += [PourWaypoint('Retract empty gripper after supported release', source, retreat, False)]
    # Height must come from observed floor/table separation, never neck FK or
    # a cosmetic horizontal projection of the old, vertically wrong anchor.
    world_from_scene, table_alignment = floor_anchored_scene(scene['modelFromCameraPrior'],
        scene['cameraFromScene'], scene['floorTableObservation'])
    q0,world_from_robot,preparation,body_plan=prepare_base_and_torso(robot,initial,world_from_scene,advance)
    model_from_scene=np.linalg.inv(world_from_robot)@world_from_scene
    bounds=np.asarray(scene['tableBoundsXY'],float)
    outline=convex_table_outline(scene.get('tableOutlineXY',
        [bounds[0],[bounds[1][0],bounds[0][1]],bounds[1],[bounds[0][0],bounds[1][1]]]))
    workspace = PourWorkspace(robot, can, cup, bounds, scene['tableZ'], model_from_scene, outline)
    world_workspace = PourWorkspace(robot, can, cup, bounds, scene['tableZ'], world_from_scene, outline)
    can_in_tool = np.linalg.inv(grasp) @ source
    baseline_self = robot.engine.clearance.check(initial)
    baseline_world = world_workspace.check(initial, source, supported=True, whole_robot=True)
    reports, seed = [], q0.copy()
    previous=initial.copy()
    for phase,label,q,base_pose in preparation:
        reports.append(dict(index=len(reports),stage=label,phase=phase,attached=False,
            positions={name:float(q[j.position_start()]) for name,j in robot.engine.joints.items()},
            worldFromRobot=base_pose.tolist(),desiredCanPose=(world_from_scene@source).tolist(),
            ik=dict(solved=True,note='Body geometry stage; no arm IK requested'),
            selfClearance=robot.review(previous,q),
            worldClearance=world_workspace.check(q,source,supported=True,robot_pose=base_pose,whole_robot=True),
            checkpoint='Geometric preview only; drive corridor, stopping distance and torso reference unverified'))
        previous=q
    previous_pour = None
    raw_pour, pour_solved = [], True
    # Seed the pregrasp from a solved grasp rather than forcing a local IK
    # branch directly out of hanging. The connector is still reviewed from q0.
    raised=next(step.world_tool for step in steps if step.stage=='Raise only to computed cup clearance')
    grasp_seed, grasp_seed_report = grasp_branch_seed(robot,q0,model_from_scene,grasp,raised)
    for index, step in enumerate(steps):
        target = model_from_scene @ step.world_tool
        continuation = seed.copy()
        if index == 0 and grasp_seed_report['solved']: continuation = grasp_seed
        if step.stage.startswith('Tilt toward') and previous_pour is not None:
            # Extrapolate the local IK branch to discourage redundant-joint
            # wandering, which otherwise turns a smooth tilt into a jerky fit.
            continuation[robot.indices] += (seed - previous_pour)[robot.indices]
        old_seed = seed.copy()
        q, ik = robot.solve(target, continuation)
        report = dict(index=len(reports), stage=step.stage, phase='arm', attached=step.attached,
                      positions={name:float(q[j.position_start()]) for name,j in robot.engine.joints.items()},
                      checkpoint=step.checkpoint, ik=ik,
                      worldFromRobot=world_from_robot.tolist(),
                      desiredCanPose=(world_from_scene @ step.world_can).tolist(),
                      targetToolPose=target.tolist(), ghostFrames=robot.ghost_frames(q))
        if ik['solved']:
            report['selfClearance'] = robot.review(seed, q)
            # Release is a stationary state change; payload remains at support.
            moving_attached = step.attached and step.stage != 'Verify jaw closure'
            report['worldClearance'] = workspace.transition(seed, q, can_in_tool, source,
                attached=moving_attached,
                supported=step.stage in ('Approach open gripper 8 cm before can', 'Grasp at source',
                    'Verify jaw closure', 'Retention test lift', 'Return to source support',
                    'Release supported can', 'Retract empty gripper after supported release'))
            seed = q
        if step.stage == 'Position opening over cup' or step.stage.startswith('Tilt toward'):
            raw_pour.append(ik['rawRadians'])
            pour_solved = pour_solved and ik['solved']
            previous_pour = old_seed if step.stage.startswith('Tilt toward') else None
        reports.append(report)
    timed = None
    quick = None
    if pour_solved:
        try: timed = fixed_timed_chain(raw_pour, hold_seconds=hold)
        except PourPlanError as error: timed = dict(executable=False, error=str(error))
        # A prepared tilt below the ideal flow threshold shortens the active
        # pour/cutoff portion. It is not guaranteed dry with uncertain fill/lip.
        onset = can.tilt_for_fraction(can.initial_fraction)
        final = can.tilt_for_fraction(can.final_fraction)
        first = max(0, int((onset - np.deg2rad(10)) / final * (len(raw_pour)-1)))
        if len(raw_pour) - first >= 6:
            try:
                quick = fixed_timed_chain(raw_pour[first:], hold_seconds=hold)
                quick['preparedTiltDegrees'] = float(np.rad2deg(final * first / (len(raw_pour)-1)))
                quick['returnsToPreparedTiltBeforeFullUpright'] = True
                quick['preparedTiltDrynessVerified'] = False
            except PourPlanError as error: quick = dict(executable=False, error=str(error))
    for chain in (timed, quick):
        if chain and 'samples' in chain:
            chain['sweptReview'] = workspace.review_timed_curve(chain, q0, can_in_tool)
    native_timed = []
    if quick and 'samples' in quick:
        for sample in quick['samples']:
            q=q0.copy();q[robot.indices]=np.array(sample['rawRadians'])-robot.priors[robot.side]
            native_timed.append(dict(timeSeconds=sample['timeSeconds'],stage=sample['stage'],
                positions={name:float(q[j.position_start()]) for name,j in robot.engine.joints.items()},
                worldFromRobot=world_from_robot.tolist(),phase='arm',
                desiredCanPose=(world_from_robot @ robot.frame(q) @ can_in_tool).tolist(),
                attached=True,detail='Fixed-time candidate; full task remains non-executable'))
    push = dict(executable=False, reason='Recipient direction not yet confirmed in this scene')
    if 'recipientXY' in scene:
        try: push = glass_push_plan(cup, scene['tableBoundsXY'], scene['recipientXY'],table_outline_xy=outline)
        except PourPlanError as error: push = dict(executable=False, reason=str(error))
    failed = [r['stage'] for r in reports if not r['ik']['solved']]
    blocked = [r['stage'] for r in reports if r['ik']['solved'] and
               (not r['selfClearance']['clear'] or not r['worldClearance']['clear'])]
    return dict(schemaVersion=1, hardwareOutputEnabled=False, executable=False,
                physicalArm='right', nominalBaseAdvanceMeters=advance,
                baseline={name:float(initial[j.position_start()]) for name,j in robot.engine.joints.items()},
                bodyPreparation=body_plan,
                nativeTimedPreview=native_timed,
                baseRouteChecked=False, sceneEvidence=scene.get('evidence', {}),
                tableAlignment=table_alignment,
                sceneGeometry=dict(can=scene['can'],cup=scene['cup'],tableBoundsXY=scene['tableBoundsXY'],
                    tableOutlineXY=outline.tolist(),tableExtentComplete=False,
                    tableZ=scene['tableZ'],modelFromScene=world_from_scene.tolist()),
                modelID=robot.engine.reference['modelID'], modelReferenceID=robot.engine.reference['referenceID'],
                modelSource='pinned ghost scan; simulation only; supplied saved status gives both arms and head targets',
                baselineSelf=baseline_self, baselineWorld=baseline_world,
                geometryAudit=geometry_audit(payload_path, can, cup), liquid=can.liquid_report(),
                failedIKStages=failed, blockedClearanceStages=blocked, fixedTimedPour=timed, preparedTimedPour=quick,
                leftGlassPush=push, steps=reports,
                blockers=['Camera-to-arm registration and body/torso posture remain unverified',
                          'Gripper contact offset and open-jaw envelope are not measured',
                          'Base travel corridor and measured stopping distance require current review',
                          'Known arm/head model mismatch remains unresolved',
                          'Fixed-time compiled curve is not executable through overlapping cmd4 commands'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scene', required=True, type=Path)
    parser.add_argument('--status', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--base-advance', type=float, default=0.)
    parser.add_argument('--hold-seconds', type=float, default=.35)
    args = parser.parse_args()
    try:
        report = plan(load(args.scene), load(args.status), args.base_advance, args.hold_seconds)
    except (PourPlanError, ValueError, KeyError) as error:
        report = dict(schemaVersion=1, executable=False, hardwareOutputEnabled=False, error=str(error))
    report['inputHashes'] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (args.scene, args.status)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False, default=json_default) + '\n')
    summary = {k:v for k,v in report.items() if k not in ('steps','fixedTimedPour','preparedTimedPour','nativeTimedPreview')}
    for name in ('fixedTimedPour','preparedTimedPour'):
        if report.get(name): summary[name] = {k:v for k,v in report[name].items() if k not in ('samples','spline')}
    print(json.dumps(summary, indent=2, allow_nan=False, default=json_default))
    return 0 if 'error' not in report else 2


if __name__ == '__main__': raise SystemExit(main())
