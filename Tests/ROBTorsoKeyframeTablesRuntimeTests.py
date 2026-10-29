#!/usr/bin/env python3
"""Regression entry point for the replacement stable-ID animation tables."""
from pathlib import Path
import subprocess
subprocess.run(['bash', str(Path(__file__).resolve().parents[1]/'Scripts/test-animation-studio.sh')], check=True)
