"""Pinned official HAT-S native2× reference. No ML import occurs for provenance-only tools."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'ModelConversionTools/vendor/hat'
CHECKPOINT_SHA256 = '3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf'
REVISION = '1638a9a822581657811867bf670717f8371fc3e5'


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def verify_sources():
    for entry in json.loads((VENDOR / 'source-manifest.json').read_text())['files']:
        if sha(ROOT / entry['path']) != entry['sha256']:
            raise RuntimeError('Official HAT/support source drift: ' + entry['path'])


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def load_reference():
    import collections
    import itertools
    import math
    import warnings
    import torch
    verify_sources()
    checkpoint = ROOT / 'ModelConversionTools/checkpoints/HAT-S_SRx2.pth'
    if sha(checkpoint) != CHECKPOINT_SHA256:
        raise RuntimeError('Official HAT-S checkpoint hash mismatch')
    for name in ('basicsr', 'basicsr.utils', 'basicsr.archs'):
        package = types.ModuleType(name)
        package.__path__ = []
        sys.modules[name] = package
    module('basicsr.utils.registry', VENDOR / 'basicsr/registry.py')
    # Execute the byte-unmodified upstream helper function bodies without importing BasicSR's
    # unrelated training/deformable-convolution plugins. No learned architecture is reimplemented.
    path = VENDOR / 'basicsr/arch_util.py'
    tree = ast.parse(path.read_text(), filename=str(path))
    functions = {'_no_grad_trunc_normal_', 'trunc_normal_', '_ntuple'}
    selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in functions]
    selected += [node for node in tree.body if isinstance(node, ast.Assign)
                 and any(isinstance(target, ast.Name) and target.id == 'to_2tuple' for target in node.targets)]
    helpers = types.ModuleType('basicsr.archs.arch_util')
    helpers.__dict__.update(torch=torch, math=math, warnings=warnings, collections=collections, repeat=itertools.repeat)
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), helpers.__dict__)
    sys.modules[helpers.__name__] = helpers
    architecture = module('official_hat_reference', VENDOR / 'hat_arch.py')
    model = architecture.HAT(upscale=2, in_chans=3, img_size=64, window_size=16,
        compress_ratio=24, squeeze_factor=24, conv_scale=0.01, overlap_ratio=0.5,
        img_range=1., depths=[6,6,6,6,6,6], embed_dim=144, num_heads=[6,6,6,6,6,6],
        mlp_ratio=2, upsampler='pixelshuffle', resi_connection='1conv').eval()
    loaded = torch.load(checkpoint, map_location='cpu', weights_only=True)
    model.load_state_dict(loaded['params_ema'], strict=True)
    for parameter in model.parameters():
        if not torch.isfinite(parameter).all():
            raise RuntimeError('Non-finite official trained parameter')
    return model
