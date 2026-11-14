#!/usr/bin/env python3
"""Saved-image parity and timing benchmark. No robot or network interfaces."""
import argparse
import json
from pathlib import Path
import socket
import statistics
import sys
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-directory',type=Path,default=Path.home()/'Library/Application Support/Cerebro/WorkspaceDetector/model')
    parser.add_argument('--images',nargs='+',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--repeats',type=int,default=3)
    args=parser.parse_args()
    if not 1<=args.repeats<=20:parser.error('repeats must be 1-20')
    def denied(*a,**kw):raise RuntimeError('Network access prohibited in offline benchmark')
    socket.create_connection=denied;socket.socket.connect=denied;socket.getaddrinfo=denied
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Cerebro/Resources/ShadowPlanner'))
    from workspace_detector import Detector
    start=time.monotonic();detector=Detector(str(args.model_directory));load_s=time.monotonic()-start
    records=[]
    for path in args.images:
        jpeg=path.read_bytes()
        baseline=detector.detect(jpeg,cached_text=False)
        cached=detector.detect(jpeg,cached_text=True)
        if len(baseline['candidates'])!=len(cached['candidates']):raise RuntimeError('Candidate counts changed')
        maximum=0
        for a,b in zip(baseline['candidates'],cached['candidates']):
            if (a['target'],a['query'])!=(b['target'],b['query']):raise RuntimeError('Candidate identity/order changed')
            maximum=max(maximum,abs(a['score']-b['score']),*(abs(x-y) for x,y in zip(a['box'],b['box'])))
        if maximum>1e-5:raise RuntimeError(f'Detection parity failed: {maximum}')
        timings={False:[],True:[]}
        for repeat in range(args.repeats):
            for mode in ([False,True] if repeat%2==0 else [True,False]):
                timings[mode].append(detector.detect(jpeg,cached_text=mode)['inference_ms'])
        records.append(dict(image=str(path.resolve()),candidates=len(cached['candidates']),
                            maximum_absolute_output_difference=maximum,baseline_ms=statistics.median(timings[False]),
                            cached_ms=statistics.median(timings[True]),samples=timings))
        print(json.dumps(records[-1]),flush=True)
    result=dict(network_denied=True,hardware_interfaces_used=False,device=detector.device,load_s=load_s,records=records)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()
