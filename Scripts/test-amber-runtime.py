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


def observe_without_start(binary, interface):
    arm = VirtualArm(interface)
    arm.positions[0] = b'\x12\x34'
    try:
        with tempfile.TemporaryDirectory(prefix='rob-arm-passive-') as directory:
            result = subprocess.run([str(binary), '--virtual-fixture', '--interface', interface,
                                     '--runtime-dir', str(Path(directory) / 'session'), '--duration', '.4'],
                                    text=True, capture_output=True, timeout=4)
            assert result.returncode == 0, result.stderr
            final = json.loads(result.stdout.splitlines()[-1])
            assert final['status']['mode'] == 'observing' and final['status']['shutdown_complete']
            assert final['status']['backend_accepted_frames'] == 0 and arm.frames == 0
            observations = final['raw_joint_observations']
            assert len(observations) == 7 and all(x is not None for x in observations)
            assert observations[0]['position_native_counts'] == 0x1234
            assert observations[0]['data'][1:3] == [0x12, 0x34]
            assert all(0 <= x['age_at_report_ns'] < 200000000 for x in observations)
            assert final['status']['commanded_position'] == [0] * 7, 'raw receipt is not a commanded/calibrated pose'
            return {'test': 'raw_observation_before_any_grant_has_zero_transmission', 'passed': True}
    finally:
        arm.close()


def scenario(binary, interface, action):
    scenario_started = time.monotonic()
    arm = VirtualArm(interface)
    process = None
    client = None
    try:
        with tempfile.TemporaryDirectory(prefix='rob-arm-fixture-') as directory:
            runtime = Path(directory) / 'session'
            process = subprocess.Popen([str(binary), '--virtual-fixture', '--interface', interface,
                                        '--runtime-dir', str(runtime), '--duration', '4'],
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
            assert last['mode'] == 'following', 'action must exercise its own stop trigger, not earlier expiry'
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
                expected_reason = ('Stop' if action in ('stop', 'replay') else
                                   'Shutdown' if action == 'signal' else 'ClientDisconnected')
                assert status['reason_name'] == expected_reason, (action, status)
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


def target_switching(binary, interface):
    """Small initial move, then 12 finite reversals through the actual IPC path."""
    arm = VirtualArm(interface)
    process = None
    client = None
    try:
        with tempfile.TemporaryDirectory(prefix='rob-retarget-') as directory:
            runtime = Path(directory) / 'session'
            process = subprocess.Popen([str(binary), '--virtual-fixture', '--interface', interface,
                                        '--runtime-dir', str(runtime), '--duration', '12'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            assert select.select([process.stdout], [], [], 4)[0], 'startup timeout'
            ready = json.loads(process.stdout.readline())
            assert ready['interface_kind'] == 'vcan'
            client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            client.settimeout(2)
            client.connect(str(runtime / 'control.sock'))
            hello = receive(client)
            assert hello['virtual_fixture'] is True
            time.sleep(.3)
            generation = 0
            sequence = 0

            def command(op, **extra):
                packet = dict(op=op, nonce=hello['nonce'], generation=generation,
                              created_ns=time.monotonic_ns(), **extra)
                client.send(json.dumps(packet).encode())
                return receive(client)

            started = command('start')
            assert started['accepted']
            generation = started['generation']
            last = started
            reversals = 0
            previous_direction = 0
            moving_changes = 0
            peak_velocity = 0

            def send_target(angle):
                nonlocal sequence, last, reversals, previous_direction, peak_velocity
                q = [0.] * 7
                q[1] = angle
                sequence += 1
                last = command('target', sequence=sequence, position=q)
                assert last['accepted'] and last['generation'] == generation, last
                assert last['mode'] == 'following', last
                assert len(list(Path(f'/proc/{process.pid}/task').iterdir())) == 1, 'one owner thread throughout retargets'
                assert all(abs(x) < 1e-10 for i, x in enumerate(last['commanded_position']) if i != 1)
                velocity = last['commanded_velocity'][1]
                peak_velocity = max(peak_velocity, abs(velocity))
                direction = 1 if velocity > .001 else -1 if velocity < -.001 else 0
                if direction and previous_direction and direction != previous_direction:
                    reversals += 1
                if direction:
                    previous_direction = direction
                time.sleep(.01)

            # Arrival of an ideal synthetic plant; never physical arrival proof.
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                send_target(math.radians(5))
                if abs(last['commanded_position'][1] - math.radians(5)) < .0002 and abs(last['commanded_velocity'][1]) < 1e-8:
                    break
            else:
                raise AssertionError('initial simulated move did not settle')
            legs = []
            for leg in range(12):
                if abs(last['commanded_velocity'][1]) > .001:
                    moving_changes += 1
                angle = math.radians(5 if leg % 2 else 2)
                direction = 1 if leg % 2 else -1
                start_position = last['commanded_position'][1]
                # Trigger by observed motion, not a timer that can land near a
                # zero-velocity crossing on differently scheduled runners.
                deadline = time.monotonic() + 1.5
                while time.monotonic() < deadline:
                    send_target(angle)
                    velocity = last['commanded_velocity'][1]
                    position = last['commanded_position'][1]
                    if direction * velocity > .02 and (leg != 0 or start_position - position > .01):
                        assert abs(position - angle) > .005, 'reverse well before target completion'
                        legs.append(dict(leg=leg, sequence=sequence, position=position, velocity=velocity, target=angle))
                        break
                else:
                    raise AssertionError(('no bounded moving-switch point', leg, last))
            assert moving_changes == 11 and reversals >= 11, (moving_changes, reversals)
            assert command('stop')['accepted']
            assert not command('target', sequence=sequence + 1, position=[0] * 7)['accepted']
            output, error = process.communicate(timeout=6)
            final = json.loads(output.splitlines()[-1])['status']
            assert process.returncode == 0 and final['mode'] == 'held' and final['reason_name'] == 'Stop', (final, error)
            assert final['generation'] == generation == 1 and final['accepted_targets'] == sequence
            assert final['replans'] >= 12 and final['received_target_sequence'] == sequence
            assert final['backend_accepted_frames'] == final['boundary_accepted_frames'] > 1000
            assert not runtime.exists()
            return dict(test='finite_small_move_then_twelve_mid_motion_retargets', passed=True,
                        mid_motion_changes=moving_changes, velocity_reversals=reversals,
                        peak_velocity_rad_s=peak_velocity, final_status=final,
                        owner_threads=1, legs=legs, feedback='synthetic ideal virtual CAN plant')
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
    print(json.dumps(observe_without_start(binary, args.interface)), flush=True)
    for action in ['disconnect', 'stop', 'replay', 'nonce', 'oversized', 'duplicate', 'signal', 'feedback_loss']:
        print(json.dumps(scenario(binary, args.interface, action)), flush=True)
    print(json.dumps(target_switching(binary, args.interface)), flush=True)
    print(json.dumps({'passed': 11, 'failed': 0, 'robot_io': False, 'virtual_CAN_io': True}))


if __name__ == '__main__':
    main()
