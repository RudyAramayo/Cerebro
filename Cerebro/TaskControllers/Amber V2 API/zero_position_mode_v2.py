from amber_api.amber_robot import Amber_Robot
import argparse
import time

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")

parser.add_argument("--ip", type=str, default="10.0.0.5", help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")


args = parser.parse_args()

print(f"cmd_time {args.cmd_time}")
print(f"cmd_sleep {args.cmd_sleep}")

print(f"ip {args.ip}")
print(f"port {args.port}")

cmd_time = args.cmd_time
cmd_sleep = args.cmd_sleep


servo1 = 0
servo2 = 0
servo3 = 0
servo4 = 0
servo5 = 0
servo6 = 0
servo7 = 0
servo8 = 0

IP_ADDR = args.ip#"10.0.0.5"                           # ROS master's IP address
PORT = args.port
# Set joint count
joint_count = 7

time.sleep(cmd_sleep)

arm = Amber_Robot(IP_ADDR, PORT, joint_count=joint_count)
print(f"The robotic arm is now in mode{arm.get_mode()} ")

# Get status from robot
j_pos, c_pos = arm.get_status()

print(f"Joint Position [1,2,3,4,5,6,7] = {j_pos})")
print(f"Cartesian Position [X,Y,Z,Roll,Pitch,Yaw] = {c_pos}")
print(f"The robotic arm is now in mode{arm.get_mode()} ")

#print("Move Joint to [0, 0, 0, 0, 0, 0, 0]")
# Move Joint
j_target = [0, 0, 0, 0, 0, 0, 0]  # Joint Position [1,2,3,4,5,6,7]
arm.move_j(j_target, duration=cmd_time)
# Wait until finish
#print("Success?")
#print(arm.wait_for_joint(j_target))  # True = pass, False = timeout

# I am not using this as the control of the duration is not specifiable...
#print("Move Joint to Zero")
#arm.move_zero()
#arm.wait_for_joint([0, 0, 0, 0, 0, 0, 0])
