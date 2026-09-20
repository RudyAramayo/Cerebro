#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_dir="$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv"
python_bin="${ROB_SHADOW_BOOTSTRAP_PYTHON:-/opt/homebrew/bin/python3}"
if [[ ! -x "$runtime_dir/bin/python3" ]]; then
  "$python_bin" -m venv "$runtime_dir"
fi
"$runtime_dir/bin/python3" -m pip install -r "$repo_dir/Cerebro/Resources/ShadowPlanner/requirements.txt"
"$runtime_dir/bin/python3" -c 'from importlib.metadata import version; import pydrake; print("Shadow runtime ready: Drake " + version("drake"))'
# This installs a local development dependency only. It does not launch Cerebro,
# contact Amber, change boot models, or install a public/signed distribution.
