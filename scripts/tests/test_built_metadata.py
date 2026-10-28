"""Negative bundle-layout checks, with no model execution or production substitutions.

The real app/resource audits still run on compiled products. These tiny file-layout fixtures
exercise refusal paths without needing to mutate an installed or signed application.
"""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuiltMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="TruongScaler-audit-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.app = root / "Fixture.app"
        self.app.mkdir()
        info = dict(CFBundleIdentifier="com.iantruong.truongscaler", CFBundleDisplayName="TruongScaler",
            CFBundleExecutable="TruongScalerApp", MinimumOSVersion="27.0", NSAccentColorName="AccentColor",
            NSSupportsLiveActivities=True,
            BGTaskSchedulerPermittedIdentifiers=["com.iantruong.truongscaler.continued-processing.*"],
            CFBundleURLTypes=[dict(CFBundleURLSchemes=["truongscaler"])], LSApplicationQueriesSchemes=["truongnoiser"],
            UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
        (self.app / "TruongScalerApp").write_bytes(b"layout-fixture-executable")
        (self.app / "Assets.car").write_bytes(b"layout-fixture-catalog")
        widget = self.app / "PlugIns/TruongScalerLiveActivityExtension.appex"
        widget.mkdir(parents=True)
        (widget / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.iantruong.truongscaler.liveactivity",
            NSExtension=dict(NSExtensionPointIdentifier="com.apple.widgetkit-extension"))))
        (widget / "TruongScalerLiveActivityExtension").write_bytes(b"layout-fixture-widget")
        models = self.app / "Models"
        for family in ["QuickSRNet_Large", "EDSR_Baseline"]:
            for size in [192, 256]:
                asset = models / f"{family}_x2_{size}.mlmodelc"
                for name in ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"]:
                    target = asset / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"layout-fixture-only")
        for notice in ["QuickSRNet-LICENSE.txt", "EDSR-LICENSE.txt"]:
            target = models / "Notices" / notice
            target.parent.mkdir(exist_ok=True)
            target.write_text("layout-fixture-notice")
        provenance = models / "Provenance"
        provenance.mkdir()
        (provenance / "checkpoint-sha256.txt").write_text("layout-fixture-checksums")
        (provenance / "model-inventory.json").write_text(json.dumps(dict(canonicalModelCount=4)))
        self.assetutil = root / "assetutil-fixture"
        self.assetutil.write_text('#!/bin/sh\nprintf \'"Name" : "AccentColor"\\n"System Color Name" : "systemGreenColor"\\n\'\n')
        self.assetutil.chmod(0o700)

    def audit(self):
        return subprocess.run([sys.executable, str(ROOT / "scripts/validate_built_metadata.py"), "--app", str(self.app),
            "--assetutil", str(self.assetutil)], capture_output=True, text=True)

    def testCompleteLayoutPasses(self):
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def testMissingMainExecutableIsRefused(self):
        (self.app / "TruongScalerApp").unlink()
        self.assertNotEqual(self.audit().returncode, 0)

    def testEmptyMainExecutableIsRefused(self):
        (self.app / "TruongScalerApp").write_bytes(b"")
        self.assertNotEqual(self.audit().returncode, 0)

    def testEmbeddedHostedTestBundleIsRefused(self):
        (self.app / "PlugIns/TruongScalerHostTests.xctest").mkdir()
        self.assertNotEqual(self.audit().returncode, 0)


if __name__ == "__main__":
    unittest.main()
