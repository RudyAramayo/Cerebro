"""Request the hanging joint target without resetting encoder coordinates."""

import argparse
import math
import time

from amber_api.amber_robot import Amber_Robot
from amber_mode_guard import require_position_mode


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cmd_time", type=float, default=2)
parser.add_argument("--cmd_sleep", type=float, default=2)
parser.add_argument("--ip", required=True)
parser.add_argument("--port", type=int, choices=(26001, 26002), default=26002)
args = parser.parse_args()
if not all(math.isfinite(value) for value in (args.cmd_time, args.cmd_sleep)) or args.cmd_time <= 0 or args.cmd_sleep < 0:
    raise SystemExit("Hanging command blocked: duration must be positive and delay nonnegative, both finite")

time.sleep(args.cmd_sleep)
arm = Amber_Robot(args.ip, args.port, joint_count=7)
try:
    require_position_mode(arm)
except RuntimeError as error:
    raise SystemExit(f"Hanging target was not sent. {error}. Use Position + Hold before retrying.") from error

# The old script ignored move_j's Boolean result and exited successfully even
# when a powered-off/active-only controller rejected the zero-position demand.
# Never silently energize the arm, retry a rejected move, or reset its datum.
if not arm.move_j([0.0] * 7, duration=args.cmd_time):
    raise SystemExit("Hanging command rejected or not acknowledged; no retry was sent. Check position mode and arm feedback.")
print("Hanging target acknowledged by controller; this does not verify physical arrival at hanging")
