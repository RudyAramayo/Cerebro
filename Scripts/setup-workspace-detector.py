#!/usr/bin/env python3
"""Install the local object detector; runtime inference never downloads code or weights."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import venv

MODEL = "google/owlv2-base-patch16-ensemble"
REVISION = "cfd3195ba4ea9592eec887ded089f4c08eff231d"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() / "Library/Application Support/Cerebro/WorkspaceDetector")
    args = parser.parse_args()
    directory = args.directory.expanduser().resolve()
    python = directory / "venv/bin/python3"
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(directory / "venv")
    requirements = Path(__file__).with_name("requirements-workspace-detector.txt")
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(requirements)], check=True)
    model = directory / "model"
    code = "from huggingface_hub import snapshot_download; import sys; snapshot_download(repo_id=sys.argv[1],revision=sys.argv[2],local_dir=sys.argv[3],allow_patterns=['*.json','merges.txt','vocab.json','model.safetensors'])"
    subprocess.run([str(python), "-c", code, MODEL, REVISION, str(model)], check=True)
    (directory / "installation.json").write_text(json.dumps({"model": MODEL, "revision": REVISION, "modelDirectory": str(model), "python": str(python), "runtimeNetwork": False}, indent=2) + "\n")
    print("Local workspace detector installed. Runtime uses cached safetensors with network disabled.")


if __name__ == "__main__":
    main()
