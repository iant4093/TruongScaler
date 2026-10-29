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
        for family in ["QuickSRNet_Large", "EDSR_Baseline", "HAT_S"]:
            for size in [192, 256]:
                asset = models / f"{family}_x2_{size}.mlmodelc"
                for name in ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"]:
                    target = asset / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"layout-fixture-only")
        for notice in ["QuickSRNet-LICENSE.txt", "EDSR-LICENSE.txt", "HAT-S-LICENSE.txt", "HAT-S-BasicSR-LICENSE.txt", "HAT-S-timm-LICENSE.txt"]:
            target = models / "Notices" / notice
            target.parent.mkdir(exist_ok=True)
            target.write_text("layout-fixture-notice")
        provenance = models / "Provenance"
        provenance.mkdir()
        (provenance / "checkpoint-sha256.txt").write_text("layout-fixture-checksums")
        identifiers = [f"{family}_x2_{size}" for family in ["QuickSRNet_Large", "EDSR_Baseline", "HAT_S"] for size in [192, 256]]
        (provenance / "model-inventory.json").write_text(json.dumps(dict(canonicalModelCount=6,
            models=[dict(identifier=name, asset=name + ".mlmodelc") for name in identifiers])))
        (provenance / "hat-source-manifest.json").write_text(json.dumps(dict(repository="https://github.com/XPixelGroup/HAT",
            revision="1638a9a822581657811867bf670717f8371fc3e5", basicSRTag="v1.3.4.9",
            files=[dict(path="layout-fixture-only", sha256="0" * 64, bytes=1)])))
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

    def testMissingHATShapeIsRefused(self):
        (self.app / "Models/HAT_S_x2_256.mlmodelc/weights/weight.bin").unlink()
        self.assertNotEqual(self.audit().returncode, 0)

    def testRetiredCompiledModelIsRefused(self):
        (self.app / "Models/Retired_x4_256.mlmodelc").mkdir()
        self.assertNotEqual(self.audit().returncode, 0)

    def testFourModelInventoryCannotDescribeASixAssetBundle(self):
        path = self.app / "Models/Provenance/model-inventory.json"
        inventory = json.loads(path.read_text())
        inventory["canonicalModelCount"] = 4
        path.write_text(json.dumps(inventory))
        self.assertNotEqual(self.audit().returncode, 0)

    def testEachHATSupportNoticeIsRequired(self):
        for name in ["HAT-S-LICENSE.txt", "HAT-S-BasicSR-LICENSE.txt", "HAT-S-timm-LICENSE.txt"]:
            path = self.app / "Models/Notices" / name
            original = path.read_bytes()
            path.unlink()
            self.assertNotEqual(self.audit().returncode, 0, name)
            path.write_bytes(original)

    def testMissingOrUnpinnedHATSourceManifestIsRefused(self):
        path = self.app / "Models/Provenance/hat-source-manifest.json"
        original = json.loads(path.read_text())
        path.unlink()
        self.assertNotEqual(self.audit().returncode, 0)
        original["revision"] = "0" * 40
        path.write_text(json.dumps(original))
        self.assertNotEqual(self.audit().returncode, 0)


if __name__ == "__main__":
    unittest.main()
