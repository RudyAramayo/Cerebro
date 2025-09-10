from amber_api.amber_robot import Amber_Robot
import argparse
import time

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
#parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
#parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")

parser.add_argument("--force", type=int, default=10, help="Gripper force (default: %(default)s)")

parser.add_argument("--ip", type=str, default="10.0.0.5", help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="Port (default: %(default)s)")


args = parser.parse_args()

#print(f"cmd_time {args.cmd_time}")
#print(f"cmd_sleep {args.cmd_sleep}")

print(f"ip {args.ip}")
print(f"port {args.port}")
print(f"force {args.force}")


#cmd_time = args.cmd_time
#cmd_sleep = args.cmd_sleep
force = args.force

# Set joint count
joint_count = 7

#time.sleep(cmd_sleep)

arm = Amber_Robot(args.ip, args.port, joint_count=joint_count)
#0 = open gripper
arm.gripper_ctrl(action=0,force=args.force)
