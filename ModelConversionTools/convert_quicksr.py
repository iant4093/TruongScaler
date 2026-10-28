#!/usr/bin/env python3
"""Convert the official trained native 2× checkpoint; verify all production compute policies."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import subprocess
import time
import numpy as np
import torch
import coremltools as ct
from vendor.quicksr.models import QuickSRNetLarge

ROOT = Path(__file__).resolve().parents[1]
CHECKPOINT_SHA = "0c6e0f4e2b444b161d6bce22852b0e2aa0dc391ef804c99e867882dd9715ad9d"
CHECKPOINT_URL = "https://github.com/quic/aimet-model-zoo/releases/download/phase_2_january_artifacts/quicksrnet_large_2x_checkpoint_float32.pth.tar"

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()

def digest_directory(path):
    digest = hashlib.sha256()
    for file in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(file.relative_to(path).as_posix().encode() + b"\0")
        digest.update(sha(file).encode() + b"\n")
    return digest.hexdigest()

def reference(checkpoint):
    assert sha(checkpoint) == CHECKPOINT_SHA, "Official checkpoint digest mismatch"
    model = QuickSRNetLarge(scaling_factor=2).eval()
    with torch.serialization.safe_globals([torch.optim.Adam, collections.defaultdict, dict]):
        state = torch.load(checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(state["state_dict"], strict=True)
    return model

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, default=ROOT/"ModelConversionTools/checkpoints/quicksrnet-large-2x.pth")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4); torch.set_num_interop_threads(1)
    model = reference(args.checkpoint)
    rows, parity = [], []
    for size in (192, 256):
        identifier = f"QuickSRNet_Large_x2_{size}"
        axis = np.linspace(0, 1, size, dtype=np.float32); xx, yy = np.meshgrid(axis, axis)
        checker = (np.indices((size,size)).sum(axis=0) % 2).astype(np.float32)
        patterns = {"black":np.zeros((1,3,size,size),np.float16), "white":np.ones((1,3,size,size),np.float16),
                    "near-black":np.full((1,3,size,size),0.0001,np.float16),
                    "gradient":np.stack([xx,yy,1-xx])[None].astype(np.float16),
                    "checker":np.stack([checker,1-checker,checker])[None].astype(np.float16),
                    "noise":np.random.default_rng(20261024).uniform(0,1,(1,3,size,size)).astype(np.float16)}
        example = torch.from_numpy(patterns["gradient"].astype(np.float32))
        package = args.output / (identifier + ".mlpackage")
        if not package.exists():
            traced = torch.jit.trace(model, example)
            converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                inputs=[ct.TensorType(name="input_tile",shape=(1,3,size,size),dtype=np.float16)],
                outputs=[ct.TensorType(name="output_tile",dtype=np.float16)],compute_precision=ct.precision.FLOAT16,
                skip_model_load=True)
            converted.short_description = "Official trained QuickSRNet-Large native 2×; normalized transfer-encoded input."
            converted.user_defined_metadata["checkpointSHA256"] = CHECKPOINT_SHA
            converted.save(str(package))
        compiled = args.output / (identifier + ".mlmodelc")
        if not compiled.exists():
            subprocess.run(["xcrun","coremlcompiler","compile",str(package),str(args.output)],check=True)
        with torch.inference_mode():
            references = {name:model(torch.from_numpy(x.astype(np.float32))).numpy() for name,x in patterns.items()}
        for backend, units in [("all",ct.ComputeUnit.ALL),("cpu_and_ne",ct.ComputeUnit.CPU_AND_NE),
                               ("cpu_and_gpu",ct.ComputeUnit.CPU_AND_GPU),("cpu_only",ct.ComputeUnit.CPU_ONLY)]:
            core = ct.models.CompiledMLModel(str(compiled),compute_units=units)
            for name, data in patterns.items():
                started=time.perf_counter(); output=np.asarray(core.predict({"input_tile":data})["output_tile"],np.float32)
                seconds=time.perf_counter()-started
                assert output.shape == (1,3,size*2,size*2) and np.isfinite(output).all()
                delta=output.astype(np.float64)-references[name].astype(np.float64)
                psnr=float(-10*np.log10(max(float(np.mean(delta*delta)),1e-20)))
                maximum=float(np.max(np.abs(delta)))
                parity.append(dict(model=identifier,backendRequested=backend,pattern=name,psnrDB=psnr,maxError=maximum,seconds=seconds))
                assert psnr >= 50 and maximum < 0.02, parity[-1]
            del core
        rows.append(dict(identifier=identifier,asset=compiled.name,inputShape=[1,3,size,size],outputShape=[1,3,size*2,size*2],
            inputTensorName="input_tile",outputTensorName="output_tile",inputDataType="Float16",outputDataType="Float16",
            computePrecision="FLOAT16",assetDirectorySHA256=digest_directory(compiled),
            weightBinSHA256=sha(compiled/"weights/weight.bin"),checkpoint="quicksrnet-large-2x",
            checkpointSHA256=CHECKPOINT_SHA,upstreamRepo="https://github.com/quic/aimet-model-zoo",
            upstreamRevision="1bd2bf5b17cdda9251437c444009b29e1a25054b",license="BSD-3-Clause"))
    inventory=dict(schemaVersion=2,canonicalModelCount=2,family="QuickSRNet-Large",nativeScale=2,models=rows,
        checkpoints={"quicksrnet-large-2x":dict(file=args.checkpoint.name,sha256=CHECKPOINT_SHA,url=CHECKPOINT_URL,
            repo="https://github.com/quic/aimet-model-zoo",revision="1bd2bf5b17cdda9251437c444009b29e1a25054b",license="BSD-3-Clause")})
    (args.output/"model-inventory.json").write_text(json.dumps(inventory,indent=2)+"\n")
    (args.output/"official-parity.json").write_text(json.dumps(parity,indent=2)+"\n")
    print(f"PASS: {len(rows)} native 2× variants, {len(parity)} official-reference predictions, minimum PSNR {min(r['psnrDB'] for r in parity):.2f} dB")

if __name__ == "__main__": main()
