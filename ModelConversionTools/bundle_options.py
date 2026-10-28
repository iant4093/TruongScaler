#!/usr/bin/env python3
"""Merge fully validated optional variants into the canonical trained bundle.

Run convert_quicksr.py first for the default pair, then convert_options.py in a fresh output
directory. This command preserves the default assets and refuses unknown/stale extra assets.
An existing identical optional asset is left untouched; a different one must be reviewed before
replacement. Raw weights and Python dependencies are never copied into the app.
"""
import argparse,json,shutil,sys
from pathlib import Path
from convert_options import FAMILIES,ROOT,digest_directory

def main():
 p=argparse.ArgumentParser();p.add_argument('--converted',type=Path,required=True);p.add_argument('--models-dir',type=Path,default=ROOT/'Targets/TruongScalerApp/Models');a=p.parse_args()
 rows=json.loads((a.converted/'additional-models.json').read_text());expected={f'{f}_x2_{n}' for f in FAMILIES for n in [192,256]}
 assert {r['identifier'] for r in rows}==expected and len(rows)==2
 provenance=a.models_dir/'Provenance';inventory=json.loads((provenance/'model-inventory.json').read_text())
 defaults=[r for r in inventory['models'] if r['identifier'].startswith('QuickSRNet_Large_x2_')];assert len(defaults)==2
 allowed=expected|{r['identifier'] for r in defaults};assert {p.stem for p in a.models_dir.glob('*.mlmodelc')}<=allowed
 for r in defaults:assert digest_directory(a.models_dir/r['asset'])==r['assetDirectorySHA256']
 for r in rows:
  assert digest_directory(a.converted/r['asset'])==r['assetDirectorySHA256']
  dst=a.models_dir/r['asset']
  if dst.exists():assert digest_directory(dst)==r['assetDirectorySHA256'],'Review differing existing asset before replacement'
 for r in rows:
  dst=a.models_dir/r['asset']
  if not dst.exists():shutil.copytree(a.converted/r['asset'],dst)
 inventory.update(models=defaults+rows,canonicalModelCount=4,family='Native 2x trained model choices')
 for family,i in FAMILIES.items():inventory['checkpoints'][family.lower()+'-2x']=dict(file=i['checkpoint'],sha256=i['sha256'],url=i['url'],repo=i['repo'],revision=i['revision'],license=i['license'])
 for family,name in [('edsr','EDSR-LICENSE.txt')]:shutil.copy2(ROOT/'ModelConversionTools/vendor'/family/'LICENSE',a.models_dir/'Notices'/name)
 (provenance/'model-inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
 (provenance/'checkpoint-sha256.txt').write_text(''.join(i['sha256']+'  '+i['file']+'\n' for i in inventory['checkpoints'].values()))
 shutil.copy2(a.converted/'official-parity.json',provenance/'additional-official-parity.json')
 shutil.copy2(a.converted/'reference-samples.json',ROOT/'Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json')
 print('PASS: default pair preserved, two validated optional variants merged')
if __name__=='__main__':main()
