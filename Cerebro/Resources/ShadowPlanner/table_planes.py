"""Same-frame floor/table observations for a saved, non-executable scene.

The parallel-plane separation supplies height independently of neck FK. It
does not measure camera XY, yaw, arm registration or robot body attitude.
"""
import numpy as np
from can_pour import PourPlanError, rigid, transform, vector


def unit(value):
    result = vector(value)
    length = np.linalg.norm(result)
    if length < 1e-6:
        raise PourPlanError('Missing plane normal')
    return result / length


def angle(a, b):
    return float(np.rad2deg(np.arccos(np.clip(unit(a) @ unit(b), -1, 1))))


def backproject(depth, intrinsics):
    y, x = np.indices(depth.shape)
    z = np.asarray(depth, float) / 1000
    fx, fy = float(intrinsics['fx']), float(intrinsics['fy'])
    if not (np.isfinite([fx, fy]).all() and min(fx, fy) > 0):
        raise PourPlanError('Invalid depth intrinsics')
    return np.stack([(x-intrinsics['cx'])*z/fx, (y-intrinsics['cy'])*z/fy, z], axis=-1)


def region_points(points, rectangles):
    mask = np.zeros(points.shape[:2], bool)
    for x0, y0, x1, y1 in rectangles:
        if not (0 <= x0 < x1 <= mask.shape[1] and 0 <= y0 < y1 <= mask.shape[0]):
            raise PourPlanError('Plane region lies outside the image')
        mask[y0:y1, x0:x1] = True
    mask &= np.isfinite(points).all(axis=-1) & (points[:,:,2] > .2) & (points[:,:,2] < 2.5)
    result = points[mask]
    return result[::max(1, len(result)//6000)]


def robust_plane(points, up):
    points = np.asarray(points, float)
    if points.ndim != 2 or points.shape[1] != 3 or len(points) < 200 or not np.isfinite(points).all():
        raise PourPlanError('Insufficient finite plane observations')
    up = unit(up)
    rng = np.random.default_rng(42)
    best = np.zeros(len(points), bool)
    for _ in range(500):
        a, b, c = points[rng.choice(len(points), 3, replace=False)]
        n = np.cross(b-a, c-a)
        if np.linalg.norm(n) < 1e-9:
            continue
        n /= np.linalg.norm(n)
        if n @ up < 0: n = -n
        if n @ up < .9: continue
        candidate = np.abs(points@n-a@n) < .012
        if candidate.sum() > best.sum(): best = candidate
    if best.sum() < max(150, len(points)*.35):
        raise PourPlanError('No supported horizontal plane in selected region')
    for _ in range(5):
        cloud = points[best]
        _, singular, vectors = np.linalg.svd(cloud-cloud.mean(axis=0), full_matrices=False)
        if singular[1]/np.sqrt(len(cloud)) < .025:
            raise PourPlanError('Plane observations have insufficient spatial spread')
        n = vectors[-1]
        if n @ up < 0: n = -n
        offset = float(np.median(cloud@n))
        best = np.abs(points@n-offset) < .015
    return n, offset, best


def fit_parallel_planes(floor, table, imu_up):
    """Robust independent fits followed by the stated horizontal constraint."""
    clouds = [np.asarray(floor, float), np.asarray(table, float)]
    fits = [robust_plane(p, imu_up) for p in clouds]
    normal_difference = angle(fits[0][0], fits[1][0])
    if normal_difference > 7:
        raise PourPlanError('Floor and tabletop independent normals disagree by more than 7 degrees')
    masks = [fit[2] for fit in fits]
    for _ in range(5):
        centered = [(p[m]-p[m].mean(axis=0))/np.sqrt(m.sum()) for p, m in zip(clouds, masks)]
        _, _, vectors = np.linalg.svd(np.concatenate(centered), full_matrices=False)
        n = vectors[-1]
        if n @ unit(imu_up) < 0: n = -n
        offsets = [float(np.median(p[m]@n)) for p, m in zip(clouds, masks)]
        masks = [np.abs(p@n-d) < .015 for p, d in zip(clouds, offsets)]
        if any(m.mean() < .35 for m in masks):
            raise PourPlanError('Parallel-plane fit lost observation support')
    rms = [float(np.sqrt(np.mean((p[m]@n-d)**2))) for p, m, d in zip(clouds, masks, offsets)]
    height = offsets[1]-offsets[0]
    if not .3 <= height <= 1.2 or max(rms) > .012 or angle(n, imu_up) > 10:
        raise PourPlanError('Floor/table height or residuals exceed the observation bounds')
    return dict(method='same-frame parallel floor/table depth planes',
        upOptical=n.tolist(), floorOffsetOpticalMeters=offsets[0], tableOffsetOpticalMeters=offsets[1],
        tableHeightMeters=height, floorRMSMeters=rms[0], tableRMSMeters=rms[1],
        floorInlierFraction=float(masks[0].mean()), tableInlierFraction=float(masks[1].mean()),
        independentNormalDifferenceDegrees=normal_difference, imuNormalDifferenceDegrees=angle(n, imu_up),
        registrationVerified=False)


def floor_anchored_scene(camera_prior, camera_from_scene, observation):
    """Rotate the entire optical scene and anchor its vertical origin to floor.

    Rotating only the table while keeping the old anchor retains the erroneous
    neck-model height. Here all measured objects use one corrected camera pose.
    """
    prior, local = rigid(camera_prior), rigid(camera_from_scene)
    if observation.get('method') != 'same-frame parallel floor/table depth planes':
        raise PourPlanError('Saved scene needs a paired floor/table observation')
    up = unit(observation['upOptical'])
    floor, table, height = [float(observation[key]) for key in
        ('floorOffsetOpticalMeters', 'tableOffsetOpticalMeters', 'tableHeightMeters')]
    if not np.isfinite([floor, table, height]).all() or not .3 <= height <= 1.2 or abs(table-floor-height) > 1e-6:
        raise PourPlanError('Inconsistent measured table height')
    if abs(up@local[:3,3]-table) > .005 or np.linalg.norm(local[:3,2]-up) > 1e-5:
        raise PourPlanError('Scene origin/normal does not match observed tabletop')
    source_up = prior[:3,:3]@up
    target = np.array([0., 0., 1.])
    cosine = source_up@target
    if cosine < .5:
        raise PourPlanError('Camera prior disagrees with observed up by more than 60 degrees')
    v = np.cross(source_up, target)
    skew = np.array([[0,-v[2],v[1]],[v[2],0,-v[0]],[-v[1],v[0],0]])
    correction = np.eye(3)+skew+skew@skew/(1+cosine)
    position = prior[:3,3].copy(); position[2] = -floor
    camera = transform(correction@prior[:3,:3], position)
    result = camera@local
    if abs(result[2,3]-height) > 1e-6:
        raise PourPlanError('Measured height was not preserved by the scene transform')
    return result, dict(horizontalConstraintSource='observed parallel floor/table planes',
        sourceTiltDegrees=angle(source_up,target), tableNormalInModel=result[:3,2].tolist(),
        tableHeightAboveFloorMeters=height, floorHeightInModelMeters=0.,
        modelFromCamera=camera.tolist(), cameraHeightCorrectionMeters=float(position[2]-prior[2,3]),
        observation=observation, modelBaseGravityVerified=False, registrationVerified=False,
        horizontalTranslationAndYawStillEstimated=True, heightSource='observed floor/table separation')
