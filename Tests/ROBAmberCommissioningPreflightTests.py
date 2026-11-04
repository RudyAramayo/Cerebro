#!/usr/bin/env python3
"""No host or robot I/O: adversarial package and inventory fixtures."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('preflight', ROOT / 'Scripts/amber-commissioning-preflight.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        self.binary = self.root / 'bin/rob-amber-controller'
        self.binary.write_bytes(b'fixture, never executed')
        self.binary.chmod(0o755)
        self.manifest = dict(source_commit='a' * 40, physical_transmit_available=False,
                             files_sha256={'bin/rob-amber-controller': hashlib.sha256(self.binary.read_bytes()).hexdigest()})
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def save(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_package_is_integrity_only(self):
        result = p.verify_package(self.root)
        self.assertEqual(result['verified_files'], ['bin/rob-amber-controller'])
        self.assertFalse(result['physical_transmit_available'])

    def test_modified_binary_rejected(self):
        self.binary.write_bytes(b'modified')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            p.verify_package(self.root)

    def test_path_escape_and_symlink_rejected(self):
        for name in ['../outside', '/etc/passwd', 'bin/../outside', 'bin//extra', 'bin\\extra']:
            with self.subTest(name=name):
                self.manifest['files_sha256'][name] = '0' * 64
                self.save()
                with self.assertRaises(ValueError):
                    p.verify_package(self.root)
                del self.manifest['files_sha256'][name]
        self.save()
        saved = self.root / 'saved'
        self.binary.rename(saved)
        self.binary.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            p.verify_package(self.root)

    def test_bad_commit_transmit_mode_and_permissions_rejected(self):
        for field, value in [('source_commit', 'unknown'), ('physical_transmit_available', True)]:
            previous = self.manifest[field]
            self.manifest[field] = value
            self.save()
            with self.assertRaises(ValueError):
                p.verify_package(self.root)
            self.manifest[field] = previous
        self.save()
        self.binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'not executable'):
            p.verify_package(self.root)

    def host(self):
        return {'processes': [], 'observation_errors': [], 'can_interfaces': [],
                'serial_devices': [], 'recovery_helper': {},
                'vendor_files': {arm: {'sha256': p.VENDOR_SHA256} for arm in ('left', 'right')},
                'rc_local': {'sha256': p.RC_SHA256}}

    def test_empty_inventory_cannot_mint_authority(self):
        report = p.assess(self.host(), p.verify_package(self.root))
        self.assertFalse(report['physical_stream_ready'])
        self.assertFalse(report['inventory_is_authority'])
        codes = {x['code'] for x in report['blockers']}
        self.assertIn('fresh_stationary_feedback_required', codes)
        self.assertIn('physical_ownership_unverified', codes)
        self.assertIn('physical_backend_unavailable', codes)

    def test_live_legacy_serial_recovery_and_namespace_reported(self):
        host = self.host()
        host.update(processes=[{'name': 'amber_core_L', 'pid': 10}],
                    can_interfaces=[{'ifname': 'can10'}],
                    serial_devices=[{'writable_by_audit_user': True}],
                    recovery_helper={'sha256': 'b' * 64})
        codes = {x['code'] for x in p.assess(host, {})['blockers']}
        self.assertTrue({'legacy_cores_running', 'physical_can_visible_in_audit_namespace',
                         'serial_bypass_access', 'recovery_entry_point_present'} <= codes)

    def test_incomplete_inventory_and_baseline_changes_reported(self):
        host = copy.deepcopy(self.host())
        host.update(can_interfaces=None, observation_errors=['denied'], rc_local={})
        host['vendor_files']['right'] = {'sha256': 'c' * 64}
        codes = {x['code'] for x in p.assess(host, {})['blockers']}
        self.assertTrue({'can_inventory_unavailable', 'incomplete_process_observation',
                         'startup_baseline_mismatch', 'vendor_baseline_mismatch_right'} <= codes)


if __name__ == '__main__':
    unittest.main()
