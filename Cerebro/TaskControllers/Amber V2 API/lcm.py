lcm_recv_channel = "Amber_ArmStatus"
lcm_send_channel = "Amber_PosCmd"
import time
import socket
import asyncio
import concurrent.futures
import lcm
from datetime import datetime

from lcmTypes.armStatus_t import armStatus_t
        
record_list = []
#await UDP_CMD.cmd_10.currentMode()
from lcmTypes.armStatus_t import armStatus_t

async def recorder(q: Q):
    def my_handler(channel, data):
        msg = armStatus_t.decode(data)
        print("Received message on channel \"%s\"" % channel)
        
        tmp = [msg.jointPosition[0],msg.jointPosition[1],msg.jointPosition[2],msg.jointPosition[3],msg.jointPosition[4],msg.jointPosition[5],msg.jointPosition[6]]
        print("   position    = %s" % str(tmp))
        record_list.append(tmp)
    lc = lcm.LCM()
    subscription = lc.subscribe(lcm_recv_channel, my_handler)

    while True:
            if(param.isRecording == False):
                await UDP_CMD.cmd_10.initPositionMode()
                return
            lc.handle()
            await q.sleep(0.05)


asyncio.ensure_future(recorder(q))
