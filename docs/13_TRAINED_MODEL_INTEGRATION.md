# Native 2× trained model choices

QuickSRNet-Large is the fast default. The two choices are QuickSRNet (Fast) and EDSR (Better). Each family has static 192→384 and 256→512 variants. Only the model is selectable: every new/imported/batch/handoff/retry job still uses native 2× and denoise off. A completed or resumed artifact retains its recorded model; changing the next-job picker never relabels pixels or mixes models in a canvas.

Official architecture/support files are vendored under ModelConversionTools/vendor, raw checkpoints once under ModelConversionTools/checkpoints, and compiled assets under Targets/TruongScalerApp/Models. The model inventory records checkpoint hashes, source revisions, tensor contracts, licenses, weight digests and directory digests. Source manifests pin the original architecture bytes. Preserve the BSD-3-Clause and MIT notices.

All tensor interfaces use NCHW FP16. QuickSRNet retains FP16 arithmetic. EDSR-baseline retains FP32 arithmetic because the evaluated FP16 EDSR graph missed high-frequency reference fidelity. The EDSR adapter applies the author's RGB range of 255. No trained reference is replaced with a shared custom/stub graph.

Production uses requireProductionModels. Missing weights, incorrect shapes and invalid predictions fail visibly; deterministic resampling is test-only. The established component-bounded log/HDR/chroma/alpha pipeline is preserved. The model receives peak-normalized, transfer-encoded luminance replicated across RGB channels. Its prediction is restored to log luminance before unchanged color reconstruction.

QuickSRNet clips internally and retains its [-0.02,1.02] validation envelope. EDSR can overshoot at edges: finite raw predictions within [-0.25,1.25] are accepted before restoration clamps to the bounded transfer range. Larger or non-finite predictions are refused before durable commit. Adversarial luminance checkers exercise this refusal; there is no hidden model fallback, and the error suggests retrying with QuickSRNet. Ordinary photo/HDR/alpha/export and seam checks remain independent requirements.

Production resolves GPU-enabled requests to CPU+Neural Engine and supports explicit CPU-only. Prior raw GPU-enabled iOS simulator predictions returned zeros for QuickSRNet. Effective requested compute is logged truthfully; neither conversion nor CPU+NE requests prove actual ANE placement. Test actual simulator predictions separately from Mac conversion parity.

## Reproducible conversion and verification

Use Python 3.12 with the versions pinned in `ModelConversionTools/requirements.txt`. The environment is a developer tool and does not ship in the app. Official checkpoint URLs, filenames and SHA-256 digests are recorded in `Targets/TruongScalerApp/Models/Provenance/model-inventory.json`. Preserve the two canonical checkpoint files under `ModelConversionTools/checkpoints`; load weights strictly with `weights_only=True`.

```sh
python3.12 -m venv ModelConversionTools/.venv
ModelConversionTools/.venv/bin/python -m pip install -r ModelConversionTools/requirements.txt
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_quicksr.py --output <fresh-default-directory>
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_options.py --output <fresh-edsr-directory>
```

Run these heavy steps serially. Reuse an existing environment when present. The default converter creates the QuickSRNet pair and parity/inventory JSON in its output directory. Review those outputs before replacing the corresponding canonical assets and provenance; the converter does not publish them into the app.

`bundle_options.py --converted <fresh-edsr-directory>` merges EDSR assets into an existing canonical default bundle. For a separate review bundle, begin with a copy of the complete `Models/` tree and pass `--models-dir <review-models-directory>`. The bundler verifies input/existing digests and refuses differing existing optional assets. It also refreshes the repository's `Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json`, including when using a separate models directory. Review both models and reference fixtures before publishing a new conversion.

Converters compare full tensors against the unmodified official FP32 PyTorch reference with identical half-rounded inputs under all four Mac compute requests. Cases include black, white, near-black, gradients, color/luminance checkers and seeded noise. Each comparison requires exact shapes, finite output, PSNR ≥50 dB and maximum absolute error <0.02. Keep detailed parity measurements and sampled reference fixtures for actual iOS regressions. High-frequency fidelity is why EDSR keeps FP32 arithmetic.

```sh
python3 ModelConversionTools/verify_production_assets.py --checkpoints-dir ModelConversionTools/checkpoints
```

The verifier checks compiled asset/directory hashes, weight hashes, checkpoint hashes and pinned vendored sources. Build audits additionally verify the actual app's model tree. Keep all `.mlmodelc` files, including `coremldata.bin` and `weights/weight.bin`, as well as `Models/Provenance`, `Models/Notices`, vendored licenses and fixture provenance in version control. Raw checkpoints, vendor code and Python packages are not app resources.

Model parity is separate from photo quality and safety. Run required-model errors, high-frequency refusal, ordinary photo/HDR/chroma/alpha/export, seams, durable refusal/resume and simulator prediction cases, plus the checks in [DEVELOPMENT.md](DEVELOPMENT.md). [VALIDATION.md](VALIDATION.md) records the latest complete executed validation and its limits. Local results do not establish physical-phone latency, image quality, OS scheduling, signed handoff, ANE placement or equivalence to another editor.
