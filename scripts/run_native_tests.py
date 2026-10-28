#!/usr/bin/env python3
"""Execute actual iOS package and app-hosted UIKit regressions, without a phone."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "build/logs"
RESULTS = ROOT / "build/test-results"
for directory in (LOGS, RESULTS):
    directory.mkdir(parents=True, exist_ok=True)
os.chdir(ROOT)
stages = []


def run(label, args, env=None):
    print(label, flush=True)
    with (LOGS / (label + ".log")).open("w") as output:
        result = subprocess.run(args, env=env, stdout=output, stderr=subprocess.STDOUT)
    stages.append({"label": label, "command": args, "exitCode": result.returncode})
    (RESULTS / "native-stages.json").write_text(json.dumps(stages, indent=2) + "\n")
    if result.returncode:
        print((LOGS / (label + ".log")).read_text()[-12000:], file=sys.stderr)
        raise SystemExit(result.returncode)


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", identifier)
    return tuple(int(value or 0) for value in match.groups()) if match else (0, 0, 0)


inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
candidates = []
for runtime, devices in inventory["devices"].items():
    if runtime_version(runtime)[0] < 27:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("deviceTypeIdentifier", "").endswith(".iPhone-17"):
            candidates.append((runtime_version(runtime), device))
requested = os.environ.get("TRUONGSCALER_SIMULATOR_UDID")
if requested:
    candidates = [row for row in candidates if row[1]["udid"] == requested]
if not candidates:
    raise SystemExit("An available iPhone 17 Simulator with iOS 27+ is required; no fallback device is used.")
device = sorted(candidates, key=lambda row: row[0], reverse=True)[0][1]
sim = device["udid"]
(RESULTS / "simulator.json").write_text(json.dumps(device, indent=2) + "\n")
if device["state"] != "Booted":
    subprocess.run(["xcrun", "simctl", "boot", sim], check=True)
subprocess.run(["xcrun", "simctl", "bootstatus", sim, "-b"], check=True)
package_derived = Path(os.environ.get("TRUONGSCALER_PACKAGE_DERIVED_DATA", ROOT / "build/NativePackageDerivedData"))
app_derived = Path(os.environ.get("TRUONGSCALER_APP_TEST_DERIVED_DATA", ROOT / "build/NativeAppDerivedData"))
jobs = os.environ.get("TRUONGSCALER_BUILD_JOBS", "2")
if not jobs.isdecimal() or int(jobs) < 1:
    raise SystemExit("TRUONGSCALER_BUILD_JOBS must be a positive integer.")
suites = [
    "TruongScalerCoreTests", "MMapCanvasTests", "CoreIngestionTests",
    "MetalColorEngineTests", "TiledInferenceEngineTests", "DNGWriterBridgeTests",
    "CoreExportTests", "BackgroundJobManagerTests", "DeepZoomGalleryUITests",
]
# Standalone UIKit geometry fixtures still need the sceneless UIWindow initializer,
# deprecated on iOS 26. App/hosted builds below and distribution builds treat warnings
# as errors; these package fixtures keep deprecation diagnostics visible in their logs.
for suite in suites:
    run(suite + "-build", [
        "xcodebuild", "-jobs", jobs, "build-for-testing", "-scheme", suite,
        "-destination", "platform=iOS Simulator,id=" + sim, "-derivedDataPath", str(package_derived),
        "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox -strict-concurrency=complete",
    ])
developer = Path(os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip())
platform = developer / "Platforms/iPhoneSimulator.platform/Developer"
products = package_derived / "Build/Products/Debug-iphonesimulator"
env = os.environ.copy()
env["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks") + ":" + str(products / "PackageFrameworks")
env["SIMCTL_CHILD_DYLD_LIBRARY_PATH"] = str(products)
env["SIMCTL_CHILD_TRUONGSCALER_QUALITY_EVIDENCE_DIR"] = str(RESULTS / "quality/ios")
for suite in suites:
    bundle = products / (suite + ".xctest")
    if not bundle.is_dir():
        raise SystemExit("Required native test bundle missing: " + str(bundle))
    run("ios-" + suite, ["xcrun", "simctl", "spawn", sim, str(platform / "Library/Xcode/Agents/xctest"), str(bundle)], env)
result_bundle = RESULTS / "native-hosted.xcresult"
# Only a prior generated result at this exact ignored path, never app data.
if result_bundle.exists():
    shutil.rmtree(result_bundle)
host_build = [
    "xcodebuild", "-jobs", jobs, "-project", "TruongScaler.xcodeproj", "-scheme", "TruongScalerHostTests",
    "-destination", "platform=iOS Simulator,id=" + sim, "-derivedDataPath", str(app_derived),
    "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
]
capture_dir = os.environ.get("TRUONGSCALER_README_SCREENSHOT_DIR")
if capture_dir:
    run("hosted-ui-build", host_build + ["build-for-testing"])
    templates = sorted((app_derived / "Build/Products").glob("TruongScalerHostTests_*.xctestrun"))
    if len(templates) != 1:
        raise SystemExit("Expected one hosted test-run template for screenshot capture.")
    configuration = plistlib.loads(templates[0].read_bytes())
    target = configuration.get("TruongScalerHostTests")
    if not isinstance(target, dict):
        raise SystemExit("The hosted test-run template has no expected target.")
    # xcodebuild does not forward arbitrary shell or SIMCTL_CHILD variables to its test host.
    # Put the opt-in value in XCTest's actual launch environment, beside the template so
    # __TESTROOT__ continues resolving to the built Products directory.
    capture_path = Path(capture_dir).resolve()
    target.setdefault("EnvironmentVariables", {})["TRUONGSCALER_README_SCREENSHOT_DIR"] = str(capture_path)
    configured = templates[0].parent / "README-Capture.xctestrun"
    configured.write_bytes(plistlib.dumps(configuration))
    run("hosted-ui", ["xcodebuild", "-jobs", jobs, "-xctestrun", str(configured),
        "-destination", "platform=iOS Simulator,id=" + sim, "-resultBundlePath", str(result_bundle),
        "test-without-building"])
    for name in ("input-library.png", "processed-viewer.png", "output-library.png", "model-settings.png", "provenance.json"):
        if not (capture_path / name).is_file():
            raise SystemExit("Requested documentation capture did not produce " + name)
else:
    run("hosted-ui", host_build + ["-resultBundlePath", str(result_bundle), "test"])
print("PASS: all iOS package and app-hosted test suites executed.", flush=True)
