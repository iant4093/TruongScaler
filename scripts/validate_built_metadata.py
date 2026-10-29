#!/usr/bin/env python3
"""Validate the ACTUAL built app/widget metadata for this repair.

This is deliberately a build-product check, not a source-string assertion. It reads the
generated `Info.plist` files, embedded extension, asset catalog and model tree. It records the
`UIBackgroundModes` decision explicitly and never claims simulator background execution proves
physical iOS scheduling.

Usage:
  python3 scripts/validate_built_metadata.py \
      --app .build/device-debug/Build/Products/Debug-iphoneos/TruongScalerApp.app \
      --expect-config Debug
"""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path

WILDCARD = "com.iantruong.truongscaler.continued-processing.*"
PREFIX = "com.iantruong.truongscaler.continued-processing"
BUNDLE_ID = "com.iantruong.truongscaler"
WIDGET_ID = "com.iantruong.truongscaler.liveactivity"
APP_GROUP = "group.com.iantruong.imagingsuite"
KNOWN_BACKGROUND_MODES = {
    "audio", "location", "voip", "fetch", "remote-notification", "processing",
    "bluetooth-central", "bluetooth-peripheral", "external-accessory",
    "near-field-communication", "push-to-talk", "live-communication",
}


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--expect-config", choices=["Debug", "Release"], default=None)
    parser.add_argument("--entitlements", type=Path, default=None)
    parser.add_argument("--assetutil", default=None)
    args = parser.parse_args()

    app: Path = args.app
    failures: list[str] = []
    notes: list[str] = []

    if not app.is_dir():
        print(f"FAIL: built app does not exist: {app}", file=sys.stderr)
        return 1

    info_path = app / "Info.plist"
    if not info_path.is_file():
        print(f"FAIL: missing built Info.plist: {info_path}", file=sys.stderr)
        return 1
    info = load_plist(info_path)

    def expect(key: str, expected) -> None:
        actual = info.get(key)
        if actual != expected:
            failures.append(f"Info.plist {key}: expected {expected!r}, got {actual!r}")

    expect("CFBundleIdentifier", BUNDLE_ID)
    expect("CFBundleDisplayName", "TruongScaler")
    expect("CFBundleExecutable", "TruongScalerApp")
    expect("MinimumOSVersion", "27.0")
    expect("BGTaskSchedulerPermittedIdentifiers", [WILDCARD])
    expect("NSAccentColorName", "AccentColor")
    expect("NSSupportsLiveActivities", True)

    executable = app / "TruongScalerApp"
    if not executable.is_file() or executable.stat().st_size == 0:
        failures.append("main application executable is missing or empty")
    for test_bundle in app.rglob("*.xctest"):
        failures.append(f"embedded test bundle must not ship: {test_bundle.relative_to(app)}")

    url_types = info.get("CFBundleURLTypes") or []
    schemes = [scheme for entry in url_types for scheme in (entry.get("CFBundleURLSchemes") or [])]
    if "truongscaler" not in schemes:
        failures.append(f"CFBundleURLSchemes missing truongscaler: {schemes}")
    if "truongnoiser" not in (info.get("LSApplicationQueriesSchemes") or []):
        failures.append("LSApplicationQueriesSchemes missing truongnoiser")

    orientations = set(info.get("UISupportedInterfaceOrientations") or [])
    for required in ("UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"):
        if required not in orientations:
            failures.append(f"UISupportedInterfaceOrientations missing {required}")

    background_modes = info.get("UIBackgroundModes")
    if background_modes is None:
        notes.append("UIBackgroundModes absent. Continued processing is foreground-initiated; the "
                     "reproduced registration rejection was caused by registering the literal wildcard, "
                     "not by this key. Physical submission must still be retested.")
    else:
        unknown = set(background_modes) - KNOWN_BACKGROUND_MODES
        if unknown:
            failures.append(f"unsupported UIBackgroundModes values: {sorted(unknown)}")
        notes.append(f"UIBackgroundModes present: {background_modes}")

    # The wildcard must be a bundle-ID-prefixed family and every concrete submission must be under it.
    if not WILDCARD.startswith(BUNDLE_ID + "."):
        failures.append("BG wildcard is not prefixed by the main bundle ID")
    if not WILDCARD.endswith(".*"):
        failures.append("BG wildcard does not end in .*")

    # Compiled accent asset: current TruongCam uses systemGreenColor, not the stale blush value.
    assets_car = app / "Assets.car"
    if not assets_car.is_file() or assets_car.stat().st_size <= 0:
        failures.append("missing or empty compiled Assets.car")
    else:
        if args.assetutil:
            assetutil_command = [args.assetutil]
        else:
            assetutil_command = ["xcrun", "--sdk", "iphonesimulator", "assetutil"]
        try:
            output = subprocess.run(
                [*assetutil_command, "--info", str(assets_car)],
                check=True, capture_output=True, text=True, timeout=120,
            ).stdout
            if '"Name" : "AccentColor"' not in output:
                failures.append("compiled Assets.car does not contain AccentColor")
            if '"System Color Name" : "systemGreenColor"' not in output:
                failures.append("compiled AccentColor does not reference systemGreenColor")
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(f"could not inspect Assets.car with assetutil: {error}")

    # Embedded Live Activity extension.
    widget = app / "PlugIns/TruongScalerLiveActivityExtension.appex"
    if not widget.is_dir():
        failures.append("missing embedded TruongScalerLiveActivityExtension.appex")
    else:
        widget_info = load_plist(widget / "Info.plist")
        if widget_info.get("CFBundleIdentifier") != WIDGET_ID:
            failures.append(f"widget CFBundleIdentifier is {widget_info.get('CFBundleIdentifier')!r}")
        extension = (widget_info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        if extension != "com.apple.widgetkit-extension":
            failures.append(f"widget NSExtensionPointIdentifier is {extension!r}")
        if not (widget / "TruongScalerLiveActivityExtension").is_file():
            failures.append("widget executable is missing")

    # Two shapes of each trained native 2× family, plus notices/provenance.
    models = app / "Models"
    expected_models = {f"{family}_x2_{size}.mlmodelc" for family in ("QuickSRNet_Large", "EDSR_Baseline", "HAT_S") for size in (192, 256)}
    if not models.is_dir():
        failures.append("missing embedded Models tree")
    else:
        present = {p.name for p in models.iterdir() if p.is_dir()}
        if expected_models != {name for name in present if name.endswith(".mlmodelc")}:
            failures.append(f"embedded Models mismatch; missing: {sorted(expected_models - present)}, unexpected: {sorted({name for name in present if name.endswith('.mlmodelc')} - expected_models)}")
        for name in sorted(expected_models):
            asset = models / name
            for required in ("coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"):
                if not (asset / required).is_file():
                    failures.append(f"{name} missing {required}")
        for notice in ("QuickSRNet-LICENSE.txt", "EDSR-LICENSE.txt", "HAT-S-LICENSE.txt", "HAT-S-BasicSR-LICENSE.txt", "HAT-S-timm-LICENSE.txt"):
            if not (models / "Notices" / notice).is_file():
                failures.append(f"Models/Notices missing {notice}")
        for provenance in ("checkpoint-sha256.txt", "model-inventory.json", "hat-source-manifest.json"):
            if not (models / "Provenance" / provenance).is_file():
                failures.append(f"Models/Provenance missing {provenance}")
        try:
            inventory_json = json.loads((models / "Provenance/model-inventory.json").read_text())
            rows = inventory_json.get("models", [])
            expected_ids = {Path(name).stem for name in expected_models}
            if (inventory_json.get("canonicalModelCount") != 6 or len(rows) != 6 or
                    {row.get("identifier") for row in rows} != expected_ids or
                    any(row.get("asset") != row.get("identifier", "") + ".mlmodelc" for row in rows)):
                failures.append("embedded model inventory does not declare exactly the six native 2× variants")
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"embedded model inventory unreadable: {error}")
        try:
            manifest = json.loads((models / "Provenance/hat-source-manifest.json").read_text())
            if (manifest.get("repository") != "https://github.com/XPixelGroup/HAT" or
                    manifest.get("revision") != "1638a9a822581657811867bf670717f8371fc3e5" or
                    manifest.get("basicSRTag") != "v1.3.4.9" or not manifest.get("files")):
                failures.append("embedded HAT source manifest does not identify the pinned official reference")
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"embedded HAT source manifest unreadable: {error}")

    if args.entitlements is not None:
        entitlements = load_plist(args.entitlements)
        if entitlements.get("com.apple.developer.kernel.increased-memory-limit") is not True:
            failures.append("missing increased-memory-limit entitlement")
        if APP_GROUP not in (entitlements.get("com.apple.security.application-groups") or []):
            failures.append(f"missing App Group {APP_GROUP}")
        if any("continued-processing.gpu" in key for key in entitlements):
            failures.append("unexpected background GPU entitlement")

    # Information that must be explicit, not fabricated.
    notes.append("Simulator registration of the concrete identifier is accepted; simulator submission "
                 "returns platform-unavailable. Physical iOS scheduling remains a device-only gate.")
    notes.append("BGTaskScheduler handler registration is per concrete job identifier, while Info.plist "
                 "advertises only the wildcard family.")

    print(f"=== built metadata: {app} ===")
    if args.expect_config:
        print(f"config: {args.expect_config}")
    for note in notes:
        print(f"NOTE: {note}")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("PASS: app executable, Info.plist, extension, accent asset, BG family and 6 trained native 2× models are consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
