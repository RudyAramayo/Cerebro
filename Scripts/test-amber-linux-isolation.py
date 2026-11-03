#!/usr/bin/env python3
"""Run disposable hosted-Linux virtual CAN tests. Never connects to a robot."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess


def run(args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=60).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--summary', required=True, type=Path)
    args = parser.parse_args()
    if os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit('Requires a disposable GitHub-hosted runner; not a robot or workstation')
    interface, namespace = 'robci0', 'rob-arm-ci'
    links = json.loads(run(['ip', '-details', '-json', 'link', 'show']))
    if any(x.get('link_type') == 'can' or x.get('ifname') == interface for x in links):
        raise SystemExit('Refusing a host with an existing CAN interface')
    if namespace in run(['ip', 'netns', 'list']):
        raise SystemExit('Fixture namespace already exists')
    created = False
    link_created = False
    moved = False
    old_socket = None
    try:
        run(['sudo', 'ip', 'netns', 'add', namespace]); created = True
        run(['sudo', 'ip', 'link', 'add', interface, 'type', 'vcan']); link_created = True
        run(['sudo', 'ip', 'link', 'set', interface, 'up'])
        old_socket = socket.socket(socket.AF_CAN, socket.SOCK_RAW | socket.SOCK_NONBLOCK, socket.CAN_RAW)
        old_socket.bind((interface,))
        run(['sudo', 'ip', 'link', 'set', interface, 'netns', namespace]); moved = True
        run(['sudo', 'ip', '-n', namespace, 'link', 'set', interface, 'up'])
        # Crucially exercise the descriptor opened BEFORE the namespace move.
        # The packet is for a virtual interface only, with no physical devices.
        old_send_error = None
        try:
            old_socket.send(struct.pack('=IB3x8s', 0x123, 1, b'\0' * 8))
        except OSError as error:
            old_send_error = error.errno
        if old_send_error not in (errno.ENODEV, errno.ENXIO, errno.ENETDOWN):
            raise RuntimeError(f'Old namespace socket was not excluded: errno={old_send_error}')
        with socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW) as new_socket:
            try:
                new_socket.bind((interface,))
            except OSError as error:
                new_bind_error = error.errno
            else:
                raise RuntimeError('Host namespace can still bind the moved virtual interface')
        output = run(['sudo', 'ip', 'netns', 'exec', namespace, 'env', 'ROB_ISOLATED_VCAN_TEST=1', str(args.binary.resolve()), interface])
        records = [json.loads(line) for line in output.splitlines() if line.strip()]
        report = {'robot_io': False, 'virtual_CAN_io': True, 'old_socket_send_errno': old_send_error,
                  'new_host_bind_errno': new_bind_error, 'tests': records,
                  'git_commit': os.environ.get('GITHUB_SHA'),
                  'scope': 'Disposable hosted runner and virtual CAN only; physical slcan transfer remains uncommissioned'}
        root = Path(__file__).resolve().parents[1]
        sources = ['Tools/ContinuousArm/SocketCanTransport.hpp', 'Tools/ContinuousArm/SocketCanTransport.cpp',
                   'Tools/ContinuousArm/ReceiveClock.hpp', 'Tools/ContinuousArm/ReceiveClock.cpp',
                   'Tests/ROBAmberLinuxTransportTests.cpp', 'Scripts/test-amber-linux-isolation.py']
        report['source_sha256'] = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources}
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
    finally:
        if old_socket is not None:
            old_socket.close()
        if created:
            run(['sudo', 'ip', 'netns', 'delete', namespace])
        if link_created and not moved:
            # Remove only our new fixture, never an existing interface.
            names = [x['ifname'] for x in json.loads(run(['ip', '-json', 'link', 'show']))]
            if interface in names:
                run(['sudo', 'ip', 'link', 'delete', interface])


if __name__ == '__main__':
    main()
