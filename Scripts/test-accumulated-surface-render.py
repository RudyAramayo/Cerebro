#!/usr/bin/env python3
"""Exercise the production accumulator, renderer and controller scan methods.

Robot services are inert substitutes; this fixture has no camera/actuator IO.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/ROBSCNViewController.m").read_text()
properties_start = source.index("@property (strong) NSButton *surfaceMode;")
properties = source[properties_start:source.index("\n@end", properties_start)]
methods = source[source.index("- (void)surfaceModeChanged:"):source.index("- (void)refreshFloorStatus\n")]
fixture = (root / "Tests/ROBAccumulatedSurfaceRenderFixture.m").read_text()
fixture = fixture.replace("__CONTROLLER_PROPERTIES__", properties).replace("__CONTROLLER_METHODS__", methods)
render_path = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/rob-accumulated-surface-render.png").resolve()
render_path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="rob-surface-render-", dir="/private/tmp") as temporary:
    temporary = Path(temporary)
    path = temporary / "fixture.m"
    path.write_text(fixture)
    executable = temporary / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-parameter", "-I", str(root / "Cerebro"), str(path),
                    str(root / "Cerebro/ROBAccumulatedSurfaceRenderer.m"),
                    "-framework", "AppKit", "-framework", "SceneKit", "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(render_path)], check=True)
image = render_path.read_bytes()
assert image[:8] == b"\x89PNG\r\n\x1a\n", "The production renderer must produce a PNG artifact"
assert struct.unpack(">II", image[16:24]) == (1100, 800), "Unexpected production render dimensions"
print(f"Production renderer PNG: {render_path}")
