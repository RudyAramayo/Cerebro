from amber_api.amber_robot import Amber_Robot
import argparse
import time

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
#parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
#parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")

parser.add_argument("--ip", type=str, help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")


args = parser.parse_args()

#print(f"cmd_time {args.cmd_time}")
#print(f"cmd_sleep {args.cmd_sleep}")

print(f"ip {args.ip}")
print(f"port {args.port}")

#cmd_time = args.cmd_time
#cmd_sleep = args.cmd_sleep

#time.sleep(cmd_sleep)

# Set joint count
joint_count = 7

arm = Amber_Robot(args.ip, args.port, joint_count=joint_count)
arm.gripper_calibrate()
