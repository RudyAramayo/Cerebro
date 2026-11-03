#!/usr/bin/env python3
"""Exercise the Linux executable ONLY inside the hosted virtual-CAN fixture."""
import argparse
import json
import math
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time


class VirtualArm:
    def __init__(self, interface):
        self.bus = socket.socket(socket.AF_CAN, socket.SOCK_RAW | socket.SOCK_NONBLOCK, socket.CAN_RAW)
        # Include EFF/RTR discrimination but NOT CAN_ERR_FLAG. Including the
        # error bit routes a filter to the kernel's error-frame receive list.
        self.bus.setsockopt(socket.SOL_CAN_RAW, socket.CAN_RAW_FILTER,
                            b''.join(struct.pack('=II', j, 0xC00007FF) for j in range(0x11, 0x18)))
        self.bus.bind((interface,))
        self.positions = [b'\0\0'] * 7
        self.frames = 0
        self.error = None
        self.done = threading.Event()
        self.feedback = True
        self.thread = threading.Thread(target=self.loop)
        self.thread.start()

    def loop(self):
        try:
            next_feedback = 0
            while not self.done.is_set():
                while select.select([self.bus], [], [], 0)[0]:
                    identifier, length, data = struct.unpack('=IB3x8s', self.bus.recv(16))
                    assert 0x11 <= identifier <= 0x17 and length == 3 and data[0] == 0x40
                    self.positions[identifier - 0x11] = data[1:3]
                    self.frames += 1
                if self.feedback and time.monotonic() >= next_feedback:
                    for joint, position in enumerate(self.positions):
                        data = b'\x01' + position + b'\0\0\0\0\x02'
                        self.bus.send(struct.pack('=IB3x8s', 0x91 + joint, 8, data))
                    next_feedback = time.monotonic() + .01
                self.done.wait(.001)
        except BaseException as error:
            self.error = error

    def close(self):
        self.done.set()
        self.thread.join(2)
        self.bus.close()
        if self.error:
            raise self.error


def receive(client):
    return json.loads(client.recv(8192))


def scenario(binary, interface, action):
    scenario_started = time.monotonic()
    arm = VirtualArm(interface)
    process = None
    client = None
    try:
        with tempfile.TemporaryDirectory(prefix='rob-arm-fixture-') as directory:
            runtime = Path(directory) / 'session'
            process = subprocess.Popen([str(binary), '--virtual-fixture', '--interface', interface,
                                        '--runtime-dir', str(runtime), '--duration', '2.5'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if not select.select([process.stdout], [], [], 4)[0]:
                raise AssertionError('runtime startup did not complete')
            ready_line = process.stdout.readline()
            if not ready_line:
                raise AssertionError(process.stderr.read())
            ready = json.loads(ready_line)
            assert ready['event'] == 'ready' and ready['interface_kind'] == 'vcan'
            client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            client.settimeout(2)
            client.connect(str(runtime / 'control.sock'))
            hello = receive(client)
            token = hello['nonce']
            assert hello['virtual_fixture'] and len(token) == 32
            time.sleep(.3)  # accumulate independent fresh stationary samples
            assert arm.frames == 0, 'no publication before explicit fixture start'
            sequence = 0
            generation = 0

            def command(op, **extra):
                message = dict(op=op, nonce=token, generation=generation, created_ns=time.monotonic_ns())
                message.update(extra)
                client.send(json.dumps(message).encode())
                return receive(client)

            started = command('start')
            assert started['accepted'], started
            generation = started['generation']
            last = None
            for tick in range(45):
                sequence += 1
                last = command('target', sequence=sequence, position=[.45 * math.sin(.5 + tick * .01)] * 7)
                assert last['accepted'], last
                time.sleep(.01)
            assert arm.frames > 100 and abs(last['commanded_velocity'][0]) > .01, (arm.frames, arm.error, last)
            if action == 'disconnect':
                client.close()
                client = None
            elif action == 'stop':
                stop_reply = command('stop')
                assert stop_reply['accepted'], (stop_reply, time.monotonic() - scenario_started)
                assert not command('target', sequence=sequence + 1, position=[0] * 7)['accepted']
            elif action == 'replay':
                assert not command('target', sequence=sequence, position=[0] * 7)['accepted']
                assert not command('target', sequence=sequence + 1, position=[0] * 7,
                                   created_ns=time.monotonic_ns() - 250000000)['accepted']
                assert not command('stop', generation=generation + 1)['accepted']
                stop_reply = command('stop')
                assert stop_reply['accepted'], (stop_reply, time.monotonic() - scenario_started)
            elif action == 'nonce':
                client.send(json.dumps(dict(op='stop', nonce='0' * 32, generation=generation,
                                            created_ns=time.monotonic_ns())).encode())
                assert client.recv(8192) == b'', 'wrong nonce connection is closed'
            elif action == 'oversized':
                client.send(b'x' * 4096)
                assert client.recv(8192) == b'', 'oversized packet connection is closed'
            elif action == 'duplicate':
                packet = json.dumps(dict(op='stop', nonce=token, generation=generation, created_ns=time.monotonic_ns()))
                client.send(('{"op":"heartbeat",' + packet[1:]).encode())
                assert client.recv(8192) == b'', 'duplicate top-level key is malformed'
            elif action == 'signal':
                process.send_signal(signal.SIGTERM)
            elif action == 'feedback_loss':
                arm.feedback = False
                # Maintain input until the hardware-feedback timeout must fault.
                for _ in range(30):
                    if process.poll() is not None:
                        break
                    try:
                        command('heartbeat')
                    except (BrokenPipeError, ConnectionResetError, json.JSONDecodeError):
                        break
                    time.sleep(.01)
            else:
                raise AssertionError(action)
            output, error = process.communicate(timeout=6)
            records = [json.loads(line) for line in output.splitlines() if line.strip()]
            final = records[-1]
            assert final['event'] == 'final', (output, error)
            status = final['status']
            assert not status['physical_transmit_available']
            assert status['backend_accepted_frames'] == status['boundary_accepted_frames'] > 100
            if action == 'feedback_loss':
                assert process.returncode == 3 and status['mode'] == 'fault' and not status['shutdown_complete'], status
                assert status['boundary_fault'] == 5, status  # BoundaryFault::Feedback
            else:
                assert process.returncode == 0 and status['mode'] == 'held' and status['shutdown_complete'], (status, error)
                assert all(abs(x) < 1e-9 for x in status['commanded_velocity']), status
            assert not runtime.exists(), 'private socket and directory removed after exit'
            return {'test': action, 'passed': True, 'status': status, 'virtual_frames': arm.frames}
    finally:
        if client is not None:
            client.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=2)
        arm.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--interface', required=True)
    args = parser.parse_args()
    if os.environ.get('ROB_ISOLATED_VCAN_TEST') != '1':
        raise SystemExit('Explicit isolated virtual fixture required')
    links = json.loads(subprocess.check_output(['ip', '-details', '-json', 'link', 'show'], text=True))
    target = [x for x in links if x['ifname'] == args.interface]
    if len(target) != 1 or target[0].get('linkinfo', {}).get('info_kind') != 'vcan':
        raise SystemExit('Kernel-verified virtual CAN required before simulator socket creation')
    if any(x.get('link_type') == 'can' and x.get('linkinfo', {}).get('info_kind') != 'vcan' for x in links):
        raise SystemExit('Physical CAN interface present: refuse test')
    binary = args.binary.resolve()
    info = json.loads(subprocess.check_output([str(binary), '--self-check'], text=True))
    assert info['hardware_io'] is False and info['physical_transmit_available'] is False
    print(json.dumps({'test': 'no_io_self_check_and_no_physical_transmit_capability', 'passed': True}), flush=True)
    for action in ['disconnect', 'stop', 'replay', 'nonce', 'oversized', 'duplicate', 'signal', 'feedback_loss']:
        print(json.dumps(scenario(binary, args.interface, action)), flush=True)
    print(json.dumps({'passed': 9, 'failed': 0, 'robot_io': False, 'virtual_CAN_io': True}))


if __name__ == '__main__':
    main()
