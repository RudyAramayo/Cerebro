#!/usr/bin/env python3
"""Read-only Amber deployment inventory. Never grants motion or changes the host.

No CAN/UDP sockets, sudo, recovery calls, service changes or password reads.
Results describe a point-in-time observation, not an exclusive ownership lease.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import time

VENDOR_SHA256 = '554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100'
RC_SHA256 = '2369a9576604b945df2c8bb4913967430ea0d3790eca196102ecdbdc5ebe37b9'
ROUTES = {'right': ('can10', '/home/amber/L-10/amber_core_L'),
          'left': ('can11', '/home/amber/R-11/amber_core_R')}


def file_record(path):
    try:
        p = Path(path)
        s = p.lstat()
        if not stat.S_ISREG(s.st_mode):
            return {'path': str(p), 'error': 'not a regular file'}
        return {'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                'size': s.st_size, 'mode': oct(stat.S_IMODE(s.st_mode)), 'uid': s.st_uid}
    except OSError as error:
        return {'path': str(path), 'error': type(error).__name__}


def verify_package(directory):
    root = Path(directory)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('package must be an existing nonsymlink directory')
    manifest = root / 'manifest.json'
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size > 1048576:
        raise ValueError('invalid manifest')
    data = json.loads(manifest.read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', data.get('source_commit', '')):
        raise ValueError('invalid source commit')
    if data.get('physical_transmit_available') is not False:
        raise ValueError('only the receive-only commissioning release is supported')
    files = data.get('files_sha256')
    if not isinstance(files, dict) or not files or len(files) > 64:
        raise ValueError('invalid file manifest')
    if 'bin/rob-amber-controller' not in files:
        raise ValueError('missing controller')
    verified = []
    for name, expected in sorted(files.items()):
        parts = PurePosixPath(name)
        if parts.is_absolute() or str(parts) != name or '..' in parts.parts or '\\' in name:
            raise ValueError('unsafe manifest path')
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('invalid hash')
        current = root
        for part in parts.parts:
            current /= part
            if current.is_symlink():
                raise ValueError('symlink in package')
        record = file_record(current)
        if record.get('sha256') != expected:
            raise ValueError('package hash mismatch: ' + name)
        if name.startswith('bin/') and not (current.stat().st_mode & stat.S_IXUSR):
            raise ValueError('packaged binary is not executable')
        verified.append(name)
    # This is self-consistency, not signature/authenticity verification. The
    # deployment caller must pin the archive hash from the verified CI artifact.
    return {'source_commit': data['source_commit'], 'manifest': file_record(manifest),
            'verified_files': verified, 'physical_transmit_available': False,
            'scope': 'Manifest self-consistency; trusted archive hash checked separately'}


def command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5,
                                env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
        return {'returncode': result.returncode, 'stdout': result.stdout[:32768],
                'error': result.stderr[:500]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'returncode': None, 'error': type(error).__name__}


def inventory():
    if platform.system() != 'Linux':
        raise ValueError('host inventory requires Linux; no remote connection is made')
    processes = []
    errors = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            name = (entry / 'comm').read_text().strip()
            if name in ('amber_core_L', 'amber_core_R', 'slcand', 'rob-amber-contr'):
                processes.append({'pid': int(entry.name), 'name': name,
                                  'threads': len(list((entry / 'task').iterdir())),
                                  'network_namespace': os.readlink(entry / 'ns/net')})
        except FileNotFoundError:
            continue  # process exited during a read-only observation
        except (PermissionError, OSError):
            errors.append('process observation unavailable: ' + entry.name)
    links = command(['ip', '-details', '-statistics', '-json', 'link', 'show'])
    can = None
    if links['returncode'] == 0:
        can = [item for item in json.loads(links['stdout']) if item.get('link_type') == 'can']
    serial = []
    for entry in sorted(Path('/dev/serial/by-id').glob('*')):
        try:
            target = entry.resolve(strict=True)
            s = target.stat()
            serial.append({'by_id': entry.name, 'device': str(target),
                           'uid': s.st_uid, 'gid': s.st_gid, 'mode': oct(stat.S_IMODE(s.st_mode)),
                           'writable_by_audit_user': os.access(target, os.W_OK)})
        except OSError as error:
            serial.append({'by_id': entry.name, 'error': type(error).__name__})
    units = {}
    for unit in ('rc-local.service', 'rob-amber-gateway.service'):
        raw = command(['systemctl', 'show', unit, '--property=LoadState,ActiveState,SubState,MainPID,Restart,UnitFileState'])
        units[unit] = (dict(line.split('=', 1) for line in raw['stdout'].splitlines() if '=' in line)
                       if raw['returncode'] == 0 else {'error': raw['error']})
    return {'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'kernel': platform.release(), 'architecture': platform.machine(),
            'uid': os.getuid(), 'network_namespace': os.readlink('/proc/self/ns/net'),
            'sampled_monotonic_ns': time.monotonic_ns(), 'processes': processes,
            'observation_errors': errors, 'can_interfaces': can,
            'can_query_error': links.get('error') if can is None else None,
            'serial_devices': serial, 'units': units,
            'vendor_files': {arm: file_record(path) for arm, (_, path) in ROUTES.items()},
            'rc_local': file_record('/etc/rc.local'),
            'recovery_helper': file_record('/usr/local/sbin/rob-amber-recover'),
            'namespace_pins': sorted(p.name for p in Path('/run/netns').glob('*'))}


def assess(host, package):
    blockers = []
    cores = [p for p in host['processes'] if p['name'] in ('amber_core_L', 'amber_core_R')]
    if cores:
        blockers.append({'code': 'legacy_cores_running', 'detail': 'Vendor controllers remain active; no exclusive replacement ownership.'})
    if host['observation_errors']:
        blockers.append({'code': 'incomplete_process_observation', 'detail': 'Some processes could not be inspected.'})
    if host['can_interfaces'] is None:
        blockers.append({'code': 'can_inventory_unavailable', 'detail': 'No valid CAN interface inventory.'})
    else:
        names = {x['ifname'] for x in host['can_interfaces']}
        if {'can10', 'can11'} & names:
            blockers.append({'code': 'physical_can_visible_in_audit_namespace', 'detail': 'CAN remains reachable from this namespace; socket bind/flock would not prove sole ownership.'})
    if any(x.get('writable_by_audit_user') for x in host['serial_devices']):
        blockers.append({'code': 'serial_bypass_access', 'detail': 'Audit user can write a serial device; raw device access must be included in the ownership design.'})
    if host['recovery_helper'].get('sha256'):
        blockers.append({'code': 'recovery_entry_point_present', 'detail': 'Recovery helper remains installed; its restart authority must be coordinated with cutover.'})
    for arm, record in host['vendor_files'].items():
        if record.get('sha256') != VENDOR_SHA256:
            blockers.append({'code': 'vendor_baseline_mismatch_' + arm, 'detail': 'Original core differs from the verified backup or is unreadable.'})
    if host['rc_local'].get('sha256') != RC_SHA256:
        blockers.append({'code': 'startup_baseline_mismatch', 'detail': 'Startup file differs from the recorded baseline or is unreadable.'})
    # No inventory or JSON flag can establish any of these live conditions.
    for code, detail in (
        ('physical_backend_unavailable', 'This candidate supports passive physical observation and virtual output only.'),
        ('fresh_stationary_feedback_required', 'Obtain fresh all-joint feedback in the morning; quiet CAN is not a pose or power-state measurement.'),
        ('joint_profile_uncommissioned', 'Confirm native lift axis/sign, limits and mode/status semantics; rehearsal values are simulation settings.'),
        ('physical_clearance_review_required', 'Review the actual empty-arm sweep, other arm and surroundings. No head/camera geometry is assumed.'),
        ('independent_stop_unmeasured', 'Operator reports the present failure stops motion; firmware timeout, torque retention and supported-arm stop still need measurement.'),
        ('physical_ownership_unverified', 'Real slcan isolation, blocked legacy/recovery entry points and old serial/adapter traffic still need commissioning.'),
        ('testing_paused_for_sleep', 'No activation, mode change, core restart, CAN cutover or motion until Rudy resumes testing.')):
        blockers.append({'code': code, 'detail': detail})
    return {'schema': 'rob-amber-commissioning-preflight/1', 'read_only': True,
            'physical_stream_ready': False, 'inventory_is_authority': False,
            'package': package, 'host': host, 'blockers': blockers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = assess(inventory(), verify_package(args.package))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({'read_only': True, 'physical_stream_ready': False,
                          'inventory_error': str(error)}))
        return 1
    print(json.dumps(result, indent=2))
    return 0  # successful inventory; not permission to run motors


if __name__ == '__main__':
    sys.exit(main())
