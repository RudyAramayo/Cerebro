"""Pure pour geometry, rigid payload, fixed schedule and real ghost regressions."""
from pathlib import Path
import sys
import math
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Cerebro/Resources/ShadowPlanner"))
from can_pour import (CanGeometry, CupGeometry, GhostPourRobot, PourPlanError, PourWorkspace,
                      transform, upright_can, geometry_path, geometry_audit,
                      cylinder_bottom, fixed_timed_chain, glass_push_plan,
                      horizontal_table_frame, convex_table_outline)


class PourGeometryTests(unittest.TestCase):
    def setUp(self):
        self.can = CanGeometry(.033, .12, .025)
        self.cup = CupGeometry((.50, .15, .78), .035, .04, .16)
        self.source = upright_can([.50, 0, .68], [0, 1, 0])
        self.tool = transform(np.eye(3), [.50, -.01, .68])

    def test_half_of_half_is_quarter_capacity(self):
        report = self.can.liquid_report()
        self.assertEqual(report['requestedFractionOfCapacity'], .25)
        self.assertEqual(report['finalFractionOfCapacity'], .25)
        self.assertFalse(report['metered'])
        self.assertAlmostEqual(self.can.retained_fraction(self.can.tilt_for_fraction(.25)), .25, places=7)

    def test_cylinder_volume_matches_analytic_full_cross_section(self):
        # Below the first clipped axial slice, the average x over the disk is 0.
        # The integral therefore reduces to 1 - spout_radius*tan(angle)/height.
        for degrees in (1, 10, 20):
            angle = math.radians(degrees)
            # Positive disk x beyond spout is clipped at the can's closed top.
            # Put the opening at the outside lip to remove that clipped region.
            can = CanGeometry(.033, .12, .033)
            self.assertAlmostEqual(can.retained_fraction(angle), 1 - .033 * math.tan(angle) / .12, places=10)
        values = [self.can.retained_fraction(x) for x in np.linspace(0, math.pi/2, 80)]
        self.assertTrue(np.all(np.diff(values) <= 1e-9))

    def test_whole_can_and_tool_pivot_together_and_return_to_support(self):
        path = geometry_path(self.can, self.cup, self.source, self.tool)
        self.assertTrue(geometry_audit(path, self.can, self.cup)['valid'])
        pivots = [s.world_can @ np.r_[self.can.spout, 1] for s in path if s.stage.startswith('Tilt toward')]
        np.testing.assert_allclose(pivots, np.tile(pivots[0], (len(pivots), 1)), atol=1e-9)
        self.assertTrue(all(cylinder_bottom(s.world_can, self.can) >= .805 - 1e-9
                            for s in path if s.stage.startswith('Tilt toward')))
        np.testing.assert_allclose(path[-1].world_can, self.source)
        self.assertFalse(path[-1].attached)
        self.assertIn('support', path[-2].checkpoint)

    def test_bad_direction_and_nonfinite_geometry_rejected(self):
        with self.assertRaises(PourPlanError):
            geometry_path(self.can, self.cup, upright_can([.5, 0, .68], [1, 0, 0]), self.tool)
        for radius in (float('nan'), float('inf'), -.1):
            with self.assertRaises(PourPlanError): CanGeometry(radius, .12, .025)

    def test_fixed_chain_returns_exactly_and_bounds_all_derivatives(self):
        joints = np.zeros((28, 7)); joints[:, 5] = np.linspace(.1, 1.4, 28)
        chain = fixed_timed_chain(joints, hold_seconds=.35)
        self.assertFalse(chain['executable'])
        self.assertFalse(chain['volumeMetered'])
        self.assertLessEqual(chain['peakVelocity'], .30)
        self.assertLessEqual(chain['peakAcceleration'], .60)
        self.assertLessEqual(chain['peakJerk'], 2.)
        self.assertAlmostEqual(chain['uprightRecallAtSeconds'], chain['tiltSeconds'] + .35)
        np.testing.assert_allclose(chain['samples'][0]['rawRadians'], chain['samples'][-1]['rawRadians'], atol=1e-10)
        for s in (chain['samples'][0], chain['samples'][-1]):
            np.testing.assert_allclose(s['velocity'], 0., atol=1e-9)
            np.testing.assert_allclose(s['acceleration'], 0., atol=1e-8)

    def test_post_interpolation_bounds_are_enforced(self):
        joints = np.zeros((8, 7)); joints[:, 6] = [0, 1, 2.09, 2.09, -2.09, -2.09, -1, 0]
        with self.assertRaises(PourPlanError): fixed_timed_chain(joints)

    def test_slide_keeps_entire_glass_supported(self):
        plan = glass_push_plan(self.cup, [[.1, -.2], [.9, .5]], [.5, 1.])
        self.assertEqual(plan['physicalArm'], 'left')
        self.assertLess(plan['contactPoint'][2] - (.78 - .16), .03)
        with self.assertRaises(PourPlanError):
            glass_push_plan(self.cup, [[.1, -.2], [.9, .3]], [.5, 1.], distance=.15)

    def test_horizontal_table_does_not_inherit_camera_mount_tilt(self):
        from scipy.spatial.transform import Rotation
        original=transform(Rotation.from_euler('xyz',[.1,.5,.3]).as_matrix(),[.8,.04,.96])
        corrected,audit=horizontal_table_frame(original)
        np.testing.assert_allclose(corrected[:3,2],[0,0,1],atol=1e-12)
        np.testing.assert_allclose(corrected[:3,3],original[:3,3])
        self.assertGreater(audit['sourceTiltDegrees'],25)
        self.assertFalse(audit['registrationVerified'])
        corners=np.array([[0,0,0,1],[1,0,0,1],[1,1,0,1],[0,1,0,1]])
        np.testing.assert_allclose((corrected@corners.T)[2],.96)

    def test_visible_table_outline_does_not_fill_unobserved_bbox_corners(self):
        outline=convex_table_outline([[0,0],[1,0],[.6,.5],[0,.5]])
        cup=CupGeometry((.8,.30,.16),.032,.038,.16)
        with self.assertRaises(PourPlanError):
            glass_push_plan(cup,[[0,0],[1,.5]],[.8,1.],table_outline_xy=outline)
        with self.assertRaises(PourPlanError):convex_table_outline([[0,0],[1,0],[.4,.1],[0,1]])


class GhostIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.robot = GhostPourRobot(ROOT / 'Cerebro/Resources/ShadowPlanner')

    def status(self):
        return dict(arms={s: dict(q_radians=[0.]*7) for s in ('left','right')},
                    neck=dict(known=True, pan=6000, lower=6011, upper=6400))

    def test_missing_head_pose_cannot_be_replaced_by_reference(self):
        status = self.status(); status['neck']['known'] = False
        with self.assertRaises(PourPlanError): self.robot.from_status(status)

    def test_ik_preserves_other_arm_and_head_and_final_bounds(self):
        q = self.robot.from_status(self.status())
        target = self.robot.frame(q)
        solved, report = self.robot.solve(target, q)
        self.assertTrue(report['solved'])
        np.testing.assert_allclose(solved, q, atol=1e-9)
        self.assertLessEqual(max(abs(x) for x in report['rawRadians']), 2.09)
        target[0, 3] += 3
        _, report = self.robot.solve(target, q)
        self.assertFalse(report['solved'])

    def test_real_hull_overlap_stays_blocked(self):
        q = self.robot.from_status(self.status())
        report = self.robot.engine.clearance.check(q)
        self.assertFalse(report['clear'])
        self.assertLess(report['distance'], 0)

    def test_workspace_includes_other_arm_and_payload_against_head(self):
        q = self.robot.from_status(self.status())
        can = CanGeometry(.033, .12, .025)
        cup = CupGeometry((2.5, 2.5, 1.), .032, .038, .16)
        workspace = PourWorkspace(self.robot, can, cup, [[2,2],[3,3]], 0, np.eye(4))
        self.assertIn(('left_tool','cup_proxy'), workspace.pairs)
        self.assertIn(('can_payload','oak_link'), workspace.pairs)
        self.assertNotIn(('can_payload','right_tool'), workspace.pairs)
        head = self.robot.frame(q, 'oak_link')
        report = workspace.check(q, head)
        self.assertFalse(report['clear'])
        self.assertLess(report['minimumSlackMeters'], 0)

    def test_fast_wrist_does_not_inflate_almost_stationary_shoulder_clearance(self):
        q = self.robot.from_status(self.status())
        q[self.robot.indices[0]] = 2.08 - self.robot.priors['right'][0]
        after=q.copy();after[self.robot.indices[0]]+=.0001;after[self.robot.indices[6]]+=.5
        guard=self.robot.engine.clearance
        slow=('lower_neck_link','right_one_Link')
        fast=('right_tool','oak_link')
        original=guard.pairs
        try:
            # Isolate the two-pair regression. Full-scene baseline overlaps
            # remain covered by the other real-hull regression above.
            guard.pairs=[slow,fast]
            self.assertTrue(guard.check(q)['clear'])
            self.assertTrue(guard.check(after)['clear'])
            self.assertFalse(guard.check((q+after)/2,padding=.004,pairs=[slow])['clear'])
            self.assertTrue(guard.transition(q,after)['clear'])
            with self.assertRaises(ValueError):
                guard.check(q,pairs=[slow],pair_padding={slow:-.01})
        finally: guard.pairs=original


if __name__ == '__main__': unittest.main()
