import socket
from ctypes import *
import time
import argparse
'''
An example for Cartesian control by python

Ref: https://github.com/MrAsana/AMBER_B1_ROS2/wiki/SDK-&-API---UDP-Ethernet-Protocol--for-controlling-&-programing#4-cartesian-control

'''

parser = argparse.ArgumentParser(description="Example of argparse with default values.")
parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")
parser.add_argument("--pos_x", type=float, default=0.1, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pos_y", type=float, default=-0.33, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pos_z", type=float, default=0.2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--roll", type=float, default=0.0, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--pitch", type=float, default=-1.5, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--yaw", type=float, default=0.5, help="Time to execute the command (default: %(default)s)")

parser.add_argument("--ip", type=str, default="10.0.0.5", help="IP (default: %(default)s)")
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

pre_sleep = 0
post_sleep = cmd_time + cmd_sleep


position_x = args.pos_x
position_y = args.pos_y
position_z = args.pos_z

rot_r = args.roll
rot_p = args.pitch
rot_y = args.yaw

IP_ADDR = args.ip#"10.0.0.5"                           # ROS master's IP address


class robot_joint_position(Structure):              # ctypes struct for send
    _pack_ = 1                                      # Override Structure align
    _fields_ = [("cmd_no", c_uint16),
                ("length", c_uint16),
                ("counter", c_uint32),
                ("xyz", c_float * 3),               # ctypes array
                ("rpy", c_float * 3),
                ("arm_angle", c_float),
                ("time", c_float),
                ]


class robot_mode_data(Structure):                   # ctypes struct for receive
    _pack_ = 1
    _fields_ = [("cmd_no", c_uint16),
                ("length", c_uint16),
                ("counter", c_uint32),
                ("respond", c_uint8),
                ]
rad_neg_30_degrees = -0.5236 #neg values bend toward the inside for R11
rad_neg_45_degrees = -0.7854
rad_neg_60_degrees = -(rad_neg_30_degrees*2)

rad_30_degrees = 0.5236 #neg values bend toward the inside for R11
rad_45_degrees = 0.7854
rad_60_degrees = rad_30_degrees*2



tmp_1 = robot_joint_position()
tmp_1.cmd_no = 6
tmp_1.length = 40

tmp_1.xyz[0] = position_x#0.1
tmp_1.xyz[1] = position_y#-0.33 #on R11 this is -Y space towards the front of the robot
tmp_1.xyz[2] = position_z#0.2

tmp_1.rpy[0] = rot_r#0.0                             # 弧度=57.29578 度
tmp_1.rpy[1] = rot_p#-1.5                             # 1 rad ≈ 57.296°
tmp_1.rpy[2] = rot_y#0.5

#tmp_1.arm_angle = 0.7
tmp_1.time = cmd_time#2.0

time.sleep(pre_sleep)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 12321))
s.sendto(tmp_1, (IP_ADDR, args.port))

data, addr = s.recvfrom(1024)
print("Receiving: ", data.hex())
payloadR = robot_mode_data.from_buffer_copy(data)
print("Received: cmd_no={:d}, length={:d}, "
      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
                                          payloadR.length,
                                          payloadR.counter,
                                          payloadR.respond, ))
time.sleep(post_sleep)