from amber_api.amber_robot import Amber_Robot
import argparse
import time

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")
parser.add_argument("--servo1", type=float, default=0.0, help="Set position of servo 1")
parser.add_argument("--servo2", type=float, default=0.0, help="Set position of servo 2")
parser.add_argument("--servo3", type=float, default=0.0, help="Set position of servo 3")
parser.add_argument("--servo4", type=float, default=0.0, help="Set position of servo 4")
parser.add_argument("--servo5", type=float, default=0.0, help="Set position of servo 5")
parser.add_argument("--servo6", type=float, default=0.0, help="Set position of servo 6")
parser.add_argument("--servo7", type=float, default=0.0, help="Set position of servo 7")
parser.add_argument("--servo8", type=float, default=0.0, help="Set position of servo 8")

parser.add_argument("--ip", type=str, help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")


args = parser.parse_args()

print(f"cmd_time {args.cmd_time}")
print(f"cmd_sleep {args.cmd_sleep}")
print(f"servo1 {args.servo1}")
print(f"servo2 {args.servo2}")
print(f"servo3 {args.servo3}")
print(f"servo4 {args.servo4}")
print(f"servo5 {args.servo5}")
print(f"servo6 {args.servo6}")
print(f"servo7 {args.servo7}")
print(f"servo8 {args.servo8}")

print(f"ip {args.ip}")
print(f"port {args.port}")

cmd_time = args.cmd_time
cmd_sleep = args.cmd_sleep

servo1 = args.servo1
servo2 = args.servo2
servo3 = args.servo3
servo4 = args.servo4
servo5 = args.servo5
servo6 = args.servo6
servo7 = args.servo7
servo8 = args.servo8

IP_ADDR = args.ip                           # ROS master's IP address
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

#print("Move Joint to [1,1,1,1,1,1,1]")
# Move Joint
j_target = [servo1, servo2, servo3, servo4, servo5, servo6, servo7]  # Joint Position [1,2,3,4,5,6,7]
arm.move_j(j_target, duration=cmd_time)
# Wait until finish
#print("Success?")
#print(arm.wait_for_joint(j_target))  # True = pass, False = timeout
