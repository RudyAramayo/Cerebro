#!/usr/bin/env python3
"""Install the completed, signed Cerebro product without interrupting the robot."""

import ctypes
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


BUNDLE_ID = "com.orbitusrobotics.Cerebro"


def check_bundle_identity(app):
    if app.is_symlink():
        raise ValueError("Refusing to replace or copy a symlink: {}".format(app))
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Not a Cerebro application: {}".format(app))
    if info.get("CFBundleExecutable") != "Cerebro":
        raise ValueError("Unexpected Cerebro executable in {}".format(app))
    if not os.access(app / "Contents/MacOS/Cerebro", os.X_OK):
        raise ValueError("Cerebro executable is missing or not executable: {}".format(app))


def verify_bundle(app):
    check_bundle_identity(app)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def swap_bundles(first, second):
    # macOS renamex_np(RENAME_SWAP) exchanges complete directories atomically.
    # The old installation stays intact if the filesystem refuses the swap.
    rename = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(second))


def install(source, destination):
    source, destination = Path(source), Path(destination)
    if destination.name != "Cerebro.app" or source.resolve() == destination.resolve():
        raise ValueError("Source must be a separate built Cerebro.app product")
    verify_bundle(source)
    if not destination.parent.is_dir():
        raise ValueError("Install directory does not exist: {}".format(destination.parent))

    # Concurrent Debug/Release builds must not exchange each other's staging
    # directories or roll back a newer installation.
    lock_path = destination.parent / ".Cerebro-build-install.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        had_previous = destination.exists() or destination.is_symlink()
        if had_previous:
            check_bundle_identity(destination)
        staging = Path(tempfile.mkdtemp(prefix=".Cerebro-build-install-", dir=destination.parent))
        staged_app = staging / "Cerebro.app"
        preserve_staging = False
        try:
            subprocess.run(["/usr/bin/ditto", str(source), str(staged_app)], check=True)
            verify_bundle(staged_app)
            if had_previous:
                swap_bundles(staged_app, destination)
            else:
                staged_app.rename(destination)
            try:
                verify_bundle(destination)
            except Exception:
                try:
                    if had_previous:
                        swap_bundles(staged_app, destination)
                    else:
                        destination.rename(staged_app)
                except Exception:
                    preserve_staging = True
                    print("error: Install rollback failed; retained recovery files at {}".format(staging), file=sys.stderr)
                    raise
                raise
        finally:
            if not preserve_staging:
                shutil.rmtree(staging)
    print("note: Installed signed Cerebro build at {}. A running session is unchanged; relaunch to use the update.".format(destination))


def main():
    if os.environ.get("CEREBRO_INSTALL_AFTER_BUILD", "YES") == "NO":
        print("note: Cerebro installation disabled by CEREBRO_INSTALL_AFTER_BUILD=NO")
        return 0
    if os.environ.get("ACTION", "build") != "build":
        print("note: Cerebro installation skipped for {}".format(os.environ["ACTION"]))
        return 0
    try:
        product = Path(os.environ["BUILT_PRODUCTS_DIR"]) / "Cerebro.app"
        destination = Path(os.environ.get("CEREBRO_INSTALL_DIRECTORY", "/Applications")) / "Cerebro.app"
        install(product, destination)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("error: Cerebro installation failed: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
