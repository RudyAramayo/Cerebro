#!/usr/bin/env python3
"""Stage a verified Linux commissioning artifact. Never install or contact Amber."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PIN = '7de6b1035e1cad509251b31b3287d10fbcda6baf'


def run(args):
    return subprocess.check_output(args, text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--ruckig-source', required=True, type=Path)
    parser.add_argument('--portable-results', required=True, type=Path)
    parser.add_argument('--linux-results', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    if os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit('Packaging executes only on the disposable hosted build runner')
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise SystemExit('Package requires the Linux x86_64 build target, never the robot')
    if run(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=no']).strip():
        raise SystemExit('Package only a clean committed source tree')
    source = args.ruckig_source.resolve()
    if run(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip() != PIN or run(
            ['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no']).strip():
        raise SystemExit('Unmodified pinned Ruckig source required')
    commit = run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip()
    portable = json.loads(args.portable_results.read_text())
    native = json.loads(args.linux_results.read_text())
    if portable['sanitizer'] != 'none' or native['git_commit'] != commit:
        raise SystemExit('Release validation must match this commit')
    for report in [portable, native]:
        for name, expected in report['source_sha256'].items():
            if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
                raise SystemExit('Validation source mismatch: ' + name)
    expected_counts = {'wire_codec_tests': 8, 'driver_boundary_tests': 11,
                       'receive_clock_tests': 4, 'session_tests': 11}
    if portable['tests'][-1]['groups'] != 19 or portable['tests'][-1]['result'] != 'pass':
        raise SystemExit('Trajectory validation missing')
    for field, count in expected_counts.items():
        if portable[field][-1]['passed'] != count or portable[field][-1]['failed']:
            raise SystemExit('Validation missing: ' + field)
    if (native['tests'][-1]['passed'] != 8 or native['tests'][-1]['failed'] or
            native['runtime_tests'][-1]['passed'] != 9 or native['runtime_tests'][-1]['failed']):
        raise SystemExit('Native transport and executable validation required')
    binary = args.build_dir.resolve() / 'rob-amber-controller'
    raw = binary.read_bytes()
    if hashlib.sha256(raw).hexdigest() != native['runtime_binary_sha256']:
        raise SystemExit('Candidate binary differs from the process-tested executable')
    if raw[:6] != b'\x7fELF\x02\x01' or int.from_bytes(raw[18:20], 'little') != 62:
        raise SystemExit('Expected ELF64 little-endian x86_64')
    info = json.loads(run([str(binary), '--self-check']))
    if info['physical_transmit_available'] or info['hardware_io']:
        raise SystemExit('Only default-off commissioning artifact can be packaged')
    dynamic = run(['readelf', '--dynamic', str(binary)])
    needed = re.findall(r'Shared library: \[(.*?)\]', dynamic)
    if any('asan' in x or 'ubsan' in x or 'tsan' in x for x in needed):
        raise SystemExit('Do not package sanitizer executable for deployment')
    versions = sorted(set(re.findall(r'\b(?:GLIBC|GLIBCXX|CXXABI|GCC)_[0-9.]+',
                                    run(['readelf', '--version-info', str(binary)]))))
    interpreter = re.findall(r'Requesting program interpreter: ([^\]]+)\]',
                             run(['readelf', '--program-headers', str(binary)]))
    if len(interpreter) != 1:
        raise SystemExit('Expected one explicit Linux ELF interpreter')
    glibc = [tuple(map(int, x.split('_', 1)[1].split('.'))) for x in versions if x.startswith('GLIBC_')]
    if max(glibc, default=(0,)) > (2, 35):
        raise SystemExit('Candidate exceeds observed Amber glibc 2.35 ABI')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'bin').mkdir()
    (output / 'licenses').mkdir()
    (output / 'validation').mkdir()
    shutil.copy2(binary, output / 'bin/rob-amber-controller')
    shutil.copy2(source / 'LICENSE', output / 'licenses/Ruckig-LICENSE')
    shutil.copy2(source / 'third_party/json/LICENSE', output / 'licenses/nlohmann-json-LICENSE')
    shutil.copy2(ROOT / 'Tools/ContinuousArm/DEPLOYMENT.md', output / 'DEPLOYMENT.md')
    shutil.copy2(ROOT / 'Tools/ContinuousArm/rob-amber-observe@.service.example', output / 'rob-amber-observe@.service.example')
    shutil.copy2(args.portable_results, output / 'validation/portable.json')
    shutil.copy2(args.linux_results, output / 'validation/linux.json')
    manifest = {'source_commit': commit, 'ruckig_commit': PIN, 'binary_abi': 'ELF64 x86_64',
                'needed_libraries': needed, 'required_symbol_versions': versions, 'interpreter': interpreter[0],
                'observed_amber': {'os': 'Ubuntu 22.04.3', 'architecture': 'x86_64', 'glibc': '2.35'},
                'physical_transmit_available': False, 'installed': False, 'service_enabled': False,
                'portable_groups': 53, 'transport_groups': 8, 'runtime_groups': 9,
                'release_scope': 'Passive commissioning and isolated virtual-CAN control only',
                'files_sha256': {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(output.rglob('*')) if p.is_file()}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    with tarfile.open(output.with_suffix('.tar.gz'), 'w:gz') as archive:
        archive.add(output, arcname='amber-commissioning')
    print(json.dumps({'staged': str(output), 'source_commit': commit, 'physical_transmit_available': False}))


if __name__ == '__main__':
    main()
