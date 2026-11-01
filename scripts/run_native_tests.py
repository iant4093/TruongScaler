#!/usr/bin/env python3
"""Execute actual iOS package and app-hosted UIKit regressions, without a phone."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "build/logs"
RESULTS = ROOT / "build/test-results"
for directory in (LOGS, RESULTS):
    directory.mkdir(parents=True, exist_ok=True)
os.chdir(ROOT)
stages = []
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--suite", action="append", help="Run a named package suite plus hosted UIKit tests; repeat for multiple suites")
parser.add_argument("--hosted-only", action="store_true", help="Run only the app-hosted UIKit tests")
options = parser.parse_args()
if options.hosted_only and options.suite:
    parser.error("--hosted-only and --suite cannot be combined")


def run(label, args, env=None):
    print(label, flush=True)
    stage_started = time.monotonic()
    with (LOGS / (label + ".log")).open("w") as output:
        result = subprocess.run(args, env=env, stdout=output, stderr=subprocess.STDOUT)
    stages.append({"label": label, "command": args, "exitCode": result.returncode,
                   "elapsedSeconds": time.monotonic() - stage_started})
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
if options.hosted_only:
    suites = []
elif options.suite:
    unknown = set(options.suite) - set(suites)
    if unknown:
        parser.error("Unknown package suites: " + ", ".join(sorted(unknown)))
    suites = list(dict.fromkeys(options.suite))
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
# Inspect the installed companion from the host. iOS27 deprecates canOpenURL; a query
# is also weaker evidence than the actual Open In menu these integration tests exercise.
companion = subprocess.run(["xcrun", "simctl", "get_app_container", sim,
    "com.iantruong.truongnoiser", "app"], capture_output=True, text=True)
companion_available = False
if companion.returncode == 0:
    companion_info = Path(companion.stdout.strip()) / "Info.plist"
    if companion_info.is_file():
        declarations = plistlib.loads(companion_info.read_bytes()).get("CFBundleDocumentTypes", [])
        companion_available = any("com.iantruong.imagingsuite.handoff.noiser" in entry.get("LSItemContentTypes", [])
            for entry in declarations)
if os.environ.get("TRUONGSUITE_REQUIRE_COMPANION") == "1" and not companion_available:
    raise SystemExit("The updated companion must be installed on this Simulator for paired validation.")
run("hosted-ui-build", host_build + ["build-for-testing"])
templates = sorted((app_derived / "Build/Products").glob("TruongScalerHostTests_*.xctestrun"))
if len(templates) != 1:
    raise SystemExit("Expected one hosted test-run template.")
configuration = plistlib.loads(templates[0].read_bytes())
target = configuration.get("TruongScalerHostTests")
if not isinstance(target, dict):
    raise SystemExit("The hosted test-run template has no expected target.")
# XCTest host launches do not inherit arbitrary shell/SIMCTL_CHILD variables.
host_environment = target.setdefault("EnvironmentVariables", {})
host_environment["TRUONGSUITE_COMPANION_AVAILABLE"] = "1" if companion_available else "0"
capture_dir = os.environ.get("TRUONGSCALER_README_SCREENSHOT_DIR")
if capture_dir:
    capture_path = Path(capture_dir).resolve()
    host_environment["TRUONGSCALER_README_SCREENSHOT_DIR"] = str(capture_path)
configured = templates[0].parent / "Local-Validation.xctestrun"
configured.write_bytes(plistlib.dumps(configuration))
run("hosted-ui", ["xcodebuild", "-jobs", jobs, "-xctestrun", str(configured),
    "-destination", "platform=iOS Simulator,id=" + sim, "-resultBundlePath", str(result_bundle),
    "-collect-test-diagnostics", "never", "test-without-building"])
if capture_dir:
    for name in ("input-library.png", "processed-viewer.png", "output-library.png", "model-settings.png", "provenance.json"):
        if not (capture_path / name).is_file():
            raise SystemExit("Requested documentation capture did not produce " + name)
print("PASS: " + str(len(suites)) + " selected iOS package suites and app-hosted UIKit tests executed.", flush=True)
