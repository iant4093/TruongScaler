#!/usr/bin/env python3
"""Verify six trained native2× assets, their pinned sources and optional built app.

Standard library only: provenance/bundle checks never import ML dependencies or load models.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / "Targets/TruongScalerApp/Models"
FAMILIES = ("QuickSRNet_Large", "EDSR_Baseline", "HAT_S")
EXPECTED_IDENTIFIERS = {f"{family}_x2_{size}" for family in FAMILIES for size in (192, 256)}
CHECKPOINTS = {
    "quicksrnet-large-2x": ("quicksrnet-large-2x.pth", "0c6e0f4e2b444b161d6bce22852b0e2aa0dc391ef804c99e867882dd9715ad9d"),
    "edsr_baseline-2x": ("edsr-baseline-x2.pt", "1bc9523228fdc3b0a5ddb0d7062001e22b31bbb398ae09cfdefb97e8ee06e171"),
    "hat-s-2x": ("HAT-S_SRx2.pth", "3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf"),
}
HAT_REVISION = "1638a9a822581657811867bf670717f8371fc3e5"
NOTICE_SOURCES = {
    "QuickSRNet-LICENSE.txt": "ModelConversionTools/vendor/quicksr/LICENSE.txt",
    "EDSR-LICENSE.txt": "ModelConversionTools/vendor/edsr/LICENSE",
    "HAT-S-LICENSE.txt": "ModelConversionTools/vendor/hat/LICENSE",
    "HAT-S-BasicSR-LICENSE.txt": "ModelConversionTools/vendor/hat/basicsr/LICENSE",
    "HAT-S-timm-LICENSE.txt": "ModelConversionTools/vendor/hat/basicsr/LICENSE_pytorch-image-models",
}
HAT_SOURCE_PATHS = {
    "ModelConversionTools/vendor/hat/HAT-S_SRx2.yml",
    "ModelConversionTools/vendor/hat/LICENSE",
    "ModelConversionTools/vendor/hat/basicsr/LICENSE",
    "ModelConversionTools/vendor/hat/basicsr/LICENSE_pytorch-image-models",
    "ModelConversionTools/vendor/hat/basicsr/arch_util.py",
    "ModelConversionTools/vendor/hat/basicsr/registry.py",
    "ModelConversionTools/vendor/hat/hat_arch.py",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_digest(directory: Path) -> str:
    files = sorted((p for p in directory.rglob("*") if p.is_file()),
                   key=lambda p: p.relative_to(directory).as_posix())
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(directory).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def load_json(path: Path, failures: list[str]):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        failures.append(f"unreadable JSON {path}: {error}")
        return None


def source_path(relative: str) -> Path:
    path = ROOT / relative
    if Path(relative).is_absolute() or not path.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError(f"source path is not repository-relative: {relative}")
    return path


def validate_model_entry(entry: dict, checkpoints: dict, models_dir: Path, failures: list[str]) -> None:
    identifier = entry.get("identifier")
    if identifier not in EXPECTED_IDENTIFIERS:
        failures.append(f"unsupported model identifier: {identifier!r}")
        return
    size = int(identifier.rsplit("_", 1)[1])
    family = identifier.rsplit("_x2_", 1)[0]
    expected_checkpoint = {"QuickSRNet_Large": "quicksrnet-large-2x", "EDSR_Baseline": "edsr_baseline-2x", "HAT_S": "hat-s-2x"}[family]
    for key, expected in {
        "asset": identifier + ".mlmodelc", "inputShape": [1, 3, size, size],
        "outputShape": [1, 3, size * 2, size * 2], "inputTensorName": "input_tile",
        "outputTensorName": "output_tile", "inputDataType": "Float16", "outputDataType": "Float16",
        "computePrecision": "FLOAT16" if family == "QuickSRNet_Large" else "FLOAT32",
        "checkpoint": expected_checkpoint, "checkpointSHA256": CHECKPOINTS[expected_checkpoint][1],
    }.items():
        if entry.get(key) != expected:
            failures.append(f"{identifier} {key} is {entry.get(key)!r}, expected {expected!r}")
    if family != "QuickSRNet_Large" and entry.get("productionRawPredictionRange") != [-0.25, 1.25]:
        failures.append(f"{identifier} must preserve its validated raw prediction range")
    checkpoint = checkpoints.get(expected_checkpoint, {})
    if (checkpoint.get("file"), checkpoint.get("sha256")) != CHECKPOINTS[expected_checkpoint]:
        failures.append(f"{identifier} checkpoint identity is not pinned")
    for model_key, checkpoint_key in [("upstreamRepo", "repo"), ("upstreamRevision", "revision"), ("license", "license")]:
        if not entry.get(model_key) or entry.get(model_key) != checkpoint.get(checkpoint_key):
            failures.append(f"{identifier} provenance disagrees at {model_key}")
    if family == "HAT_S" and (entry.get("upstreamRepo") != "https://github.com/XPixelGroup/HAT" or entry.get("upstreamRevision") != HAT_REVISION):
        failures.append(f"{identifier} official HAT source revision drift")
    if entry.get("asset") != identifier + ".mlmodelc":
        return
    asset = models_dir / entry["asset"]
    if not asset.is_dir():
        failures.append(f"missing compiled asset {asset}")
        return
    if directory_digest(asset) != entry.get("assetDirectorySHA256"):
        failures.append(f"directory digest drift for {identifier}")
    weights = asset / "weights/weight.bin"
    if not weights.is_file() or sha256_file(weights) != entry.get("weightBinSHA256"):
        failures.append(f"weight digest drift for {identifier}")
    if family == "HAT_S":
        actual_weights = {p.name: sha256_file(p) for p in (asset / "weights").iterdir() if p.is_file()}
        if actual_weights != entry.get("weightFilesSHA256"):
            failures.append(f"sharded weight inventory drift for {identifier}")


def verify_hat_sources(models_dir: Path, failures: list[str]) -> None:
    manifest_path = models_dir / "Provenance/hat-source-manifest.json"
    manifest = load_json(manifest_path, failures)
    if not isinstance(manifest, dict):
        return
    if (manifest.get("repository") != "https://github.com/XPixelGroup/HAT" or
            manifest.get("revision") != HAT_REVISION or manifest.get("basicSRTag") != "v1.3.4.9"):
        failures.append("HAT/support source manifest has an unpinned upstream")
    entries = manifest.get("files", [])
    if not isinstance(entries, list) or len(entries) != len(HAT_SOURCE_PATHS) or {e.get("path") for e in entries} != HAT_SOURCE_PATHS:
        failures.append("HAT source manifest must include the complete official architecture/config/support/notices")
        return
    vendor_manifest = ROOT / "ModelConversionTools/vendor/hat/source-manifest.json"
    if not vendor_manifest.is_file() or vendor_manifest.read_bytes() != manifest_path.read_bytes():
        failures.append("bundled HAT source manifest differs from the vendored reference manifest")
    for entry in entries:
        path = source_path(entry["path"])
        if (not path.is_file() or path.stat().st_size != entry.get("bytes") or
                sha256_file(path) != entry.get("sha256")):
            failures.append(f"official HAT/support source drift: {entry['path']}")


def verify(models_dir: Path, checkpoints_dir: Path | None, built_app: Path | None) -> int:
    failures: list[str] = []
    inventory = load_json(models_dir / "Provenance/model-inventory.json", failures)
    if not isinstance(inventory, dict):
        inventory = {}
    entries = inventory.get("models", [])
    if not isinstance(entries, list):
        entries = []
    if inventory.get("canonicalModelCount") != 6 or len(entries) != 6:
        failures.append("inventory must contain exactly six native 2× variants")
    identifiers = {entry.get("identifier") for entry in entries}
    if identifiers != EXPECTED_IDENTIFIERS:
        failures.append(f"unexpected inventory identifiers: {sorted(str(i) for i in identifiers)}")
    present = {p.stem for p in models_dir.glob("*.mlmodelc")}
    if present != EXPECTED_IDENTIFIERS:
        failures.append(f"unexpected compiled model tree: {sorted(present)}")
    if list(models_dir.glob("*.mlpackage")) or list(models_dir.glob("*.mlmodel")):
        failures.append("uncompiled conversion candidates must not be shipped in the Models tree")
    checkpoints = inventory.get("checkpoints", {})
    if set(checkpoints) != set(CHECKPOINTS):
        failures.append("inventory must retain exactly the three pinned checkpoint identities")
    for entry in entries:
        validate_model_entry(entry, checkpoints, models_dir, failures)
    for name, (filename, digest) in CHECKPOINTS.items():
        checkpoint = checkpoints.get(name, {})
        if (checkpoint.get("file"), checkpoint.get("sha256")) != (filename, digest):
            failures.append(f"checkpoint metadata drift for {name}")
        if checkpoints_dir is not None:
            path = checkpoints_dir / filename
            if not path.is_file() or sha256_file(path) != digest:
                failures.append(f"raw checkpoint hash drift or missing file: {path}")

    additional = load_json(models_dir / "Provenance/additional-source-manifest.json", failures)
    if not isinstance(additional, list) or not additional:
        failures.append("EDSR official source manifest must not be empty")
    else:
        for entry in additional:
            path = source_path(entry["localFile"])
            if not path.is_file() or sha256_file(path) != entry["sha256"]:
                failures.append(f"EDSR vendored source digest drift: {path}")
    quick = load_json(models_dir / "Provenance/upstream-source.json", failures)
    if not isinstance(quick, dict) or not quick.get("files"):
        failures.append("QuickSRNet official source manifest must not be empty")
    else:
        for entry in quick.get("files", []):
            path = source_path("ModelConversionTools/vendor/quicksr/" + entry["file"])
            if not path.is_file() or sha256_file(path) != entry["sha256"]:
                failures.append(f"QuickSRNet vendored source digest drift: {path}")
    verify_hat_sources(models_dir, failures)
    for notice, original in NOTICE_SOURCES.items():
        path = models_dir / "Notices" / notice
        upstream = ROOT / original
        if not path.is_file() or not upstream.is_file() or sha256_file(path) != sha256_file(upstream):
            failures.append(f"missing or changed upstream notice {notice}")

    if built_app is not None:
        built_models = built_app / "Models"
        if {p.stem for p in built_models.glob("*.mlmodelc")} != EXPECTED_IDENTIFIERS:
            failures.append("built app contains missing or retired compiled models")
        for entry in entries:
            if entry.get("identifier") not in EXPECTED_IDENTIFIERS:
                continue
            path = built_models / (entry["identifier"] + ".mlmodelc")
            if not path.is_dir() or directory_digest(path) != entry.get("assetDirectorySHA256"):
                failures.append(f"built app asset digest drift for {entry['identifier']}")
        # Resource discovery alone is insufficient: the actual app must contain identical notices
        # and provenance as well as the model weights. Do not silently omit a new source manifest.
        for folder in ("Provenance", "Notices"):
            for source in (models_dir / folder).rglob("*"):
                if source.is_file():
                    destination = built_models / source.relative_to(models_dir)
                    if not destination.is_file() or sha256_file(destination) != sha256_file(source):
                        failures.append(f"built app resource drift: {source.relative_to(models_dir)}")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"PASS: 6 trained native 2× assets and pinned provenance verified in {models_dir}")
    if checkpoints_dir is not None:
        print(f"PASS: raw checkpoint hashes verified in {checkpoints_dir}")
    if built_app is not None:
        print(f"PASS: built app Models, notices and provenance match all canonical digests: {built_app}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS)
    parser.add_argument("--checkpoints-dir", type=Path, default=None)
    parser.add_argument("--built-app", type=Path, default=None)
    args = parser.parse_args()
    try:
        return verify(args.models_dir, args.checkpoints_dir, args.built_app)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: invalid asset/provenance contract: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
