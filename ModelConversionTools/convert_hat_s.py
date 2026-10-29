#!/usr/bin/env python3
"""Convert the official trained native2× HAT-S graph to a fresh candidate directory."""
import argparse
import copy
import gc
import json
from pathlib import Path
import time
import types
from hat_reference import load_reference, CHECKPOINT_SHA256, REVISION


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', type=int, choices=(192,256), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--precision', choices=('fp32','fp16'), default='fp32')
    parser.add_argument('--metadata-only', action='store_true')
    args = parser.parse_args()
    import numpy as np
    import torch
    import coremltools as ct
    # coremltools9's scalar cast predates NumPy2.5's rejection of int(array([value])).
    # Repair only this compile-time scalar bridge in this conversion process, not installed files.
    from coremltools.converters.mil.frontend.torch import ops as torch_ops
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
    from coremltools.converters.mil import Builder as mb
    original_int = torch_ops._int
    @register_torch_op(torch_alias=['_int', 'int'], override=True)
    def scalar_int_compat(context, node):
        value = torch_ops._get_inputs(context, node, expected=1)[0]
        if value.can_be_folded_to_const() and np.asarray(value.val).size == 1:
            context.add(mb.const(val=int(np.asarray(value.val).item()), name=node.name), node.name)
        else:
            original_int(context, node)
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    model = load_reference()
    parameters = sum(p.numel() for p in model.parameters())
    print(json.dumps({'model':'HAT-S','nativeScale':2,'parameters':parameters,
                      'checkpointSHA256':CHECKPOINT_SHA256,'officialRevision':REVISION}), flush=True)
    if args.metadata_only:
        return
    args.output.mkdir(parents=True, exist_ok=True)
    package = args.output / f'HAT_S_x2_{args.size}.mlpackage'
    if package.exists():
        raise RuntimeError('Use a fresh output directory; no trained candidate is overwritten')
    # Only the conversion instance caches the exact official fixed-shape attention mask. The
    # independent reference retains its original calculate_mask/forward methods.
    conversion = copy.deepcopy(model).eval()
    # Mask entries are exactly0/-100. Store FP16 and promote in attention instead of shipping a
    # large Float32 activation as if it were a learned weight.
    conversion.register_buffer('fixed_attention_mask', conversion.calculate_mask((args.size,args.size)).half())
    conversion.calculate_mask = types.MethodType(lambda self, x_size: self.fixed_attention_mask, conversion)
    class SharedSpatialUnfold(torch.nn.Module):
        """Exact nn.Unfold using one spatial index vector shared across channels.

        Coremltools9 lowers ordinary im2col to a dense mostly-zero convolution weight whose shape
        here would be[165888,288,24,24] (>100GiB). Spatial gather keeps the same ordering/zero pad
        without allocating that tensor. Official reference uses its original nn.Unfold.
        """
        def __init__(self, original, side):
            super().__init__()
            kernel = original.kernel_size[0] if isinstance(original.kernel_size, tuple) else original.kernel_size
            stride = original.stride[0] if isinstance(original.stride, tuple) else original.stride
            padding = original.padding[0] if isinstance(original.padding, tuple) else original.padding
            self.padding = padding
            self.side = side
            self.kernel = kernel
            self.windows_per_axis = (side + 2 * padding - kernel) // stride + 1
            self.windows = self.windows_per_axis ** 2
            padded = side + 2 * padding
            dy, dx = torch.meshgrid(torch.arange(kernel),torch.arange(kernel),indexing='ij')
            by, bx = torch.meshgrid(torch.arange(self.windows_per_axis),torch.arange(self.windows_per_axis),indexing='ij')
            offsets = (dy * padded + dx).reshape(-1,1)
            bases = (by * stride * padded + bx * stride).reshape(1,-1)
            self.register_buffer('spatial_indices', (offsets + bases).reshape(-1))
        def forward(self, value):
            padded = torch.nn.functional.pad(value,(self.padding,self.padding,self.padding,self.padding))
            flat = padded.reshape(1,288,-1)
            return torch.index_select(flat,2,self.spatial_indices).reshape(1,288*self.kernel*self.kernel,self.windows)
    replaced = 0
    for layer in conversion.layers:
        block = layer.residual_group.overlap_attn
        block.unfold = SharedSpatialUnfold(block.unfold,args.size)
        replaced += 1
    probe = torch.linspace(0,1,args.size*args.size).reshape(1,1,args.size,args.size).repeat(1,3,1,1)
    with torch.inference_mode():
        expected = model(probe)
        deployed = conversion(probe)
    lowering_delta = float((expected - deployed).abs().max())
    if lowering_delta != 0:
        raise RuntimeError(f'Static mask/unfold lowering differs from original official graph: {lowering_delta}')
    print(json.dumps({'replacedUnfolds':replaced,'fullTorchLoweringMaxAbs':lowering_delta}),flush=True)
    del probe, expected, deployed
    del model
    gc.collect()
    class Boundary(torch.nn.Module):
        def __init__(self, network):
            super().__init__()
            self.network = network
        def forward(self, value):
            return self.network(value.float()).half()
    wrapper = Boundary(conversion).eval()
    example = torch.full((1,3,args.size,args.size), 0.5, dtype=torch.float16)
    started = time.perf_counter()
    with torch.inference_mode():
        traced = torch.jit.trace(wrapper, example, strict=True, check_trace=False)
    trace_seconds = time.perf_counter() - started
    print(f'Official graph traced in {trace_seconds:.3f}s', flush=True)
    del wrapper, conversion, example
    gc.collect()
    started = time.perf_counter()
    from coremltools.optimize.coreml import OptimizationConfig, OpPalettizerConfig
    from coremltools.optimize.coreml._quantization_passes import palettize_weights as MaskPalettePass
    from coremltools.converters.mil.mil.passes.graph_pass import AbstractGraphPass
    from coremltools.converters.mil.mil.passes.pass_registry import register_pass
    mask_names = []
    @register_pass(namespace='truongscaler', override=True)
    class lossless_hat_mask(AbstractGraphPass):
        def apply(self, program):
            for operation in program.functions['main'].find_ops(op_type='const'):
                value = operation.outputs[0].val
                if isinstance(value,np.ndarray) and value.ndim >= 3 and value.shape[-2:] == (256,256):
                    unique = np.unique(value)
                    if np.array_equal(unique,np.array([-100.,0.],dtype=unique.dtype)):
                        mask_names.append(operation.name)
            if len(mask_names) != 1:
                raise RuntimeError(f'Expected one shared official mask, found {mask_names}')
            compression = OptimizationConfig(global_config=None)
            compression.set_op_name(mask_names[0],OpPalettizerConfig(mode='unique',weight_threshold=0))
            MaskPalettePass(config=compression).apply(program)
    pipeline = ct.PassPipeline.DEFAULT
    # Materialize positional-bias lookups before deployment. Retaining those large constant
    # gathers caused excessive GPU specialization memory; the dense constant path is validated.
    # Apply the exact mask encoding in the same pipeline. The public post-training optimizer
    # reconverts with a default folding pipeline, which would expand the attention biases again.
    pipeline.append_pass('truongscaler::lossless_hat_mask')
    converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
        inputs=[ct.TensorType(name='input_tile', shape=(1,3,args.size,args.size), dtype=np.float16)],
        outputs=[ct.TensorType(name='output_tile', dtype=np.float16)],
        compute_precision=ct.precision.FLOAT32 if args.precision == 'fp32' else ct.precision.FLOAT16,
        skip_model_load=True, pass_pipeline=pipeline)
    # The shifted-window mask is a two-value deterministic constant, not a learned parameter.
    # Lossless unique-value LUT encoding prevents a 256px graph from shipping ~64MiB of zeros/-100.
    # No convolution/attention weights are quantized or palettized.
    conversion_seconds = time.perf_counter() - started
    converted.short_description = f'Official trained HAT-S native2x {args.size}; raw RGB transfer-domain output.'
    converted.author = 'XPixelGroup HAT authors; Core ML conversion by TruongScaler'
    converted.license = 'Apache-2.0; see bundled upstream HAT/BasicSR notices.'
    converted.user_defined_metadata['checkpointSHA256'] = CHECKPOINT_SHA256
    converted.user_defined_metadata['officialRevision'] = REVISION
    converted.user_defined_metadata['arithmeticPrecision'] = args.precision
    from shard_coreml_weights import save_sharded_model
    weight_layout = save_sharded_model(converted,package)
    report = {'model':'HAT-S','parameters':parameters,'inputShape':[1,3,args.size,args.size],
        'outputShape':[1,3,args.size*2,args.size*2],'checkpointSHA256':CHECKPOINT_SHA256,
        'officialRevision':REVISION,'precision':args.precision,'cachedOfficialMask':True,
        'sharedSpatialUnfolds':replaced,'fullTorchLoweringMaxAbs':lowering_delta,'numpyScalarIntCompatibility':True,
        'maskStorage':'Lossless two-value LUT0/-100, attention arithmetic FP32',
        'losslessMaskConstants':mask_names,'learnedWeightsPalettized':False,
        'positionalBiasStorage':'precomputed FP32 for bounded GPU specialization memory',
        'weightLayout':weight_layout,
        'traceSeconds':trace_seconds,'conversionSeconds':conversion_seconds,
        'parity':'NOT_RUN','phoneSpeedAndQuality':'NOT_MEASURED','actualANEPlacement':'NOT_MEASURED'}
    (args.output / f'HAT_S_x2_{args.size}.conversion.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
