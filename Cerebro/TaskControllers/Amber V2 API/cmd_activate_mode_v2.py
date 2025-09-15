from amber_api.amber_robot import Amber_Robot
import argparse

parser = argparse.ArgumentParser(description="Example of argparse with default values.")

parser.add_argument("--ip", type=str, help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")

args = parser.parse_args()

print(f"ip {args.ip}")
print(f"port {args.port}")

IP_ADDR = args.ip                           # ROS master's IP address
PORT = args.port
# Set joint count
joint_count = 7

arm = Amber_Robot(IP_ADDR, PORT, joint_count=joint_count)
print(f"The robotic arm is now in mode{arm.get_mode()} ")
# Set robot to active Mode
arm.set_active_mode()
# Get status from robot
j_pos, c_pos = arm.get_status()

print(f"Joint Position [1,2,3,4,5,6,7] = {j_pos})")
print(f"Cartesian Position [X,Y,Z,Roll,Pitch,Yaw] = {c_pos}")
print(f"The robotic arm is now in mode{arm.get_mode()} ")
