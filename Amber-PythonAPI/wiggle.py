import time
import amber_api.cmd_4
while True:
    amber_api.cmd_4.move_joint("10.0.0.5",26002,[0,0,0,0,1,0,0,0],3)
    print("Moving to [ 0, 0, 0, 0, 1, 0, 0]")
    time.sleep(4)
    amber_api.cmd_4.move_joint("10.0.0.5",26002,[0,0,0,0,-1,0,0,0],3)
    print("Moving to [ 0, 0, 0, 0,-1, 0, 0]")
    time.sleep(4)
