"""Can-pouring geometry and ghost IK. No transport or hardware output.

The spout is a point attached to the can, not the wrist origin. Angles below
describe a quasi-static liquid envelope, not a metered volume or timing law.
"""
from dataclasses import dataclass
import math
from pathlib import Path
import tempfile

import numpy as np
from scipy.optimize import least_squares, brentq
from scipy.spatial.transform import Rotation
from scipy.interpolate import make_interp_spline, PPoly


class PourPlanError(ValueError):
    pass


def vector(value, size=3):
    result = np.asarray(value, dtype=float)
    if result.shape != (size,) or not np.isfinite(result).all():
        raise PourPlanError("Expected a finite vector of length %d" % size)
    return result


def positive(value, low, high, name):
    if not math.isfinite(value) or not low <= value <= high:
        raise PourPlanError("%s must be in [%g, %g]" % (name, low, high))
    return float(value)


def transform(rotation, position):
    result = np.eye(4)
    result[:3, :3], result[:3, 3] = rotation, vector(position)
    if (not np.isfinite(result).all() or
            not np.allclose(result[:3, :3].T @ result[:3, :3], np.eye(3), atol=1e-8) or
            abs(np.linalg.det(result[:3, :3]) - 1) > 1e-8):
        raise PourPlanError("Invalid rigid transform")
    return result


def rigid(value):
    result = np.asarray(value, float)
    if result.shape != (4, 4) or not np.allclose(result[3], [0, 0, 0, 1]):
        raise PourPlanError("Expected a rigid 4x4 transform")
    return transform(result[:3, :3], result[:3, 3])


def convex_table_outline(value):
    points = np.asarray(value, float)
    if points.ndim != 2 or points.shape[1] != 2 or not 3 <= len(points) <= 64 or not np.isfinite(points).all():
        raise PourPlanError("Invalid visible tabletop outline")
    edges = np.roll(points, -1, axis=0) - points
    area = np.sum(points[:,0] * np.roll(points[:,1],-1) - points[:,1] * np.roll(points[:,0],-1)) / 2
    if area < 0: points = points[::-1].copy(); edges = np.roll(points,-1,axis=0)-points
    turns = edges[:,0]*np.roll(edges[:,1],-1) - edges[:,1]*np.roll(edges[:,0],-1)
    if abs(area) < .001 or np.any(np.linalg.norm(edges,axis=1)<.001) or np.any(turns <= 1e-9):
        raise PourPlanError("Tabletop outline must be a nondegenerate convex polygon")
    return points


def inside_table(point, outline, inset):
    edges = np.roll(outline,-1,axis=0)-outline
    relative = np.asarray(point)-outline
    distances = (edges[:,0]*relative[:,1]-edges[:,1]*relative[:,0])/np.linalg.norm(edges,axis=1)
    return bool(np.all(distances >= inset-1e-9))


@dataclass(frozen=True)
class CanGeometry:
    radius: float
    height: float
    # Radial distance of the LOWEST opening lip, not the pull-tab center.
    spout_radius: float
    initial_fraction: float = .5
    fraction_of_remaining_to_pour: float = .5

    def __post_init__(self):
        positive(self.radius, .015, .060, "can radius")
        positive(self.height, .050, .250, "can height")
        positive(self.spout_radius, 0, self.radius, "opening lip radius")
        positive(self.initial_fraction, .01, 1, "initial fill fraction")
        positive(self.fraction_of_remaining_to_pour, .01, .95, "fraction of remaining liquid")

    @property
    def spout(self):
        return np.array([self.spout_radius, 0., self.height / 2])

    @property
    def desired_fraction(self):
        return self.initial_fraction * self.fraction_of_remaining_to_pour

    @property
    def final_fraction(self):
        return self.initial_fraction - self.desired_fraction

    def retained_fraction(self, tilt):
        """Volume below a horizontal plane through the opening lip.

        Integrate cylinder cross-sections, normalized to the cylinder volume.
        It excludes foam, surface tension, flow lag, can shoulders and venting.
        """
        positive(tilt, 0, math.pi / 2, "tilt")
        if tilt < 1e-10:
            return 1.
        # Gauss-Legendre in angular disk coordinates avoids endpoint sqrt loss.
        nodes, weights = np.polynomial.legendre.leggauss(128)
        alpha = nodes * math.pi / 2
        x = self.radius * np.sin(alpha)
        disk_weights = weights * np.cos(alpha) ** 2  # normalized disk area
        c, s = math.cos(tilt), math.sin(tilt)
        lip_z = self.height / 2 * c - self.spout_radius * s
        if c < 1e-9:
            lengths = np.where(x >= self.spout_radius, 1., 0.)
        else:
            lengths = np.clip((lip_z + x * s) / c + self.height / 2, 0, self.height) / self.height
        return float(np.clip(np.sum(disk_weights * lengths), 0, 1))

    def tilt_for_fraction(self, remaining):
        positive(remaining, .001, 1, "remaining fraction")
        if remaining >= 1:
            return 0.
        if self.retained_fraction(math.pi / 2) > remaining:
            raise PourPlanError("Requested volume cannot be reached within the 90-degree tilt envelope")
        return float(brentq(lambda angle: self.retained_fraction(angle) - remaining, 0, math.pi / 2,
                            xtol=1e-10))

    def liquid_report(self):
        return dict(initialFractionOfCapacity=self.initial_fraction,
                    requestedFractionOfRemaining=self.fraction_of_remaining_to_pour,
                    requestedFractionOfCapacity=self.desired_fraction,
                    finalFractionOfCapacity=self.final_fraction,
                    idealOnsetTiltDegrees=math.degrees(self.tilt_for_fraction(self.initial_fraction)),
                    idealFinalTiltDegrees=math.degrees(self.tilt_for_fraction(self.final_fraction)),
                    metered=False, timedPour=False,
                    note="Static cylinder estimate only. A timed test does not establish volume; foam and flow lag are not modeled.")


@dataclass(frozen=True)
class CupGeometry:
    rim_center: tuple
    inner_radius: float
    outer_radius: float
    height: float

    def __post_init__(self):
        vector(self.rim_center)
        positive(self.inner_radius, .015, .100, "cup inner radius")
        positive(self.outer_radius, self.inner_radius, .120, "cup outer radius")
        positive(self.height, .050, .300, "cup height")


@dataclass
class PourWaypoint:
    stage: str
    world_can: np.ndarray
    world_tool: np.ndarray
    attached: bool
    checkpoint: str | None = None


def upright_can(center, spout_direction):
    direction = vector(spout_direction).copy()
    if abs(direction[2]) > 1e-6 or np.linalg.norm(direction) < 1e-6:
        raise PourPlanError("The upright can needs its observed horizontal opening direction")
    x = direction / np.linalg.norm(direction)
    z = np.array([0., 0., 1.])
    return transform(np.column_stack([x, np.cross(z, x), z]), center)


def tilt_about_spout(world_can_upright, can, tilt, world_spout):
    source = rigid(world_can_upright)
    positive(tilt, 0, math.pi / 2, "tilt")
    # +Y rotation tilts can +Z toward its +X opening direction. There is no yaw.
    rotation = source[:3, :3] @ Rotation.from_rotvec([0, tilt, 0]).as_matrix()
    return transform(rotation, vector(world_spout) - rotation @ can.spout)


def cylinder_bottom(world_can, can):
    pose = rigid(world_can)
    # Exact lowest support point of a cylinder under a rigid transform.
    r = pose[2, :3]
    return float(pose[2, 3] - can.height / 2 * abs(r[2]) - can.radius * math.hypot(r[0], r[1]))


def geometry_path(can, cup, world_can, world_tool_at_grasp, *, rim_clearance=.025,
                  landing_margin=.015, maximum_tilt_step_degrees=3):
    """Rigid can/tool continuation, including grasp verification and return.

    This does not invent an entry from hanging. The caller must solve and
    collision-review that connector from current measured joints separately.
    """
    source, grasp = rigid(world_can), rigid(world_tool_at_grasp)
    positive(rim_clearance, .015, .080, "rim clearance")
    positive(landing_margin, .010, .060, "landing margin")
    positive(maximum_tilt_step_degrees, .5, 5, "tilt sample spacing")
    if landing_margin >= cup.inner_radius:
        raise PourPlanError("Cup opening is smaller than the landing allowance")
    if np.linalg.norm(source[:3, 2] - [0, 0, 1]) > 1e-6:
        raise PourPlanError("The source can must be upright")
    rim = vector(cup.rim_center)
    bearing = rim - source[:3, 3]; bearing[2] = 0
    if np.linalg.norm(bearing) < can.radius + cup.outer_radius:
        raise PourPlanError("Can/cup source geometry overlaps")
    bearing /= np.linalg.norm(bearing)
    yaw_error = math.acos(float(np.clip(bearing @ source[:3, 0], -1, 1)))
    if yaw_error > math.radians(15):
        raise PourPlanError("Opening does not face the cup; reacquire its direction rather than rotate silently")
    tool_in_can = np.linalg.inv(source) @ grasp
    path = []

    def append(stage, pose, attached=True, checkpoint=None):
        pose = rigid(pose)
        path.append(PourWaypoint(stage, pose, pose @ tool_in_can, attached, checkpoint))

    append("Grasp at source", source, False, "Visually confirm both pads surround the can before closing")
    append("Verify jaw closure", source, True, "Jaw ACK is not retention; no force escalation or calibration with the can")
    test_lift = source.copy(); test_lift[2, 3] += .02
    append("Retention test lift", test_lift, True, "Verify the can follows the hand with no slip before carrying")

    # Keep the entire cylinder above the rim during transfer. Wrist/head/world
    # clearance is checked by the independent whole-robot path audit.
    transfer = source.copy()
    transfer[2, 3] = max(test_lift[2, 3], rim[2] + rim_clearance + can.height / 2)
    append("Raise only to computed cup clearance", transfer)
    over = transfer.copy()
    over[:2, 3] = rim[:2] - (over[:3, :3] @ can.spout)[:2]
    append("Position opening over cup", over, True, "Verify opening lies inside the cup and view remains clear")
    end_tilt = can.tilt_for_fraction(can.final_fraction)
    count = max(5, math.ceil(math.degrees(end_tilt) / maximum_tilt_step_degrees))
    # Hold the opening at one point while rotating the can/tool rigidly around
    # it. The upright cylinder is the highest required opening position over
    # this <=90-degree interval: H*cos(theta)+(r-s)*sin(theta) can have an
    # interior maximum, so compute that support maximum analytically.
    peak_angle = min(end_tilt, math.atan2(can.radius - can.spout_radius, can.height))
    opening_height = rim_clearance + can.height * math.cos(peak_angle) + (can.radius - can.spout_radius) * math.sin(peak_angle)
    over[2, 3] = rim[2] + opening_height - can.height / 2
    path[-1].world_can = over
    path[-1].world_tool = over @ tool_in_can
    spout = rim + [0, 0, opening_height]
    for angle in np.linspace(0, end_tilt, count + 1)[1:]:
        pose = tilt_about_spout(source, can, angle, spout)
        append("Tilt toward cup %.2f degrees" % math.degrees(angle), pose, True,
               "Fixed-time estimate; interrupt for rim contact, foam limit, slip, lost view or spill")
    # Recovery is a whole can/tool path, not an isolated J7 amendment or a
    # replacement cmd4 fired during an unfinished trajectory.
    pour_frames = list(path[5:])
    for step in reversed(pour_frames[:-1]):
        append("Controlled upright recovery", step.world_can)
    append("Upright above cup", over, True, "Verify stream has ceased and the can remains retained")
    append("Return above source", transfer)
    append("Return to source support", source, True, "Confirm base contact/support before release")
    append("Release supported can", source, False, "Verify jaws open and the can remains standing")
    return path


class GhostPourRobot:
    """Uses the same pinned URDF and full collision hulls as the ghost worker."""
    def __init__(self, directory, side="right"):
        from worker import ShadowPlanner
        self.engine = ShadowPlanner(directory)
        self.directory = directory
        if side not in ("left", "right"):
            raise PourPlanError("Unknown physical arm")
        self.side = side
        self.indices = self.engine.arm_indices[self.side]
        ref = self.engine.reference["positions"]
        self.priors = {
            "right": -np.array([ref["right_joint%d" % i] for i in range(1, 8)]),
            "left": np.array([0., 2.080432, 0., -.687254, 0., .027043, 0.]),
        }
        self.limit = min(2.09, math.radians(120))
        lower = self.engine.plant.GetPositionLowerLimits()[self.indices]
        upper = self.engine.plant.GetPositionUpperLimits()[self.indices]
        self.lower = np.maximum(lower, -self.limit - self.priors[self.side])
        self.upper = np.minimum(upper, self.limit - self.priors[self.side])

    def from_status(self, status):
        state = status.get("result", status)
        q = self.engine.q0.copy()
        for side in ("left", "right"):
            arm = state["arms"][side]
            raw = vector(arm["q_radians"], 7)
            if np.max(abs(raw)) > self.limit + 1e-8:
                raise PourPlanError("Measured %s arm exceeds the conservative vendor/observed limit" % side)
            q[self.engine.arm_indices[side]] = raw - self.priors[side]
        neck = state["neck"]
        if neck.get("known") is not True:
            raise PourPlanError("Head pose is unknown; an old scan head pose cannot be substituted")
        angles = {"neck_pan": (neck["pan"] - 6000) * math.pi / 6000,
                  "lower_neck": (neck["lower"] - 6011) * math.pi / 6000,
                  "upper_neck": -(neck["upper"] - 6906) * math.pi / 6000}
        for name, value in angles.items():
            q[self.engine.joints[name].position_start()] = value
        if not np.isfinite(q).all():
            raise PourPlanError("Nonfinite full-robot pose")
        return q

    def frame(self, q, name=None):
        p = self.engine
        name = name or self.side + "_tool"
        p.plant.SetPositions(p.context, q)
        return p.plant.CalcRelativeTransform(p.context, p.plant.world_frame(),
                                            p.plant.GetFrameByName(name, p.model)).GetAsMatrix4()

    def solve(self, target, seed):
        target = rigid(target)
        baseline = np.asarray(seed, float).copy()
        initial = baseline[self.indices]
        if not np.isfinite(baseline).all():
            raise PourPlanError("Invalid IK baseline")

        def residual(values):
            q = baseline.copy(); q[self.indices] = values
            actual = self.frame(q)
            rotation_error = Rotation.from_matrix(target[:3, :3] @ actual[:3, :3].T).as_rotvec()
            return np.r_[actual[:3, 3] - target[:3, 3], .18 * rotation_error,
                         .005 * (values - initial)]

        # Deterministic local branch, preserving the other arm/body/head.
        result = least_squares(residual, np.clip(initial, self.lower + 1e-9, self.upper - 1e-9),
                               bounds=(self.lower, self.upper), max_nfev=250,
                               ftol=1e-10, xtol=1e-10, gtol=1e-10)
        q = baseline.copy(); q[self.indices] = result.x
        error = residual(result.x)
        position_error = float(np.linalg.norm(error[:3]))
        angle_error = float(np.linalg.norm(error[3:6]) / .18)
        valid = position_error <= .003 and angle_error <= math.radians(2)
        # Final, post-solver raw limit review is mandatory; no subsequent wrist
        # editing is permitted without solving/reviewing the complete target.
        raw = q[self.indices] + self.priors[self.side]
        valid = bool(valid and np.isfinite(q).all() and np.max(abs(raw)) <= self.limit + 1e-8)
        return q, dict(solved=valid, positionErrorMeters=position_error,
                       orientationErrorDegrees=math.degrees(angle_error), rawRadians=raw.tolist())

    def review(self, before, after):
        # Includes both arms, torso, head and cameras, using CURRENT supplied
        # head/other-arm coordinates instead of the reference pose.
        # Long connectors are reviewed in bounded pieces, rather than treating
        # the worker's per-request sampling budget as a geometric obstruction.
        count = max(1, math.ceil(float(np.max(abs(after-before))) / .15))
        for index in range(count):
            result = self.engine.clearance.transition(before + (after-before)*index/count,
                                                      before + (after-before)*(index+1)/count)
            if not result['clear']: return dict(result, connectorFraction=index/count)
        return result

    def ghost_frames(self, q):
        return self.engine.frame_poses(q)


def fixed_timed_chain(joints, *, hold_seconds=.35, velocity_limit=.30,
                      acceleration_limit=.60, jerk_limit=2., sample_hz=50,
                      raw_limit=2.09):
    """Compile ONE continuous tilt/hold/reverse schedule, without dispatch.

    A quintic clock has zero velocity and acceleration at each hold.
    Polynomial extrema, rather than sampled finite differences, determine
    limits and duration. The return retraces the exact same joint curve.
    This does not convert that curve into overlapping vendor cmd4 requests.
    """
    values = np.asarray(joints, float)
    if values.ndim != 2 or values.shape[1] != 7 or len(values) < 6 or not np.isfinite(values).all():
        raise PourPlanError("Timed chain needs at least six finite seven-joint solutions")
    positive(hold_seconds, 0, 2, "fixed hold seconds")
    positive(velocity_limit, .01, .30, "joint velocity limit")
    positive(acceleration_limit, .01, .60, "joint acceleration limit")
    positive(jerk_limit, .01, 2., "joint jerk limit")
    positive(sample_hz, 10, 200, "sample frequency")
    u = np.linspace(0, 1, len(values))
    # Keep geometric interpolation separate from the clock. Forcing zero
    # derivatives into densely spaced geometric knots produces artificial
    # acceleration spikes at the first/last knot and grossly inflated timing.
    curve = make_interp_spline(u, values, k=5)
    maxima = np.zeros((4, 7))
    for joint in range(7):
        poly = PPoly.from_spline((curve.t, curve.c[:, joint], curve.k))
        for order in range(4):
            derivative = poly.derivative(order)
            roots = derivative.derivative().roots(extrapolate=False)
            locations = np.r_[0., 1., curve.t, roots[np.isfinite(roots)]]
            locations = locations[(locations >= 0) & (locations <= 1)]
            maxima[order, joint] = np.max(abs(derivative(locations)))
    if np.max(maxima[0]) > raw_limit + 1e-9:
        raise PourPlanError("Interpolated curve exceeds final raw joint bounds")
    speed_clock, acceleration_clock, jerk_clock = 1.875, 10 / math.sqrt(3), 60.
    speed = maxima[1] * speed_clock
    acceleration = maxima[2] * speed_clock**2 + maxima[1] * acceleration_clock
    jerk = (maxima[3] * speed_clock**3 + 3 * maxima[2] * speed_clock * acceleration_clock +
            maxima[1] * jerk_clock)
    duration = max(.1, np.max(speed) / velocity_limit,
                   math.sqrt(np.max(acceleration) / acceleration_limit),
                   np.cbrt(np.max(jerk) / jerk_limit)) * 1.001
    records = []
    count = math.ceil(duration * sample_hz)
    for stage, start, reverse in (("tilt", 0., False),
                                  ("return", duration + hold_seconds, True)):
        for i in range(count + 1):
            fraction = i / count
            clock = 10*fraction**3 - 15*fraction**4 + 6*fraction**5
            clock_v = 30*fraction**2 - 60*fraction**3 + 30*fraction**4
            clock_a = 60*fraction - 180*fraction**2 + 120*fraction**3
            parameter = 1 - clock if reverse else clock
            sign = -1 if reverse else 1
            records.append(dict(timeSeconds=start + fraction * duration, stage=stage,
                                rawRadians=curve(parameter).tolist(),
                                velocity=(sign * curve(parameter, 1) * clock_v / duration).tolist(),
                                acceleration=((curve(parameter, 2) * clock_v**2 +
                                    sign * curve(parameter, 1) * clock_a) / duration ** 2).tolist()))
    return dict(schemaVersion=1, hardwareOutputEnabled=False, executable=False,
                requiresCoherentTrajectoryOwner=True, volumeMetered=False,
                tiltSeconds=duration, fixedHoldSeconds=hold_seconds,
                uprightRecallAtSeconds=duration + hold_seconds,
                completeAtSeconds=2 * duration + hold_seconds,
                peakVelocity=float(np.max(speed) / duration),
                peakVelocityByJoint=(speed / duration).tolist(),
                peakAcceleration=float(np.max(acceleration) / duration ** 2),
                peakJerk=float(np.max(jerk) / duration ** 3),
                peakBoundsAreConservative=True,
                peakAbsoluteRawRadians=float(np.max(maxima[0])),
                spline=dict(knots=curve.t.tolist(), coefficients=curve.c.tolist(), degree=curve.k,
                            clockPolynomial=[0, 0, 0, 10, -15, 6]),
                samples=records)


def geometry_audit(path, can, cup, *, rim_clearance=.025):
    """Independent geometry invariants, never proof of physical calibration."""
    rim = vector(cup.rim_center)
    source = path[0].world_can
    opening = source[:3, 0]
    tool_in_can = np.linalg.inv(source) @ path[0].world_tool
    errors = []
    for index, step in enumerate(path):
        if not np.allclose(step.world_can @ tool_in_can, step.world_tool, atol=1e-8):
            errors.append([index, "Can moved relative to gripping tool"])
        if step.stage.startswith("Tilt toward") or step.stage == "Controlled upright recovery":
            p = step.world_can @ np.r_[can.spout, 1]
            if np.linalg.norm(p[:2] - rim[:2]) > 1e-8:
                errors.append([index, "Opening leaves the cup center"])
            if cylinder_bottom(step.world_can, can) < rim[2] + rim_clearance - 1e-8:
                errors.append([index, "Can enters protected cup-rim plane"])
            horizontal_axis = step.world_can[:3, 2].copy(); horizontal_axis[2] = 0
            if np.linalg.norm(horizontal_axis) > 1e-6 and horizontal_axis @ opening < 0:
                errors.append([index, "Can tilts away from original opening direction"])
    return dict(valid=not errors, errors=errors, hardwareOutputEnabled=False,
                worldAndRobotClearanceIncluded=False)


def glass_push_plan(cup, table_bounds_xy, toward_xy, *, distance=.08, edge_margin=.06, table_outline_xy=None):
    """Low contact point and supported straight slide, geometry only.

    Friction, actual pad contact, ice/slosh and glass strength are unmeasured.
    The other arm must be independently solved and reviewed after the pour.
    """
    bounds = np.asarray(table_bounds_xy, float)
    if bounds.shape != (2, 2) or not np.isfinite(bounds).all() or np.any(bounds[1] <= bounds[0]):
        raise PourPlanError("A measured tabletop support rectangle is required")
    positive(distance, .01, .15, "slide distance")
    positive(edge_margin, .04, .20, "table edge margin")
    start = vector(cup.rim_center)[:2]
    toward = vector(toward_xy, 2) - start
    if np.linalg.norm(toward) < .01:
        raise PourPlanError("Recipient direction is unresolved")
    direction = toward / np.linalg.norm(toward)
    end = start + direction * distance
    inset = cup.outer_radius + edge_margin
    outline = convex_table_outline(table_outline_xy if table_outline_xy is not None else
        [bounds[0], [bounds[1][0],bounds[0][1]], bounds[1], [bounds[0][0],bounds[1][1]]])
    if not all(inside_table(point,outline,inset) for point in (start,end)):
        raise PourPlanError("Slide would leave the supported tabletop margin")
    base_z = cup.rim_center[2] - cup.height
    contact_height = min(.025, cup.height * .2)
    contact = start - direction * cup.outer_radius
    return dict(physicalArm="left", startCenterXY=start.tolist(), endCenterXY=end.tolist(),
                contactPoint=[*contact, base_z + contact_height], directionXY=direction.tolist(),
                distanceMeters=distance, speedMetersPerSecond=.015,
                requireCanSupportedAndRightArmClear=True, executable=False,
                tipThresholdFrictionRatio=cup.outer_radius / contact_height,
                note="Unmeasured friction/contact and liquid slosh; support geometry alone is not push clearance.")


class PourWorkspace:
    """Full scan hulls against table/cup/can proxies in the SAME model frame.

    This is a diagnostic for supplied geometry. It never establishes measured
    registration or complete observation of the room/open gripper envelope.
    """
    def __init__(self, robot, can, cup, table_bounds_xy, table_z, model_from_scene, table_outline_xy=None):
        from pydrake.geometry import (SceneGraph, GeometryFrame, GeometryInstance,
                                      ProximityProperties, Convex, Cylinder)
        from pydrake.math import RigidTransform
        self.robot, self.can, self.cup = robot, can, cup
        self.model_from_scene = rigid(model_from_scene)
        bounds = np.asarray(table_bounds_xy, float)
        if bounds.shape != (2, 2) or not np.isfinite(bounds).all() or np.any(bounds[1] <= bounds[0]):
            raise PourPlanError("Invalid table proxy")
        if not math.isfinite(table_z): raise PourPlanError("Invalid table height")
        self.table_z = table_z
        self.graph = SceneGraph()
        self.source = self.graph.RegisterSource('pour-workspace-diagnostic')
        self.frames, self.ids, self.static = {}, {}, {}

        def add(name, shape, pose=None):
            frame = self.graph.RegisterFrame(self.source, GeometryFrame(name))
            gid = self.graph.RegisterGeometry(self.source, frame,
                GeometryInstance(RigidTransform(), shape, name))
            self.graph.AssignRole(self.source, gid, ProximityProperties())
            self.frames[name], self.ids[name] = frame, gid
            if pose is not None: self.static[name] = pose

        for surface in robot.engine.clearance.surfaces:
            add(surface['link'], Convex(str(robot.directory / surface['hull'])))
        outline = convex_table_outline(table_outline_xy if table_outline_xy is not None else
            [bounds[0], [bounds[1][0],bounds[0][1]], bounds[1], [bounds[0][0],bounds[1][1]]])
        self.table_outline = outline
        self._table_mesh_directory = tempfile.TemporaryDirectory(prefix='rob-pour-table-')
        table_mesh = Path(self._table_mesh_directory.name) / 'visible-table.obj'
        count = len(outline)
        lines = ['v %.12g %.12g %.12g' % (x,y,z) for z in (table_z-.06,table_z) for x,y in outline]
        faces = [[1,i+2,i+1] for i in range(1,count-1)] + [[count+1,count+i+1,count+i+2] for i in range(1,count-1)]
        for i in range(count):
            j=(i+1)%count; faces += [[i+1,j+1,count+j+1],[i+1,count+j+1,count+i+1]]
        table_mesh.write_text('\n'.join(lines + ['f '+' '.join(map(str,face)) for face in faces])+'\n')
        add('table_proxy', Convex(str(table_mesh)), self.model_from_scene)
        add('cup_proxy', Cylinder(cup.outer_radius, cup.height),
            self.model_from_scene @ transform(np.eye(3), vector(cup.rim_center) - [0, 0, cup.height/2]))
        add('can_payload', Cylinder(can.radius, can.height))
        self.context = self.graph.CreateDefaultContext()
        arm_names = [x for x in self.frames if robot.engine.clearance.is_arm(x)]
        self.pairs = [(a, b) for a in arm_names for b in ('table_proxy','cup_proxy')]
        self.pairs += [('can_payload', a) for a in robot.engine.clearance.frames
                       if a != robot.side + '_tool']
        self.pairs += [('can_payload', 'table_proxy'), ('can_payload', 'cup_proxy')]

    def check(self, q, scene_can, *, padding=0, supported=False, robot_pose=None, whole_robot=False):
        from pydrake.geometry import FramePoseVector
        from pydrake.math import RigidTransform
        poses = FramePoseVector()
        for name, frame in self.frames.items():
            if name == 'can_payload': pose = self.model_from_scene @ rigid(scene_can)
            elif name in self.static: pose = self.static[name]
            else:
                pose = self.robot.frame(q, name)
                if robot_pose is not None: pose = rigid(robot_pose)@pose
            poses.set_value(frame, RigidTransform(pose))
        self.graph.get_source_pose_port(self.source).FixValue(self.context, poses)
        query = self.graph.get_query_output_port().Eval(self.context)
        minimum, nearest, clear, slack, blocker = math.inf, None, True, math.inf, None
        pairs=self.pairs
        if whole_robot:
            pairs=pairs+[(name,obstacle) for name in self.frames
                if name not in self.static and name!='can_payload' and not self.robot.engine.clearance.is_arm(name)
                for obstacle in ('table_proxy','cup_proxy')]
        for a, b in pairs:
            distance = float(query.ComputeSignedDistancePairClosestPoints(self.ids[a], self.ids[b]).distance)
            if not math.isfinite(distance): raise PourPlanError("Nonfinite workspace distance")
            required = .015 + padding
            if (a, b) == ('can_payload', 'table_proxy') and supported:
                # Only the can base's intended source support is admitted.
                # Arm/table and can/cup checks are never exempted.
                required = -.001
            if distance < minimum: minimum, nearest = distance, [a, b]
            if distance - required < slack: slack, blocker = distance - required, [a, b]
            clear = clear and distance >= required
        return dict(clear=bool(clear), minimumDistanceMeters=minimum, nearestPair=nearest,
                    minimumSlackMeters=slack, limitingPair=blocker,
                    ordinaryRequiredMeters=.015 + padding, completeWorldObserved=False,
                    gripperOpeningMeasured=False, registrationVerified=False)

    def transition(self, before, after, can_in_tool, source_can, *, attached, supported=False):
        delta = abs(after - before)
        travel = max((sum(delta[i] * lever for i, lever in levers.items())
                      for levers in self.robot.engine.clearance.levers.values()), default=0)
        if attached:
            extent = np.linalg.norm(can_in_tool[:3, 3]) + self.can.radius + self.can.height / 2
            travel = max(travel, sum(delta[i] * (lever + extent)
                                    for i, lever in self.robot.engine.clearance.levers[self.robot.side + '_tool'].items()))
        count = max(1, math.ceil(travel / .008))
        if count > 500: return dict(clear=False, reason='Workspace sweep budget exceeded')
        for u, padding in [(0, 0), (1, 0)] + [((i+.5)/count, travel/(2*count)) for i in range(count)]:
            q = before + u * (after-before)
            scene_can = (np.linalg.inv(self.model_from_scene) @ self.robot.frame(q) @ can_in_tool
                         if attached else source_can)
            result = self.check(q, scene_can, padding=padding,
                                supported=supported and cylinder_bottom(scene_can, self.can) >= self.table_z - .001)
            if not result['clear']: return dict(result, fraction=u)
        return result

    def review_timed_curve(self, chain, baseline, can_in_tool):
        """Review the actual compiled curve, including interpolation overshoot.

        Samples are covered by a conservative point-travel radius from the
        proven joint-speed bound. Static self conflicts remain a separate
        prerequisite, and are not erased by checking only moving pairs here.
        """
        robot = self.robot
        samples = chain['samples']
        dt = max((b['timeSeconds']-a['timeSeconds'] for a,b in zip(samples,samples[1:])
                  if a['stage'] == b['stage']), default=0)
        moving = set(robot.indices)
        pairs = [(a,b) for a,b in robot.engine.clearance.pairs
                 if moving.intersection(set(robot.engine.clearance.levers[a]) | set(robot.engine.clearance.levers[b]))]
        speeds = {joint: chain['peakVelocityByJoint'][index] for index,joint in enumerate(robot.indices)}
        # Nearest sample is at most dt/2 away; sum individual point velocities
        # for a pair. Shared ancestry could tighten this, but is not needed.
        link_speed = {name: sum(speeds[i] * value for i,value in levers.items() if i in moving)
                      for name,levers in robot.engine.clearance.levers.items()}
        def relative_speed(a,b):
            aa,bb=robot.engine.clearance.levers[a],robot.engine.clearance.levers[b]
            return sum(speeds[i] * max(aa.get(i,0),bb.get(i,0)) for i in moving
                       if not (i in aa and i in bb))
        self_padding = {(a,b): relative_speed(a,b) * dt/2 for a,b in pairs}
        extent = np.linalg.norm(can_in_tool[:3,3]) + self.can.radius + self.can.height/2
        payload_speed = link_speed[robot.side+'_tool'] + sum(speeds.values()) * extent
        world_padding = (max(link_speed.values(), default=0) + payload_speed) * dt/2
        checked, max_opening_error = 0, 0.
        for sample in samples:
            q = baseline.copy()
            q[robot.indices] = np.array(sample['rawRadians']) - robot.priors[robot.side]
            scene_can = np.linalg.inv(self.model_from_scene) @ robot.frame(q) @ can_in_tool
            spout = scene_can @ np.r_[self.can.spout, 1]
            opening_error = float(np.linalg.norm(spout[:2] - vector(self.cup.rim_center)[:2]))
            max_opening_error = max(max_opening_error, opening_error)
            self_result = robot.engine.clearance.check(q, pairs=pairs, pair_padding=self_padding)
            world_result = self.check(q, scene_can, padding=world_padding)
            checked += 1
            if not self_result['clear'] or not world_result['clear'] or opening_error > self.cup.inner_radius-.015:
                return dict(clear=False, checkedSamples=checked, firstFailureTimeSeconds=sample['timeSeconds'],
                            selfClearance=self_result, worldClearance=world_result,
                            openingErrorMeters=opening_error, maximumOpeningErrorMeters=max_opening_error,
                            hardwareOutputEnabled=False)
        return dict(clear=True, checkedSamples=checked, maximumOpeningErrorMeters=max_opening_error,
                    staticSelfConflictsMustAlsoPass=True, hardwareOutputEnabled=False)
