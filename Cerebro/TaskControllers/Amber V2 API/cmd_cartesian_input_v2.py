from amber_api.amber_robot import Amber_Robot
import argparse

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")
parser.add_argument("--pos_x", type=float, default=0.1, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pos_y", type=float, default=-0.33, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pos_z", type=float, default=0.2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--roll", type=float, default=0.0, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pitch", type=float, default=-1.5, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--yaw", type=float, default=0.5, help="Time to execute the command (default: %(default)s)")


parser.add_argument("--ip", type=str, help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")


args = parser.parse_args()

print(f"cmd_time {args.cmd_time}")
print(f"cmd_sleep {args.cmd_sleep}")
print(f"pos_x {args.pos_x}")
print(f"pos_y {args.pos_y}")
print(f"pos_z {args.pos_z}")
print(f"roll {args.roll}")
print(f"pitch {args.pitch}")
print(f"yaw {args.yaw}")

print(f"ip {args.ip}")
print(f"port {args.port}")

cmd_time = args.cmd_time
cmd_sleep = args.cmd_sleep

position_x = args.pos_x
position_y = args.pos_y
position_z = args.pos_z

rot_r = args.roll
rot_p = args.pitch
rot_y = args.yaw

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

#print("Move Cartesian coordinates")
# Move Cartesian coordinates
c_target = [pos_x, pos_y, pos_z, roll, pitch, yaw]  # Cartesian Position [X,Y,Z,Roll,Pitch,Yaw]
#print("Is inverse kinematics correct?")
arm.move_c(c_target, duration=3)
#print()
# Wait until finish
#print("Success?")
#print(arm.wait_for_cartesian(c_target))  # True = pass, False = timeout
