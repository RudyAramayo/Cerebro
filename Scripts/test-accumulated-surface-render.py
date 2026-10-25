#!/usr/bin/env python3
"""Exercise the production accumulator, renderer and controller scan methods.

Robot services are inert substitutes; this fixture has no camera/actuator IO.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/ROBSCNViewController.m").read_text()
properties = source[source.index("@property (strong) NSButton *surfaceMode;"):source.index("\n@end")]
methods = source[source.index("- (void)surfaceModeChanged:"):source.index("- (void)refreshFloorStatus\n")]
fixture = (root / "Tests/ROBAccumulatedSurfaceRenderFixture.m").read_text()
fixture = fixture.replace("__CONTROLLER_PROPERTIES__", properties).replace("__CONTROLLER_METHODS__", methods)
with tempfile.TemporaryDirectory(prefix="rob-surface-render-", dir="/private/tmp") as temporary:
    temporary = Path(temporary)
    path = temporary / "fixture.m"
    path.write_text(fixture)
    executable = temporary / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-parameter", "-I", str(root / "Cerebro"), str(path),
                    str(root / "Cerebro/ROBAccumulatedSurfaceRenderer.m"),
                    "-framework", "AppKit", "-framework", "SceneKit", "-o", str(executable)], check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True)
