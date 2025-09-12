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
parser.add_argument("--servo1", type=float, default=0.0, help="Set position of servo 1")
parser.add_argument("--servo2", type=float, default=0.0, help="Set position of servo 2")
parser.add_argument("--servo3", type=float, default=0.0, help="Set position of servo 3")
parser.add_argument("--servo4", type=float, default=0.0, help="Set position of servo 4")
parser.add_argument("--servo5", type=float, default=0.0, help="Set position of servo 5")
parser.add_argument("--servo6", type=float, default=0.0, help="Set position of servo 6")
parser.add_argument("--servo7", type=float, default=0.0, help="Set position of servo 7")
parser.add_argument("--servo8", type=float, default=0.0, help="Set position of servo 8")

parser.add_argument("--ip", type=str, default="10.0.0.5", help="IP (default: %(default)s)")
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

pre_sleep = 0
pre_sleep = 0

servo1 = args.servo1
servo2 = args.servo2
servo3 = args.servo3
servo4 = args.servo4
servo5 = args.servo5
servo6 = args.servo6
servo7 = args.servo7
servo8 = args.servo8

IP_ADDR = args.ip#"10.0.0.5"                           # ROS master's IP address
PORT = args.port

#class robot_joint_position(Structure):              # ctypes struct for send
#    _pack_ = 1                                      # Override Structure align
#    _fields_ = [("cmd_no", c_uint16),
#                ("length", c_uint16),
#                ("counter", c_uint32),
#                ("xyz", c_float * 3),               # ctypes array
#                ("rpy", c_float * 3),
#                ("arm_angle", c_float),
#                ("time", c_float),
#                ]

class robot_joint_position(Structure):                              # ctypes struct for send
    _pack_ = 1                                                      # Override Structure align
    _fields_ = [("cmd_no", c_uint16),                               # Ref:https://docs.python.org/3/library/ctypes.html
                ("length", c_uint16),
                ("counter", c_uint32),
                ("pos0", c_float),
                ("pos1", c_float),
                ("pos2", c_float),
                ("pos3", c_float),
                ("pos4", c_float),
                ("pos5", c_float),
                ("pos6", c_float),
                ("pos7", c_float),
                ("time", c_float),
                ]


#class robot_mode_data(Structure):                   # ctypes struct for receive
#    _pack_ = 1
#    _fields_ = [("cmd_no", c_uint16),
#                ("length", c_uint16),
#                ("counter", c_uint32),
#                ("respond", c_uint8),
#                ]
class robot_mode_data(Structure):                                   # ctypes struct for receive
    _pack_ = 1
    _fields_ = [("cmd_no", c_uint16),
                ("length", c_uint16),
                ("counter", c_uint32),
                ("pos_1", c_float),
                ("pos_2", c_float),
                ("pos_3", c_float),
                ("pos_4", c_float),
                ("pos_5", c_float),
                ("pos_6", c_float),
                ("pos_7", c_float),
                ("pos_8", c_float),
                ("speed_1", c_float),
                ("speed_2", c_float),
                ("speed_3", c_float),
                ("speed_4", c_float),
                ("speed_5", c_float),
                ("speed_6", c_float),
                ("speed_7", c_float),
                ("speed_8", c_float),
                ("X_pos", c_float),
                ("Y_pos", c_float),
                ("Z_pos", c_float),
                ("Roll_pos", c_float),
                ("Pitch_pos", c_float),
                ("Yaw_pos", c_float),
                ("X_speed", c_float),
                ("Y_speed", c_float),
                ("Z_speed", c_float),
                ("Roll_speed", c_float),
                ("Pitch_speed", c_float),
                ("Yaw_speed", c_float),
                ("Arm_Angle", c_float),
                ]






#rad_neg_30_degrees = -0.5236 #neg values bend toward the inside for R11
#rad_neg_45_degrees = -0.7854
#rad_neg_60_degrees = -(rad_neg_30_degrees*2)
#
#rad_30_degrees = 0.5236 #neg values bend toward the inside for R11
#rad_45_degrees = 0.7854
#rad_60_degrees = rad_30_degrees*2

#tmp_1 = robot_joint_position()
#tmp_1.cmd_no = 6
#tmp_1.length = 40
#tmp_1.counter = 114514
#tmp_1.servo1 = servo1
#tmp_1.servo2 = servo2
#tmp_1.servo3 = servo3
#tmp_1.servo4 = servo4
#tmp_1.servo5 = servo5
#tmp_1.servo6 = servo6
#tmp_1.servo7 = servo7
#tmp_1.servo8 = servo8
#tmp_1.time = cmd_time


time.sleep(pre_sleep)

#s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#s.bind(("0.0.0.0", 12321))
#s.sendto(tmp_1, (IP_ADDR, args.port))
#
#data, addr = s.recvfrom(1024)
#print("Receiving: ", data.hex())
#payloadR = robot_mode_data.from_buffer_copy(data)
#print("Received: cmd_no={:d}, length={:d}, "
#      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
#                                          payloadR.length,
#                                          payloadR.counter,
#                                          payloadR.respond, ))

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)                # Standard socket processes
#s.bind(("0.0.0.0", 12321))
payloadS = robot_joint_position(4, 44, 114514,                        # Fill struct for send with numbers
                                servo1, servo2, servo3, servo4, servo5, servo6, servo7, servo8, cmd_time)          # Unit of angle: rad, 1 rad ≈ 57.296°
s.sendto(payloadS, (IP_ADDR, PORT))                                # Default port is 25001
#print("Sending: cmd_no={:d}, "
#      "length={:d}, counter={:d},".format(payloadS.cmd_no,
#                                          payloadS.length,
#                                          payloadS.counter, ))

print("pos0={:f},pos1={:f},pos2={:f},"
      "pos3={:f},pos4={:f},"
      "pos5={:f},pos6={:f},"
      "pos7={:f},time={:f}".format(payloadS.pos0, payloadS.pos1,
                                   payloadS.pos2, payloadS.pos3,
                                   payloadS.pos4, payloadS.pos5,
                                   payloadS.pos6, payloadS.pos7,
                                   payloadS.time))
#data, addr = s.recvfrom(1024)                                       # Need receive return
# #print("Receiving: ", data.hex())
#payloadR = robot_mode_data.from_buffer_copy(data)                   # Convert raw data into ctypes struct to print
# #print("Received: cmd_no={:d}, length={:d}, "
# #      "counter={:d}, respond={:d}".format(payloadR.cmd_no,
# #                                          payloadR.length,
# #                                          payloadR.counter,
# #                                          payloadR.respond, ))


#attempt to get the positions.. but they won't be ready until later

try:
    data, addr = s.recvfrom(1024)
    #print("Receiving: ", data.hex())
    payloadR = robot_mode_data.from_buffer_copy(data)                   # Convert raw data into ctypes struct to print
    #print("Received: cmd_no={:d}, length={:d}, counter={:d}"
    #      .format(payloadR.cmd_no, payloadR.length, payloadR.counter))
    print("pos1={:f} pos2={:f} pos3={:f} pos4={:f} pos5={:f} pos6={:f} pos7={:f} pos8={:f}"
          .format(payloadR.pos_1, payloadR.pos_2, payloadR.pos_3, payloadR.pos_4
                  , payloadR.pos_5, payloadR.pos_6, payloadR.pos_7, payloadR.pos_8,))
    #print("speed1={:f} speed2={:f} speed3={:f} speed4={:f} speed5={:f} speed6={:f} speed7={:f} speed8={:f}"
    #      .format(payloadR.speed_1, payloadR.speed_2, payloadR.speed_3, payloadR.speed_4
    #              , payloadR.speed_5, payloadR.speed_6, payloadR.speed_7, payloadR.speed_8,))
    print("X_pos={:f} Y_pos={:f} Z_pos={:f} R_pos={:f} P_pos={:f} Yaw_pos={:f} X_speed={:f} Y_speed={:f} Z_speed={:f} "
          "Roll_speed={:f} Pitch_speed={:f} Yaw_speed={:f} Arm_Angle={:f}"
          .format(payloadR.X_pos, payloadR.Y_pos, payloadR.Z_pos, payloadR.Roll_pos, payloadR.Pitch_pos,
                  payloadR.Yaw_pos, payloadR.X_speed, payloadR.Y_speed, payloadR.Z_speed, payloadR.Roll_speed,
                  payloadR.Pitch_speed,payloadR.Yaw_speed, payloadR.Arm_Angle))
except socket.timeout:
    print("socket timeout")
