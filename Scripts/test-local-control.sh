#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-local-control.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_dir/Cerebro/ROBLocalControlProtocol.swift" "$repo_dir/Cerebro/ROBPassiveViewSettling.swift" \
  "$repo_dir/Cerebro/ROBRecycleShuttlePlan.swift" "$repo_dir/Tests/ROBLocalControlTests.swift" -o "$fixture_dir/policy"
"$fixture_dir/policy"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_dir/Cerebro/ROBLocalControlProtocol.swift" "$repo_dir/Cerebro/ROBLocalObservationStore.swift" \
  "$repo_dir/Tests/ROBLocalObservationTests.swift" -o "$fixture_dir/observation"
"$fixture_dir/observation"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_dir/Cerebro/ROBLocalControlProtocol.swift" "$repo_dir/Cerebro/ROBLocalControlSocket.swift" \
  "$repo_dir/Tests/ROBLocalControlSocketFixture.swift" -o "$fixture_dir/socket"
python3 - "$repo_dir" "$fixture_dir" <<'PY'
import importlib.util, json, os, socket, stat, subprocess, sys, time, uuid
from pathlib import Path
root, folder = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('rpc', root/'Scripts/cerebroctl.py')
rpc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rpc)
directory=folder/'runtime'; path=directory/'control.sock'
process=subprocess.Popen([str(folder/'socket'),str(directory)])
try:
    end=time.monotonic()+5
    while not path.exists() and time.monotonic()<end: time.sleep(.02)
    assert stat.S_IMODE(directory.stat().st_mode)==0o700
    assert stat.S_IMODE(path.stat().st_mode)==0o600
    state=rpc.request('status',socket_path=path); session=state['session']
    command=str(uuid.uuid4())
    first=rpc.request('motion.move',socket_path=path,session=session,request_id=command)
    assert first['ok'] and first['result']['commands']==1
    again=rpc.request('motion.move',socket_path=path,session=session,request_id=command)
    assert not again['ok'] and 'Duplicate' in again['error']
    stale=rpc.request('mission.start',socket_path=path,session='old-launch')
    assert not stale['ok']
    assert rpc.request('status',socket_path=path)['result']['commands']==1
    # A truncated client, oversized message, and disconnect do not wedge Stop.
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
        c.connect(str(path)); c.sendall(b'{' + b'x'*32769 + b'\n')
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
        c.connect(str(path)); c.sendall(b'{')
    assert rpc.request('stop',socket_path=path)['ok']
    print('PASS real Unix socket and CLI: private permissions, second-instance exclusion, same-session command, replay/stale rejection, malformed/disconnected clients and Stop responsiveness; inert handler only')
finally:
    process.terminate();process.wait(timeout=5)
PY
