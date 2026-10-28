#!/usr/bin/env python3
"""Verify the shipped trained Core ML assets, provenance and optional built app.

This script is intentionally dependency-free (Python standard library only). It checks the
canonical native 2× model inventory, per-asset directory digests, optional raw-checkpoint hashes,
and the same assets inside a built .app bundle. It never loads or substitutes stub models.

Usage:
  python3 ModelConversionTools/verify_production_assets.py \
      --checkpoints-dir ModelConversionTools/checkpoints \
      --built-app /tmp/.../TruongScalerApp.app
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / "Targets/TruongScalerApp/Models"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_digest(directory: Path) -> str:
    files = sorted(
        (p for p in directory.rglob("*") if p.is_file()),
        key=lambda p: p.relative_to(directory).as_posix(),
    )
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(directory).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def verify(models_dir: Path, checkpoints_dir: Path | None, built_app: Path | None) -> int:
    inventory_path = models_dir / "Provenance/model-inventory.json"
    inventory = json.loads(inventory_path.read_text())
    failures: list[str] = []

    if inventory.get("canonicalModelCount") != 4 or len(inventory.get("models", [])) != 4:
        failures.append("inventory must contain exactly four native 2× variants")
    identifiers = {entry["identifier"] for entry in inventory.get("models", [])}
    expected = {f"{family}_x2_{size}" for family in ("QuickSRNet_Large", "EDSR_Baseline") for size in (192, 256)}
    present = {p.stem for p in models_dir.glob("*.mlmodelc")}
    if present != expected:
        failures.append(f"unexpected compiled model tree: {sorted(present)}")
    if identifiers != expected:
        failures.append(f"unexpected identifiers: {sorted(identifiers)}")

    if built_app is not None and {p.stem for p in (built_app / "Models").glob("*.mlmodelc")} != expected:
        failures.append("built app contains missing or retired compiled models")

    for entry in inventory.get("models", []):
        asset = models_dir / entry["asset"]
        if not asset.is_dir():
            failures.append(f"missing compiled asset {asset}")
            continue
        actual = directory_digest(asset)
        if actual != entry["assetDirectorySHA256"]:
            failures.append(f"digest drift for {entry['identifier']}: {actual}")
        if built_app is not None:
            built_asset = built_app / "Models" / entry["asset"]
            if not built_asset.is_dir():
                failures.append(f"missing built app asset {built_asset}")
            elif directory_digest(built_asset) != entry["assetDirectorySHA256"]:
                failures.append(f"built app digest drift for {entry['identifier']}")

    if checkpoints_dir is not None:
        for name, checkpoint in inventory.get("checkpoints", {}).items():
            path = checkpoints_dir / checkpoint["file"]
            if not path.is_file():
                failures.append(f"missing raw checkpoint {path}")
                continue
            if sha256_file(path) != checkpoint["sha256"]:
                failures.append(f"checkpoint hash drift for {name}")

    source_manifest = models_dir / "Provenance/additional-source-manifest.json"
    if not source_manifest.is_file():
        failures.append("missing additional source manifest")
    else:
        for source in json.loads(source_manifest.read_text()):
            path = ROOT / source["localFile"]
            if not path.is_file() or sha256_file(path) != source["sha256"]:
                failures.append(f"vendored source digest drift: {path}")
    quick_sources = models_dir / "Provenance/upstream-source.json"
    if quick_sources.is_file():
        for source in json.loads(quick_sources.read_text())["files"]:
            path = ROOT / "ModelConversionTools/vendor/quicksr" / source["file"]
            if not path.is_file() or sha256_file(path) != source["sha256"]:
                failures.append(f"default source digest drift: {path}")

    for notice in ("QuickSRNet-LICENSE.txt", "EDSR-LICENSE.txt"):
        if not (models_dir / "Notices" / notice).is_file():
            failures.append(f"missing notice {notice}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print(f"PASS: 4 trained native 2× assets verified in {models_dir}")
    if checkpoints_dir is not None:
        print(f"PASS: raw checkpoint hashes verified in {checkpoints_dir}")
    if built_app is not None:
        print(f"PASS: built app Models tree matches all asset digests: {built_app}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS)
    parser.add_argument("--checkpoints-dir", type=Path, default=None)
    parser.add_argument("--built-app", type=Path, default=None)
    args = parser.parse_args()
    return verify(args.models_dir, args.checkpoints_dir, args.built_app)


if __name__ == "__main__":
    raise SystemExit(main())
