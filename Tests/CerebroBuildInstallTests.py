#!/usr/bin/env python3
"""Exercise real signed bundles and atomic replacement in temporary directories."""

import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "Scripts/install-built-cerebro.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class BuildInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cerebro-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.applications = self.root / "Applications with spaces"
        self.applications.mkdir()
        self.destination = self.applications / "Cerebro.app"
        self.source = self.bundle("Built products", "new build")

    def bundle(self, directory, version):
        app = self.root / directory / "Cerebro.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Resources/version.txt").write_text(version)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": installer.BUNDLE_ID,
                          "CFBundleExecutable": "Cerebro", "CFBundlePackageType": "APPL",
                          "CFBundleVersion": "1"}, stream)
        subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(app / "Contents/MacOS/Cerebro")],
                       input="int main(void) { return 0; }\n", text=True, check=True, capture_output=True)
        self.sign(app)
        return app

    def sign(self, app):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                       check=True, capture_output=True)

    def install_previous(self):
        previous = self.bundle("Previous build", "old build")
        (previous / "Contents/Resources/obsolete.txt").write_text("old-only resource")
        self.sign(previous)
        installer.install(previous, self.destination)

    def test_complete_signed_replacement_removes_obsolete_files(self):
        self.install_previous()
        installer.install(self.source, self.destination)
        installer.verify_bundle(self.destination)
        self.assertEqual((self.destination / "Contents/Resources/version.txt").read_text(), "new build")
        self.assertFalse((self.destination / "Contents/Resources/obsolete.txt").exists())
        self.assertEqual(list(self.applications.glob(".Cerebro-build-install-*")), [])

    def test_invalid_signature_leaves_previous_installation(self):
        self.install_previous()
        (self.source / "Contents/Resources/version.txt").write_text("tampered")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source, self.destination)
        self.assertEqual((self.destination / "Contents/Resources/version.txt").read_text(), "old build")
        installer.verify_bundle(self.destination)

    def test_post_install_failure_rolls_back(self):
        self.install_previous()
        verify = installer.verify_bundle
        def fail_destination(app):
            if app == self.destination:
                raise ValueError("simulated final verification failure")
            verify(app)
        with mock.patch.object(installer, "verify_bundle", side_effect=fail_destination):
            with self.assertRaises(ValueError):
                installer.install(self.source, self.destination)
        verify(self.destination)
        self.assertEqual((self.destination / "Contents/Resources/version.txt").read_text(), "old build")

    def test_failed_swap_keeps_previous_installation(self):
        self.install_previous()
        with mock.patch.object(installer, "swap_bundles", side_effect=PermissionError("read-only destination")):
            with self.assertRaises(PermissionError):
                installer.install(self.source, self.destination)
        self.assertEqual((self.destination / "Contents/Resources/version.txt").read_text(), "old build")

    def test_symlink_and_source_destination_alias_are_rejected(self):
        self.destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.assertTrue(self.destination.is_symlink())
        with self.assertRaises(ValueError):
            installer.install(self.source, self.source)

    def test_wrong_destination_identity_is_not_overwritten(self):
        self.install_previous()
        info = self.destination / "Contents/Info.plist"
        with info.open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "another.application"}, stream)
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.assertEqual((self.destination / "Contents/Resources/version.txt").read_text(), "old build")

    def test_opt_out_and_archive_do_not_touch_installation(self):
        for environment in ({"CEREBRO_INSTALL_AFTER_BUILD": "NO"}, {"ACTION": "install"}):
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(installer.main(), 0)
        self.assertFalse(self.destination.exists())

    def test_shared_scheme_includes_install_for_build_not_archive_or_analyze(self):
        scheme = ET.parse(ROOT / "Cerebro.xcodeproj/xcshareddata/xcschemes/Cerebro.xcscheme")
        entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
        entry = next(entry for entry in entries if entry.find("BuildableReference").get("BlueprintName") == "Install Cerebro")
        for action in ["buildForRunning", "buildForTesting", "buildForProfiling"]:
            self.assertEqual(entry.get(action), "YES")
        for action in ["buildForArchiving", "buildForAnalyzing"]:
            self.assertEqual(entry.get(action), "NO")
        self.assertIsNotNone(scheme.find("./LaunchAction/PreActions"))
        self.assertIsNotNone(scheme.find("./LaunchAction/PostActions"))


if __name__ == "__main__":
    unittest.main()
