#!/usr/bin/env python3
"""Rebuild a saved pour scene from inspected RGB-D floor/table regions.

No camera or actuator access. Raw captures stay outside the repository.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'Cerebro/Resources/ShadowPlanner'))
from can_pour import GhostPourRobot, convex_table_outline, transform
from table_planes import backproject, region_points, fit_parallel_planes, floor_anchored_scene, unit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--observations', type=Path, required=True)
    parser.add_argument('--scene-template', type=Path, required=True)
    parser.add_argument('--status', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    meta = json.loads((args.capture/'metadata.json').read_text())
    marks = json.loads(args.observations.read_text())
    scene = json.loads(args.scene_template.read_text())
    shape = meta['depth']['height'], meta['depth']['width']
    depth = np.fromfile(args.capture/'depth-u16le.raw', dtype='<u2').reshape(shape)
    points = backproject(depth, meta['intrinsics'])
    imu = meta['imu']
    if not imu['stationary']:
        raise ValueError('Capture must be stationary for floor/table observation')
    imu_up = unit(np.asarray(imu['imu_to_rgb_rotation']).reshape(3,3)@np.asarray(imu['gravity_mps2']))
    fit = fit_parallel_planes(region_points(points, marks['floorRegions']),
                              region_points(points, marks['tableRegions']), imu_up)
    n = np.asarray(fit['upOptical']); offset = fit['tableOffsetOpticalMeters']
    intr = meta['intrinsics']
    def on_plane(pixel, height=0):
        x, y = pixel
        ray = np.array([(x-intr['cx'])/intr['fx'], (y-intr['cy'])/intr['fy'], 1.])
        distance = (offset+height)/(n@ray)
        if not .2 < distance < 3: raise ValueError('Invalid boundary ray intersection')
        return ray*distance
    rim = region_points(points, [marks['canRimRegion']])
    if len(rim) < 20: raise ValueError('Can rim depth is unavailable')
    rim_point = np.median(rim, axis=0)
    base = rim_point+n*(offset-n@rim_point)
    # Image-left front corner to image-right front corner; scene Y is left.
    front_left, front_right = [on_plane(p) for p in marks['frontEdgePixels']]
    y = unit(front_left-front_right)
    x = unit(np.cross(y,n)); y = np.cross(n,x)
    camera_from_scene = transform(np.column_stack([x,y,n]),base)
    def local(p): return camera_from_scene[:3,:3].T@(p-base)
    cup = local(on_plane(marks['cupRimPixel'], scene['cup']['height']))
    outline = convex_table_outline([local(on_plane(p))[:2] for p in marks['visibleBoundaryPixels']])
    robot = GhostPourRobot(ROOT/'Cerebro/Resources/ShadowPlanner')
    q = robot.from_status(json.loads(args.status.read_text()))
    prior = robot.frame(q, 'oak_optical_frame')
    corrected, audit = floor_anchored_scene(prior, camera_from_scene, fit)
    scene.pop('modelFromScene',None)
    scene['modelFromCameraPrior'] = prior.tolist()
    scene['cameraFromScene'] = camera_from_scene.tolist()
    scene['floorTableObservation'] = fit
    scene['cup']['rim_center'] = cup.tolist()
    scene['canCenter'] = [0,0,scene['can']['height']/2]
    toward = cup.copy(); toward[2] = 0
    scene['openingDirection'] = unit(toward).tolist()
    scene['tableOutlineXY'] = outline.tolist()
    scene['tableBoundsXY'] = [outline.min(axis=0).tolist(),outline.max(axis=0).tolist()]
    scene['tableZ'] = 0
    scene['evidence'] = dict(fixture='2026-10-31 paired floor/table saved scene',
        registrationVerified=False, heightSource=fit['method'],
        dimensions='66x120mm can and 25mm lip assumed; transparent glass rim uses assumed 154.6mm height',
        worldCompleteness='Visible tabletop patch only; unseen extent and base corridor unknown',
        horizontalTranslationAndYaw='Unverified camera/model prior; not an arm calibration',
        observedCanRimAboveTableMeters=float(n@rim_point-offset),
        inspectedImageAnnotations=marks,
        captureSequence=meta['sequence'],
        captureHashes={name:hashlib.sha256((args.capture/name).read_bytes()).hexdigest()
                       for name in ('rgb.jpg','depth-u16le.raw','metadata.json')})
    args.output.write_text(json.dumps(scene,indent=2,allow_nan=False)+'\n')
    print(json.dumps(dict(observation=fit, modelFromScene=corrected.tolist(),
        cameraHeightCorrectionMeters=audit['cameraHeightCorrectionMeters'],
        observedCanRimAboveTableMeters=scene['evidence']['observedCanRimAboveTableMeters']),indent=2))


if __name__ == '__main__': main()
