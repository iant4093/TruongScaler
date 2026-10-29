#!/usr/bin/env python3
"""Merge a validated EDSR pair without discarding an already validated HAT-S pair.

The transitional QuickSRNet+EDSR bundle may contain four variants while model work is in
progress; the production verifier independently requires all six. Existing weights and HAT
provenance/notices are never overwritten. This tool imports no ML/conversion dependencies.
As before, the EDSR reference fixture is refreshed in the repository even with --models-dir.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from verify_production_assets import (
    ROOT, CHECKPOINTS, EXPECTED_IDENTIFIERS, FAMILIES, NOTICE_SOURCES, directory_digest, sha256_file,
    validate_model_entry, verify_hat_sources,
)

EDSR_CHECKPOINT = {
    "file": CHECKPOINTS["edsr_baseline-2x"][0], "sha256": CHECKPOINTS["edsr_baseline-2x"][1],
    "url": "http://cv.snu.ac.kr/research/EDSR/models/edsr_baseline_x2-1bc95232.pt",
    "repo": "https://github.com/sanghyun-son/EDSR-PyTorch",
    "revision": "8dba5581a7502b92de9641eb431130d6c8ca5d7f", "license": "MIT",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def atomic_text(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text)
    temporary.replace(path)


def bundle(converted: Path, models_dir: Path) -> None:
    incoming = json.loads((converted / "additional-models.json").read_text())
    incoming_ids = {f"EDSR_Baseline_x2_{size}" for size in (192, 256)}
    require(isinstance(incoming, list) and len(incoming) == 2 and
            {row.get("identifier") for row in incoming} == incoming_ids,
            "The EDSR converter must provide exactly its two native2× shapes")
    provenance = models_dir / "Provenance"
    inventory = json.loads((provenance / "model-inventory.json").read_text())
    existing = inventory["models"]
    existing_ids = {row["identifier"] for row in existing}
    require(len(existing_ids) == len(existing) and existing_ids <= EXPECTED_IDENTIFIERS,
            "Existing inventory has duplicate or unknown model identities")
    require({f"QuickSRNet_Large_x2_{size}" for size in (192, 256)} <= existing_ids,
            "The validated default pair must be bundled first")
    for family in FAMILIES:
        count = len([row for row in existing if row["identifier"].startswith(family + "_x2_")])
        require(count in (0, 2), f"Refusing a partial existing {family} pair")
    present = {path.stem for path in models_dir.glob("*.mlmodelc")}
    require(existing_ids <= present and present <= existing_ids | incoming_ids,
            "Compiled assets and the existing inventory disagree or include an unknown model")
    checkpoints = dict(inventory.get("checkpoints", {}))
    checkpoints["edsr_baseline-2x"] = EDSR_CHECKPOINT
    failures: list[str] = []
    for row in existing:
        validate_model_entry(row, checkpoints, models_dir, failures)
    for row in incoming:
        validate_model_entry(row, checkpoints, converted, failures)
        destination = models_dir / row["asset"]
        if destination.exists() and directory_digest(destination) != row["assetDirectorySHA256"]:
            failures.append(f"Review differing existing asset before replacement: {destination}")
    if any(identifier.startswith("HAT_S_") for identifier in existing_ids):
        verify_hat_sources(models_dir, failures)
        for notice in ("HAT-S-LICENSE.txt", "HAT-S-BasicSR-LICENSE.txt", "HAT-S-timm-LICENSE.txt"):
            path = models_dir / "Notices" / notice
            require(path.is_file() and sha256_file(path) == sha256_file(ROOT / NOTICE_SOURCES[notice]),
                    f"Existing HAT-S notice is missing or changed: {notice}")
    require(not failures, "; ".join(failures))
    # Parse all metadata inputs before copying any model or publishing an inventory.
    json.loads((converted / "official-parity.json").read_text())
    incoming_reference = json.loads((converted / "reference-samples.json").read_text())
    fixture_path = ROOT / "Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json"
    existing_reference = json.loads(fixture_path.read_text())
    preserved_cases = [row for row in existing_reference["cases"] if row["model"].startswith("HAT_S_")]
    require(all(row["model"].startswith("EDSR_Baseline_") for row in incoming_reference["cases"]),
            "The EDSR converter reference fixture must contain only EDSR cases")
    if preserved_cases:
        require(len(preserved_cases) == 6 and existing_reference["checkpoints"].get("HAT_S") == CHECKPOINTS["hat-s-2x"][1],
                "Existing HAT reference cases are incomplete or unpinned")
        incoming_reference["cases"].extend(preserved_cases)
        incoming_reference["checkpoints"]["HAT_S"] = CHECKPOINTS["hat-s-2x"][1]
    license_file = ROOT / "ModelConversionTools/vendor/edsr/LICENSE"
    require(license_file.is_file(), "The official EDSR license is missing")

    for row in incoming:
        destination = models_dir / row["asset"]
        if not destination.exists():
            shutil.copytree(converted / row["asset"], destination)
    # Merge by identity, retaining HAT-S facts and every untouched family verbatim. In particular,
    # never reconstruct the inventory from only QuickSRNet+EDSR when HAT-S is already present.
    merged = {row["identifier"]: row for row in existing}
    merged.update({row["identifier"]: row for row in incoming})
    order = {family: index for index, family in enumerate(FAMILIES)}
    rows = sorted(merged.values(), key=lambda row: (
        order[row["identifier"].rsplit("_x2_", 1)[0]], int(row["identifier"].rsplit("_", 1)[1])))
    inventory.update(models=rows, canonicalModelCount=len(rows), family="Native 2x trained model choices",
                     checkpoints=checkpoints)
    (models_dir / "Notices").mkdir(exist_ok=True)
    shutil.copy2(license_file, models_dir / "Notices/EDSR-LICENSE.txt")
    shutil.copy2(converted / "official-parity.json", provenance / "additional-official-parity.json")
    atomic_text(fixture_path, json.dumps(incoming_reference, indent=2) + "\n")
    atomic_text(provenance / "checkpoint-sha256.txt", "".join(
        checkpoint["sha256"] + "  " + checkpoint["file"] + "\n" for checkpoint in checkpoints.values()))
    atomic_text(provenance / "model-inventory.json", json.dumps(inventory, indent=2) + "\n")
    print(f"PASS: validated EDSR pair merged; {len(rows)} variants retained, including any existing HAT-S pair")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--converted", type=Path, required=True)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "Targets/TruongScalerApp/Models")
    args = parser.parse_args()
    try:
        bundle(args.converted, args.models_dir)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: refusing optional-model merge: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
