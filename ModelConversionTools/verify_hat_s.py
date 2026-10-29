#!/usr/bin/env python3
"""Full-tensor official FP32 HAT-S parity for one real compiled Core ML candidate."""
import argparse
import gc
import json
import math
from pathlib import Path
import time
from hat_reference import load_reference, CHECKPOINT_SHA256, REVISION, sha, verify_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', type=int, choices=(192,256), required=True)
    parser.add_argument('--model', type=Path)
    parser.add_argument('--compute-unit', choices=('cpuOnly','cpuAndGPU','cpuAndNeuralEngine','all'), default='cpuOnly')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--samples', type=Path)
    parser.add_argument('--reference-cache', type=Path)
    parser.add_argument('--generate-reference-only', action='store_true')
    args = parser.parse_args()
    import numpy as np
    verify_sources()
    size = args.size
    axis = np.linspace(0,1,size,dtype=np.float32)
    xx, yy = np.meshgrid(axis,axis)
    checker = (np.indices((size,size)).sum(0)%2).astype(np.float32)
    cases = {'black':np.zeros((1,3,size,size),np.float16),
        'white':np.ones((1,3,size,size),np.float16),
        'near-black':np.full((1,3,size,size),.0001,np.float16),
        'gradient':np.stack([xx,yy,1-xx])[None].astype(np.float16),
        'checker':np.stack([checker,1-checker,checker])[None].astype(np.float16),
        'luma-checker':np.stack([checker]*3)[None].astype(np.float16),
        'noise':np.random.default_rng(20261024).uniform(0,1,(1,3,size,size)).astype(np.float16)}
    import hashlib
    expected_inputs = {name:hashlib.sha256(value.tobytes()).hexdigest() for name,value in cases.items()}
    metadata = {'checkpointSHA256':CHECKPOINT_SHA256,'revision':REVISION,'size':size,'inputSHA256':expected_inputs}
    if args.generate_reference_only:
        if args.reference_cache is None or args.reference_cache.exists():
            raise RuntimeError('Provide a fresh --reference-cache path')
        import torch
        torch.set_num_threads(2)
        torch.set_num_interop_threads(1)
        reference = load_reference() # original upstream forward, mask and nn.Unfold
        values = {}
        for name,value in cases.items():
            with torch.inference_mode():
                values[name] = reference(torch.from_numpy(value.astype(np.float32))).numpy()
            if values[name].dtype != np.float32 or not np.isfinite(values[name]).all():
                raise RuntimeError('Invalid official FP32 reference: '+name)
            print('Official full FP32 reference:',name,flush=True)
        args.reference_cache.parent.mkdir(parents=True,exist_ok=True)
        np.savez_compressed(args.reference_cache,metadata=np.asarray(json.dumps(metadata,sort_keys=True)),**values)
        print(json.dumps({'referenceCacheSHA256':sha(args.reference_cache),'cases':len(values)}),flush=True)
        return 0
    reference = None
    cache = None
    if args.reference_cache:
        cache = np.load(args.reference_cache,allow_pickle=False)
        if json.loads(str(cache['metadata'])) != metadata:
            raise RuntimeError('Reference cache does not match official checkpoint/shape/inputs')
    else:
        import torch
        torch.set_num_threads(2)
        torch.set_num_interop_threads(1)
        reference = load_reference()
    if args.model is None or args.report is None:
        raise RuntimeError('--model and --report are required for prediction verification')
    import coremltools as ct
    policies = {'cpuOnly':ct.ComputeUnit.CPU_ONLY, 'cpuAndGPU':ct.ComputeUnit.CPU_AND_GPU,
                'cpuAndNeuralEngine':ct.ComputeUnit.CPU_AND_NE,'all':ct.ComputeUnit.ALL}
    model_type = ct.models.CompiledMLModel if args.model.suffix == '.mlmodelc' else ct.models.MLModel
    started = time.perf_counter()
    model = model_type(str(args.model), compute_units=policies[args.compute_unit])
    load_seconds = time.perf_counter() - started
    rows, samples, failures = [], [], []
    for name, value in cases.items():
        started = time.perf_counter()
        if cache is not None:
            expected = cache[name]
            if expected.dtype != np.float32:
                raise RuntimeError('Reference cache lost official FP32 precision')
        else:
            with torch.inference_mode():
                expected = reference(torch.from_numpy(value.astype(np.float32))).numpy()
        reference_seconds = time.perf_counter() - started
        started = time.perf_counter()
        actual = np.asarray(model.predict({'input_tile':value})['output_tile'])
        prediction_seconds = time.perf_counter() - started
        shape = (1,3,size*2,size*2)
        if expected.shape != shape or actual.shape != shape:
            raise RuntimeError(f'Invalid native2x shapes: {expected.shape}, {actual.shape}')
        finite_ref, finite_pred = bool(np.isfinite(expected).all()), bool(np.isfinite(actual).all())
        reference_safe = finite_ref and bool(np.all((expected>=-.25)&(expected<=1.25)))
        actual_safe = finite_pred and bool(np.all((actual>=-.25)&(actual<=1.25)))
        row = {'model':f'HAT_S_x2_{size}','size':size,'units':args.compute_unit,'pattern':name,
            'referenceSeconds':reference_seconds,'predictionSeconds':prediction_seconds,
            'referenceFinite':finite_ref,'predictionFinite':finite_pred,
            'referenceMin':float(np.nanmin(expected)),'referenceMax':float(np.nanmax(expected)),
            'productionReferenceRangeSafe':reference_safe,'productionPredictionRangeSafe':actual_safe}
        if finite_ref and finite_pred:
            error = actual.astype(np.float64) - expected.astype(np.float64)
            mse = float(np.mean(error*error))
            row.update(psnr=120. if mse==0 else -10*math.log10(mse),maxAbs=float(np.max(np.abs(error))))
            if row['psnr'] < 50 or row['maxAbs'] >= .02:
                failures.append(name+'-fidelity')
        elif reference_safe or actual_safe:
            failures.append(name+'-invalid-prediction')
        else:
            row['status'] = 'REQUIRES_SAFE_REFUSAL'
        if name in ('gradient','checker','luma-checker') and finite_ref:
            indices = np.linspace(0,expected.size-1,1024,dtype=int).tolist()
            samples.append({'model':row['model'],'size':size,'pattern':name,'indices':indices,
                            'expected':expected.flatten()[indices].tolist()})
        rows.append(row)
        print(json.dumps(row),flush=True)
    warm = []
    for _ in range(3):
        started = time.perf_counter()
        value = model.predict({'input_tile':cases['gradient']})['output_tile']
        warm.append(time.perf_counter()-started)
        if not np.isfinite(value).all():
            failures.append('warm-nonfinite')
    report = {'model':f'HAT_S_x2_{size}','checkpointSHA256':CHECKPOINT_SHA256,'officialRevision':REVISION,
        'reference':'Unmodified official FP32 HAT-S forward, original masks and nn.Unfold',
        'scope':'Mac full-tensor Core ML predictions; phone/ANE placement/image quality not measured',
        'computeRequested':args.compute_unit,'arithmeticPrecision':'FLOAT32','loadSeconds':load_seconds,
        'warmPredictionSeconds':warm,'cases':rows,'failures':failures,'passed':not failures,
        'gate':{'minimumPSNR':50,'maximumAbsoluteErrorExclusive':.02}}
    if args.reference_cache:
        report['fullOfficialFP32ReferenceCacheSHA256'] = sha(args.reference_cache)
        report['referenceStorage'] = 'Full FP32 tensors, lossless NPZ; validated input hashes; no reference graph shared with conversion'
    digest = hashlib.sha256()
    for path in sorted(p for p in args.model.rglob('*') if p.is_file()):
        digest.update(path.relative_to(args.model).as_posix().encode()+b'\0'+sha(path).encode()+b'\n')
    report['compiledAssetDirectorySHA256'] = digest.hexdigest()
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    if args.samples:
        args.samples.parent.mkdir(parents=True,exist_ok=True)
        args.samples.write_text(json.dumps({'cases':samples},separators=(',',':'))+'\n')
    print(json.dumps({'passed':not failures,'loadSeconds':load_seconds,'warmSeconds':warm,'failures':failures}),flush=True)
    del model,reference,cases
    gc.collect()
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
