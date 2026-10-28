#!/usr/bin/env python3
"""Convert official native 2x EDSR-baseline weights; no synthetic reference models.

Vendored architecture files remain byte-identical to pinned upstream. EDSR uses the author's RGB range of 255.
All layers retain FP32 arithmetic, with FP16 input/output tensors, to avoid the FP16 EDSR
high-frequency parity error found in evaluation. Raw predictions are not clipped by conversion.
"""
import argparse,copy,importlib.util,json,sys,time,types,subprocess
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from convert_quicksr import sha,digest_directory,ROOT

FAMILIES={
 'EDSR_Baseline':dict(checkpoint='edsr-baseline-x2.pt',sha256='1bc9523228fdc3b0a5ddb0d7062001e22b31bbb398ae09cfdefb97e8ee06e171',
  url='http://cv.snu.ac.kr/research/EDSR/models/edsr_baseline_x2-1bc95232.pt',repo='https://github.com/sanghyun-son/EDSR-PyTorch',revision='8dba5581a7502b92de9641eb431130d6c8ca5d7f',license='MIT'),}


def module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m

def reference(family):
 info=FAMILIES[family];checkpoint=ROOT/'ModelConversionTools/checkpoints'/info['checkpoint'];assert sha(checkpoint)==info['sha256']
 if family=='EDSR_Baseline':
  sys.modules['model']=types.ModuleType('model');common=module('model.common',ROOT/'ModelConversionTools/vendor/edsr/common.py');sys.modules['model'].common=common
  arch=module('official_edsr',ROOT/'ModelConversionTools/vendor/edsr/edsr.py')
  model=arch.EDSR(types.SimpleNamespace(n_resblocks=16,n_feats=64,scale=[2],n_colors=3,rgb_range=255,res_scale=1)).eval()
  # Bypass the author's permissive tail loader: every key and shape must match strictly.
  torch.nn.Module.load_state_dict(model,torch.load(checkpoint,map_location='cpu',weights_only=True),strict=True)
  class Domain(torch.nn.Module):
   def __init__(self,m):super().__init__();self.model=m
   def forward(self,x):return self.model(x*255)/255
  return Domain(model).eval()
 raise ValueError(f'Unsupported model: {family}')

def deployment(family,model):
 return copy.deepcopy(model).eval()


def patterns(size):
 axis=np.linspace(0,1,size,dtype=np.float32);xx,yy=np.meshgrid(axis,axis);checker=(np.indices((size,size)).sum(0)%2).astype(np.float32)
 return {'black':np.zeros((1,3,size,size),np.float16),'white':np.ones((1,3,size,size),np.float16),
  'near-black':np.full((1,3,size,size),.0001,np.float16),'gradient':np.stack([xx,yy,1-xx])[None].astype(np.float16),
  'checker':np.stack([checker,1-checker,checker])[None].astype(np.float16),
  'luma-checker':np.stack([checker,checker,checker])[None].astype(np.float16),
  'noise':np.random.default_rng(20261024).uniform(0,1,(1,3,size,size)).astype(np.float16)}

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
 manifest=ROOT/'Targets/TruongScalerApp/Models/Provenance/additional-source-manifest.json'
 for item in json.loads(manifest.read_text()):assert sha(ROOT/item['localFile'])==item['sha256'],item
 torch.set_num_threads(4);torch.set_num_interop_threads(1);rows=[];parity=[];samples=[]
 for family,info in FAMILIES.items():
  model=reference(family);deploy=deployment(family,model)
  for size in [192,256]:
   cases=patterns(size);refs={}
   for name,x in cases.items():
    with torch.inference_mode():y=model(torch.from_numpy(x.astype(np.float32))).numpy();yd=deploy(torch.from_numpy(x.astype(np.float32))).numpy()
    assert y.shape==(1,3,size*2,size*2) and np.isfinite(y).all();assert float(np.abs(y-yd).max())<.0001
    refs[name]=y
    if name in ['gradient','checker','luma-checker']:
     indices=np.linspace(0,y.size-1,1024,dtype=int).tolist()
     samples.append(dict(model=f'{family}_x2_{size}',size=size,pattern=name,indices=indices,expected=y.flatten()[indices].tolist()))
   ident=f'{family}_x2_{size}';package=args.output/(ident+'.mlpackage')
   assert not package.exists(),'Use a fresh output directory to avoid stale precision/weights'
   traced=torch.jit.trace(deploy,torch.from_numpy(cases['gradient'].astype(np.float32)))
   converted=ct.convert(traced,convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,
    inputs=[ct.TensorType(name='input_tile',shape=(1,3,size,size),dtype=np.float16)],outputs=[ct.TensorType(name='output_tile',dtype=np.float16)],
    compute_precision=ct.precision.FLOAT32,skip_model_load=True)
   converted.short_description=f'Official trained {family} native 2x; raw normalized transfer-domain RGB predictions.'
   converted.user_defined_metadata['checkpointSHA256']=info['sha256'];converted.save(str(package))
   subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(args.output)],check=True)
   compiled=args.output/(ident+'.mlmodelc')
   for backend,units in [('cpu_and_ne',ct.ComputeUnit.CPU_AND_NE),('cpu_only',ct.ComputeUnit.CPU_ONLY),('all',ct.ComputeUnit.ALL),('cpu_and_gpu',ct.ComputeUnit.CPU_AND_GPU)]:
    core=ct.models.CompiledMLModel(str(compiled),compute_units=units)
    for name,x in cases.items():
     t=time.perf_counter();y=np.asarray(core.predict({'input_tile':x})['output_tile'],np.float32);seconds=time.perf_counter()-t
     assert y.shape==refs[name].shape and np.isfinite(y).all()
     d=y.astype(np.float64)-refs[name];psnr=float(-10*np.log10(max(float((d*d).mean()),1e-20)));maximum=float(np.abs(d).max())
     row=dict(model=ident,pattern=name,backendRequested=backend,psnrDB=psnr,maxError=maximum,min=float(y.min()),max=float(y.max()),seconds=seconds)
     parity.append(row);print(row,flush=True);assert psnr>=50 and maximum<.02,row
    del core
   rows.append(dict(identifier=ident,asset=compiled.name,inputShape=[1,3,size,size],outputShape=[1,3,size*2,size*2],inputTensorName='input_tile',outputTensorName='output_tile',inputDataType='Float16',outputDataType='Float16',computePrecision='FLOAT32',assetDirectorySHA256=digest_directory(compiled),weightBinSHA256=sha(compiled/'weights/weight.bin'),checkpoint=family.lower()+'-2x',checkpointSHA256=info['sha256'],upstreamRepo=info['repo'],upstreamRevision=info['revision'],license=info['license'],productionRawPredictionRange=[-.25,1.25]))
  del model,deploy
 (args.output/'additional-models.json').write_text(json.dumps(rows,indent=2)+'\n')
 (args.output/'official-parity.json').write_text(json.dumps(parity,indent=2)+'\n')
 (args.output/'reference-samples.json').write_text(json.dumps(dict(checkpoints={f:i['sha256'] for f,i in FAMILIES.items()},cases=samples),separators=(',',':'))+'\n')
 print('PASS',len(rows),'models',len(parity),'full reference comparisons',flush=True)
if __name__=='__main__':main()
