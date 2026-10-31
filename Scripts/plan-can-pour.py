#!/usr/bin/env python3
"""Run the same saved-scene planner used by Cerebro Testing Sandbox."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Cerebro/Resources/ShadowPlanner'))
from can_pour_scenario import main
if __name__ == '__main__': raise SystemExit(main())
