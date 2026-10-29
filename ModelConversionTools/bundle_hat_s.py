#!/usr/bin/env python3
"""Publish the exact losslessly sharded HAT-S pair after all eight full-reference gates.

No ML dependency is imported. All inputs, sources, cache/sample bindings and pre-existing
resources are checked before the first mutation. Inventory publication is the final write.
--models-dir supports a separate review tree; --reference-fixture can stage its fixture too.
"""
from __future__ import annotations

import argparse
import ast
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
from zipfile import ZipFile

from verify_production_assets import (
    ROOT, CHECKPOINTS, EXPECTED_IDENTIFIERS, HAT_REVISION, HAT_SOURCE_PATHS,
    NOTICE_SOURCES, directory_digest, sha256_file, source_path, validate_model_entry, verify,
)

POLICIES = ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all")
PATTERNS = {"black", "white", "near-black", "gradient", "checker", "luma-checker", "noise"}
SAMPLE_PATTERNS = {"gradient", "checker", "luma-checker"}
CONTROL_PATTERNS = {"black", "white", "near-black", "gradient"}
HAT_IDS = {f"HAT_S_x2_{size}" for size in (192, 256)}
OLD_IDS = EXPECTED_IDENTIFIERS - HAT_IDS
CHECKPOINT_FILE, CHECKPOINT_SHA = CHECKPOINTS["hat-s-2x"]
EDSR_SHA = CHECKPOINTS["edsr_baseline-2x"][1]
FILE_LIMIT = 96 * 1024 * 1024
OFFICIAL_REFERENCE = "Unmodified official FP32 HAT-S forward, original masks and nn.Unfold"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path):
    return json.loads(path.read_text())


def json_bytes(value) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()


def finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def digest_string(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix="." + path.name + ".", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def require_equal_if_present(path: Path, expected: bytes) -> None:
    require(not path.exists() or (path.is_file() and path.read_bytes() == expected),
            f"Review a differing existing HAT resource before replacement: {path}")


def npy_member(archive: ZipFile, name: str, expected_shape: tuple, expected_dtype: str) -> bytes:
    with archive.open(name) as handle:
        prefix = handle.read(8)
        require(prefix[:6] == b"\x93NUMPY" and prefix[6] in (1, 2, 3), f"Invalid NumPy cache header: {name}")
        header_size = 2 if prefix[6] == 1 else 4
        header_length = int.from_bytes(handle.read(header_size), "little")
        require(0 < header_length < 65536, f"Unbounded NumPy header: {name}")
        header = ast.literal_eval(handle.read(header_length).decode("utf-8"))
        require(header.get("descr") == expected_dtype and header.get("shape") == expected_shape
                and header.get("fortran_order") is False, f"Wrong full FP32 tensor contract: {name}")
        count = math.prod(expected_shape) if expected_shape else 1
        element_bytes = 4 if expected_dtype == "<f4" else int(expected_dtype[2:]) * 4
        expected_bytes = count * element_bytes
        require(expected_bytes <= 4 * 3 * 512 * 512, f"Unbounded reference cache tensor: {name}")
        data = handle.read(expected_bytes + 1)
        require(len(data) == expected_bytes, f"Wrong reference cache tensor byte count: {name}")
        return data


def verify_reference_cache(path: Path, size: int, samples: list[dict]) -> str:
    require(path.is_file(), f"Missing full official FP32 cache: {path}")
    with ZipFile(path) as archive:
        require(set(archive.namelist()) == {pattern + ".npy" for pattern in PATTERNS} | {"metadata.npy"},
                f"Full reference cache must contain all seven tensors: {path}")
        # Read the bounded scalar Unicode metadata using NumPy's documented header, without pickle
        # or numpy imports. Tensor bytes remain full Float32 and are never shared with conversion.
        with archive.open("metadata.npy") as handle:
            prefix = handle.read(8)
            require(prefix[:6] == b"\x93NUMPY" and prefix[6] in (1, 2, 3), "Invalid reference metadata header")
            width = 2 if prefix[6] == 1 else 4
            length = int.from_bytes(handle.read(width), "little")
            require(0 < length < 65536, "Unbounded reference metadata header")
            header = ast.literal_eval(handle.read(length).decode("utf-8"))
            dtype = header.get("descr", "")
            require(re.fullmatch(r"<U[0-9]+", dtype) is not None and header.get("shape") == ()
                    and header.get("fortran_order") is False, "Reference metadata must be a Unicode scalar")
            count = int(dtype[2:]) * 4
            require(0 < count < 65536, "Unbounded reference metadata")
            metadata_bytes = handle.read(count + 1)
            require(len(metadata_bytes) == count, "Wrong reference metadata byte count")
            metadata = json.loads(metadata_bytes.decode("utf-32-le"))
            require(metadata.get("checkpointSHA256") == CHECKPOINT_SHA
                    and metadata.get("revision") == HAT_REVISION and metadata.get("size") == size,
                    "Reference cache has a different official model/shape")
            require(set(metadata.get("inputSHA256", {})) == PATTERNS
                    and all(digest_string(v) for v in metadata["inputSHA256"].values()),
                    "Reference cache input hashes are missing")
        sample_map = {sample["pattern"]: sample for sample in samples}
        require(set(sample_map) == SAMPLE_PATTERNS and len(samples) == 3, "Three sampled patterns required")
        for pattern in sorted(PATTERNS):
            data = npy_member(archive, pattern + ".npy", (1, 3, size * 2, size * 2), "<f4")
            require(all(math.isfinite(v[0]) for v in struct.iter_unpack("<f", data)),
                    f"Non-finite official reference: {pattern}")
            if pattern in sample_map:
                sample = sample_map[pattern]
                expected_indices = [int(i * (len(data) // 4 - 1) / 1023) for i in range(1024)]
                require(sample.get("model") == f"HAT_S_x2_{size}" and sample.get("size") == size
                        and sample.get("indices") == expected_indices, "Wrong official sampled tensor indices")
                expected = [struct.unpack_from("<f", data, index * 4)[0] for index in expected_indices]
                require(sample.get("expected") == expected, "Sample fixture differs from full official FP32 tensor")
    return sha256_file(path)


def publish(converted_root: Path, validation_dir: Path, models_dir: Path, fixture_path: Path) -> None:
    provenance = models_dir / "Provenance"
    inventory = read_json(provenance / "model-inventory.json")
    existing = inventory["models"]
    require(len(existing) in (4, 6) and {row["identifier"] for row in existing} in (OLD_IDS, EXPECTED_IDENTIFIERS),
            "Start from the validated default/EDSR pairs or an identical completed bundle")
    require({p.stem for p in models_dir.glob("*.mlmodelc")} == {row["identifier"] for row in existing},
            "Existing compiled assets disagree with inventory")
    failures: list[str] = []
    for row in existing:
        validate_model_entry(row, inventory["checkpoints"], models_dir, failures)
    require(not failures, "; ".join(failures))
    checkpoint_path = ROOT / "ModelConversionTools/checkpoints" / CHECKPOINT_FILE
    require(sha256_file(checkpoint_path) == CHECKPOINT_SHA, "Official checkpoint hash differs")
    checkpoint_manifest_path = ROOT / "ModelConversionTools/hat-checkpoint-manifest.json"
    checkpoint_manifest = read_json(checkpoint_manifest_path)
    require(checkpoint_manifest["filename"] == CHECKPOINT_FILE and checkpoint_manifest["sha256"] == CHECKPOINT_SHA
            and checkpoint_manifest["bytes"] == checkpoint_path.stat().st_size, "Checkpoint manifest drift")
    checkpoint = {"file": CHECKPOINT_FILE, "sha256": CHECKPOINT_SHA,
                  "url": checkpoint_manifest["sourceURL"], "repo": "https://github.com/XPixelGroup/HAT",
                  "revision": HAT_REVISION, "license": "Apache-2.0"}
    checkpoints = dict(inventory["checkpoints"], **{"hat-s-2x": checkpoint})
    manifest_path = ROOT / "ModelConversionTools/vendor/hat/source-manifest.json"
    manifest = read_json(manifest_path)
    require(manifest["revision"] == HAT_REVISION and {e["path"] for e in manifest["files"]} == HAT_SOURCE_PATHS,
            "Pinned HAT source set differs")
    for entry in manifest["files"]:
        path = source_path(entry["path"])
        require(path.stat().st_size == entry["bytes"] and sha256_file(path) == entry["sha256"],
                "Pinned official source drift: " + entry["path"])
    resources = {"hat-source-manifest.json": manifest_path.read_bytes(),
                 "hat-checkpoint-manifest.json": checkpoint_manifest_path.read_bytes()}
    incoming, copied_assets, sample_cases, summaries = [], [], [], []
    for size in (192, 256):
        identifier = f"HAT_S_x2_{size}"
        directory = converted_root / f"publish-{size}"
        asset = directory / (identifier + ".mlmodelc")
        require(asset.is_dir(), f"Missing compiled final candidate: {asset}")
        conversion = read_json(directory / (identifier + ".conversion.json"))
        require(conversion["checkpointSHA256"] == CHECKPOINT_SHA and conversion["officialRevision"] == HAT_REVISION
                and conversion["parameters"] == 9473471 and conversion["precision"] == "fp32"
                and conversion["fullTorchLoweringMaxAbs"] == 0 and conversion["learnedWeightsPalettized"] is False,
                "Conversion must preserve the official trained model")
        layout = conversion["weightLayout"]
        require(layout["tensorBlobsVerifiedByteIdentical"] > 700 and layout["files"], "Missing exact blob-copy proof")
        weight_files = {p.name: {"bytes": p.stat().st_size, "sha256": sha256_file(p)}
                        for p in (asset / "weights").iterdir() if p.is_file()}
        require({p["file"]: p["bytes"] for p in layout["files"]}
                == {name: row["bytes"] for name, row in weight_files.items()}, "Compiled weight layout differs")
        require(all(p.stat().st_size < FILE_LIMIT for p in asset.rglob("*") if p.is_file()),
                "Compiled asset exceeds the ordinary Git file limit")
        samples = read_json(validation_dir / f"publish-reference-{size}.json")["cases"]
        cache_sha = verify_reference_cache(validation_dir / f"official-full-{size}.npz", size, samples)
        asset_sha = directory_digest(asset)
        for policy in POLICIES:
            path = validation_dir / f"publish-parity-{size}-{policy}.json"
            report = read_json(path)
            require(report.get("passed") is True and report.get("failures") == []
                    and report.get("model") == identifier and report.get("computeRequested") == policy
                    and report.get("checkpointSHA256") == CHECKPOINT_SHA
                    and report.get("officialRevision") == HAT_REVISION
                    and report.get("reference") == OFFICIAL_REFERENCE
                    and report.get("arithmeticPrecision") == "FLOAT32"
                    and report.get("fullOfficialFP32ReferenceCacheSHA256") == cache_sha
                    and report.get("compiledAssetDirectorySHA256") == asset_sha, "Wrong/incomplete final parity report")
            rows = report["cases"]
            require(len(rows) == 7 and {row["pattern"] for row in rows} == PATTERNS, "All seven fidelity cases required")
            for row in rows:
                require(row["model"] == identifier and row["size"] == size and row["units"] == policy
                        and row["referenceFinite"] is True and row["predictionFinite"] is True
                        and finite(row.get("psnr")) and row["psnr"] >= 50
                        and finite(row.get("maxAbs")) and row["maxAbs"] < 0.02,
                        "Full-tensor official fidelity gate failed")
                if row["pattern"] in CONTROL_PATTERNS:
                    require(row["productionReferenceRangeSafe"] and row["productionPredictionRangeSafe"],
                            "Ordinary model control is unsafe")
            resources[f"hat-official-parity-{size}-{policy}.json"] = path.read_bytes()
            summaries.append({"model": identifier, "computeRequested": policy,
                              "minimumPSNR": min(r["psnr"] for r in rows),
                              "maximumAbsoluteError": max(r["maxAbs"] for r in rows),
                              "compiledAssetDirectorySHA256": asset_sha})
        row = {"identifier": identifier, "asset": identifier + ".mlmodelc",
               "inputShape": [1, 3, size, size], "outputShape": [1, 3, size * 2, size * 2],
               "inputTensorName": "input_tile", "outputTensorName": "output_tile",
               "inputDataType": "Float16", "outputDataType": "Float16", "computePrecision": "FLOAT32",
               "assetDirectorySHA256": asset_sha, "weightBinSHA256": weight_files["weight.bin"]["sha256"],
               "weightFilesSHA256": {name: data["sha256"] for name, data in weight_files.items()},
               "checkpoint": "hat-s-2x", "checkpointSHA256": CHECKPOINT_SHA,
               "upstreamRepo": checkpoint["repo"], "upstreamRevision": HAT_REVISION,
               "license": "Apache-2.0", "productionRawPredictionRange": [-0.25, 1.25]}
        validate_model_entry(row, checkpoints, directory, failures)
        destination = models_dir / row["asset"]
        require(not destination.exists() or directory_digest(destination) == asset_sha, "Conflicting existing HAT asset")
        incoming.append(row)
        copied_assets.append((asset, destination))
        sample_cases.extend(samples)
        resources[f"hat-conversion-{size}.json"] = (directory / (identifier + ".conversion.json")).read_bytes()
        resources[f"hat-reference-samples-{size}.json"] = json_bytes({"cases": samples})
    require(not failures, "; ".join(failures))
    fixture = read_json(fixture_path)
    require(fixture["checkpoints"].get("EDSR_Baseline") == EDSR_SHA, "Existing EDSR fixture identity changed")
    edsr_cases = [c for c in fixture["cases"] if c["model"].startswith("EDSR_Baseline_")]
    require(len(edsr_cases) == 6, "Preserve all six existing EDSR reference cases")
    old_hat = [c for c in fixture["cases"] if c["model"].startswith("HAT_S_")]
    require(not old_hat or old_hat == sample_cases, "Conflicting existing HAT reference samples")
    fixture["cases"] = edsr_cases + sample_cases
    fixture["checkpoints"]["HAT_S"] = CHECKPOINT_SHA
    resources["hat-publishing-validation.json"] = json_bytes({"passed": True, "scope": "Mac conversion parity only",
        "gates": summaries, "phonePerformanceAndQuality": "NOT_MEASURED", "actualANEPlacement": "NOT_MEASURED"})
    notices = {name: (ROOT / relative).read_bytes() for name, relative in NOTICE_SOURCES.items() if name.startswith("HAT-S")}
    for name, data in resources.items():
        require_equal_if_present(provenance / name, data)
    for name, data in notices.items():
        require_equal_if_present(models_dir / "Notices" / name, data)
    # Only validated incoming assets are copied; untouched model bytes and their rows are retained.
    for source, destination in copied_assets:
        if not destination.exists():
            shutil.copytree(source, destination)
    for name, data in resources.items():
        atomic_bytes(provenance / name, data)
    for name, data in notices.items():
        atomic_bytes(models_dir / "Notices" / name, data)
    atomic_bytes(fixture_path, json_bytes(fixture))
    rows = [row for row in existing if row["identifier"] in OLD_IDS] + incoming
    inventory.update(models=rows, canonicalModelCount=6, checkpoints=checkpoints)
    atomic_bytes(provenance / "checkpoint-sha256.txt", "".join(
        c["sha256"] + "  " + c["file"] + "\n" for c in checkpoints.values()).encode())
    atomic_bytes(provenance / "model-inventory.json", json_bytes(inventory))
    require(verify(models_dir, ROOT / "ModelConversionTools/checkpoints", None) == 0, "Final asset audit failed")
    print("PASS: promoted two exact HAT-S assets, eight full-reference reports and six official sample cases")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--converted-root", type=Path, required=True)
    parser.add_argument("--validation-dir", type=Path, required=True)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "Targets/TruongScalerApp/Models")
    parser.add_argument("--reference-fixture", type=Path,
                        default=ROOT / "Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json")
    args = parser.parse_args()
    try:
        publish(args.converted_root, args.validation_dir, args.models_dir, args.reference_fixture)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("FAIL: refusing HAT-S publication: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
