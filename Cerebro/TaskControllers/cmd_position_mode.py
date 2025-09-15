import random
import socket
from ctypes import *
import time
import argparse

'''
A simple example for controlling a single joint move once by python

Ref: https://github.com/MrAsana/AMBER_B1_ROS2/wiki/SDK-&-API---UDP-Ethernet-Protocol--for-controlling-&-programing#2-single-joint-move-once
C++ version:  https://github.com/MrAsana/C_Plus_API/tree/master/amber_gui_4_node
     
'''
parser = argparse.ArgumentParser(description="Example of argparse with default values.")
parser.add_argument("--cmd_time", type=float, default=2, help="Time to execute the command (default: %(default)s)")
parser.add_argument("--cmd_sleep", type=float, default=2, help="Time to sleep after command execution (default: %(default)s)")

parser.add_argument("--ip", type=str, help="IP (default: %(default)s)")
parser.add_argument("--port", type=int, default=26002, help="IP (default: %(default)s)")


args = parser.parse_args()

print(f"cmd_time {args.cmd_time}")
print(f"cmd_sleep {args.cmd_sleep}")

print(f"ip {args.ip}")
print(f"port {args.port}")

cmd_time = args.cmd_time
cmd_sleep = args.cmd_sleep

pre_sleep = 0

class robot_cmd(Structure):  # ctypes struct for send
    _pack_ = 1  # Override Structure align
    _fields_ = [("cmd_no", c_uint16),  # Ref:https://docs.python.org/3/library/ctypes.html
                ("length", c_uint16),
                ("counter", c_uint32),
                ("mode", c_uint16),  # Ref:https://docs.python.org/3/library/ctypes.html

                ]


class robot_data(Structure):  # ctypes struct for receive
    _pack_ = 1
    _fields_ = [("cmd_no", c_uint16),
                ("length", c_uint16),
                ("counter", c_uint32),
                ("respond", c_uint8),
                ]


def set_mode(mode, IP_ADDR="10.0.0.5", PORT=26002):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)  # Standard socket processes
    payloadS = robot_cmd(10, 10, random.randint(0, 2147483647), mode)  # Fill struct for send with numbers
    s.sendto(payloadS, (IP_ADDR, PORT))  # Default port is 26001
    s.settimeout(3)
    try:
        data, addr = s.recvfrom(1024)  # Need receive return
        payloadR = robot_data.from_buffer_copy(data)  # Convert raw data into ctypes struct to print
        #print("Received: cmd_no={:d}, length={:d}, counter={:d}"
            .format(payloadR.cmd_no, payloadR.length, payloadR.counter))
        print("pos1={:f} pos2={:f} pos3={:f} pos4={:f} pos5={:f} pos6={:f} pos7={:f} pos8={:f}"
            .format(payloadR.pos_1, payloadR.pos_2, payloadR.pos_3, payloadR.pos_4
                    , payloadR.pos_5, payloadR.pos_6, payloadR.pos_7, payloadR.pos_8,))
        #print("speed1={:f} speed2={:f} speed3={:f} speed4={:f} speed5={:f} speed6={:f} speed7={:f} speed8={:f}"
        #    .format(payloadR.speed_1, payloadR.speed_2, payloadR.speed_3, payloadR.speed_4
        #            , payloadR.speed_5, payloadR.speed_6, payloadR.speed_7, payloadR.speed_8,))
        print("X_pos={:f} Y_pos={:f} Z_pos={:f} R_pos={:f} P_pos={:f} Yaw_pos={:f} X_speed={:f} Y_speed={:f} Z_speed={:f} "
                "Roll_speed={:f} Pitch_speed={:f} Yaw_speed={:f} Arm_Angle={:f}"
            .format(payloadR.X_pos, payloadR.Y_pos, payloadR.Z_pos, payloadR.Roll_pos, payloadR.Pitch_pos,
                    payloadR.Yaw_pos, payloadR.X_speed, payloadR.Y_speed, payloadR.Z_speed, payloadR.Roll_speed,
                    payloadR.Pitch_speed,payloadR.Yaw_speed, payloadR.Arm_Angle))
        return payloadR.respond
    except socket.timeout:
        return False

time.sleep(pre_sleep)

#| Mode | inactive | Active | Position | Speed | Current |
#| ---- | -------- | ------ | -------- | ----- | ------- |
#| Code | 0        | 1      | 2        | 3     | 4       |

set_mode(2, IP_ADDR=args.ip, PORT=args.port)
