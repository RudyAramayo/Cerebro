import socket
from ctypes import *
import time
'''
An example for Cartesian control by python

Ref: https://github.com/MrAsana/AMBER_B1_ROS2/wiki/SDK-&-API---UDP-Ethernet-Protocol--for-controlling-&-programing#4-cartesian-control

'''

IP_ADDR = "10.0.0.5"                           # ROS master's IP address


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

tmp_1.xyz[0] = 0.1
tmp_1.xyz[1] = -0.33 #on R11 this is -Y space towards the front of the robot
tmp_1.xyz[2] = 0.2

tmp_1.rpy[0] = 0.0                             # 弧度=57.29578 度
tmp_1.rpy[1] = -1.5                             # 1 rad ≈ 57.296°
tmp_1.rpy[2] = 0.5

#tmp_1.arm_angle = 0.7
tmp_1.time = 2.0

tmp_2 = robot_joint_position()
tmp_2.cmd_no = 6
tmp_2.length = 40

tmp_2.xyz[0] = 0.1
tmp_2.xyz[1] = -0.25 #on R11 this is -Y space towards the front of the robot
tmp_2.xyz[2] = 0.2

tmp_2.rpy[0] = 0                             # 弧度=57.29578 度
tmp_2.rpy[1] = -1.5                             # 1 rad ≈ 57.296°
tmp_2.rpy[2] = 0.75

tmp_2.time = 2.0

tmp_3 = robot_joint_position()
tmp_3.cmd_no = 6
tmp_3.length = 40

tmp_3.xyz[0] = 0.1
tmp_3.xyz[1] = -0.33 #on R11 this is -Y space towards the front of the robot
tmp_3.xyz[2] = 0.1

tmp_3.rpy[0] = 0                             # 弧度=57.29578 度
tmp_3.rpy[1] = -1.5                             # 1 rad ≈ 57.296°
tmp_3.rpy[2] = 1.0

tmp_3.time = 6.0

tmp_4 = robot_joint_position()
tmp_4.cmd_no = 6
tmp_4.length = 40

tmp_4.xyz[0] = 0.1
tmp_4.xyz[1] = -0.33 #on R11 this is -Y space towards the front of the robot
tmp_4.xyz[2] = 0.1

tmp_4.rpy[0] = rad_neg_30_degrees+0.5                             # 弧度=57.29578 度
tmp_4.rpy[1] = -1.2                             # 1 rad ≈ 57.296°
tmp_4.rpy[2] = 1.3

tmp_4.time = 6.0



s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 12321))
s.sendto(tmp_1, (IP_ADDR, 26002))

data, addr = s.recvfrom(1024)
print("Receiving: ", data.hex())
payloadR = robot_mode_data.from_buffer_copy(data)
print("Received: cmd_no={:d}, length={:d}, "
      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
                                          payloadR.length,
                                          payloadR.counter,
                                          payloadR.respond, ))
time.sleep(4)
s.sendto(tmp_2, (IP_ADDR, 26002))
data, addr = s.recvfrom(1024)
print("Receiving: ", data.hex())
payloadR = robot_mode_data.from_buffer_copy(data)
print("Received: cmd_no={:d}, length={:d}, "
      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
                                          payloadR.length,
                                          payloadR.counter,
                                          payloadR.respond, ))

time.sleep(4)
s.sendto(tmp_3, (IP_ADDR, 26002))
data, addr = s.recvfrom(1024)
print("Receiving: ", data.hex())
payloadR = robot_mode_data.from_buffer_copy(data)
print("Received: cmd_no={:d}, length={:d}, "
      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
                                          payloadR.length,
                                          payloadR.counter,
                                          payloadR.respond, ))

time.sleep(8)
s.sendto(tmp_4, (IP_ADDR, 26002))
data, addr = s.recvfrom(1024)
print("Receiving: ", data.hex())
payloadR = robot_mode_data.from_buffer_copy(data)
print("Received: cmd_no={:d}, length={:d}, "
      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
                                          payloadR.length,
                                          payloadR.counter,
                                          payloadR.respond, ))
