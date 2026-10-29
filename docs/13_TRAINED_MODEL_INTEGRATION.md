# Native 2× trained model choices

The feature branch defines three choices: QuickSRNet (Fast, default), EDSR (Balanced) and HAT-S (Best). Each family has static 192→384 and 256→512 variants, for six required assets in the completed feature. Only the model is selectable: every new/imported/batch/handoff/retry job still uses native 2× and denoise off. A completed or resumed artifact retains its recorded model; changing the next-job picker never relabels pixels or mixes models in a canvas.

Build 1008 is the separate published QuickSRNet/EDSR release baseline. The feature branch adds HAT-S with its own independent official-reference and runtime evidence in VALIDATION.md; historical two-model counts do not validate the new model. Fast/Balanced/Best are intended tradeoff labels, not a measured ranking for every photograph or phone.

Official architecture/support files are vendored under ModelConversionTools/vendor, raw checkpoints once under ModelConversionTools/checkpoints, and promoted compiled assets under Targets/TruongScalerApp/Models. The model inventory records checkpoint hashes, source revisions, tensor contracts, licenses, weight digests and directory digests. Source manifests pin the original architecture bytes. Preserve the QuickSRNet BSD-3-Clause, EDSR MIT and HAT/BasicSR Apache-2.0 notices, including the vendored pytorch-image-models notice.

All tensor interfaces use NCHW FP16. QuickSRNet retains FP16 arithmetic. The existing EDSR-baseline uses the official 16-block, 64-feature architecture (about 1.37 million parameters) and FP32 arithmetic because the evaluated FP16 EDSR graph missed high-frequency reference fidelity. Its adapter applies the author's RGB range of 255. HAT-S uses FP32 arithmetic with FP16 tensor boundaries. The original official FP32 implementations remain the independent comparison references.

| Choice | Input / overlap, constrained tier | Input / overlap, high-memory tier | Arithmetic |
| --- | --- | --- | --- |
| QuickSRNet (Fast) | 192 / 16 | 256 / 24 | FP16 |
| EDSR (Balanced) | 192 / 16 | 256 / 24 | FP32 |
| HAT-S (Best) | 192 / 32 | 256 / 32 | FP32 |

HAT-S records its model-specific 32-pixel halo in both tiers. Existing QuickSRNet/EDSR jobs keep their original 16/24-pixel halos. Resume must validate the recorded model and tile geometry before any canvas or journal mutation; a different next-job choice cannot change that geometry.

## HAT-S provenance and lowering

The official `HAT-S_SRx2.pth` checkpoint was retrieved from the authors' Drive listing. It contains the trained `params_ema` state, is 79,906,461 bytes and has SHA-256 `3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf`. The pinned HAT source revision is `1638a9a822581657811867bf670717f8371fc3e5`. The loaded HAT-S architecture has **9,473,471 parameters**. Strict trained-state loading, conversion, tensor fidelity and photo quality are separate checks.

`ModelConversionTools/vendor/hat/source-manifest.json` pins the official architecture, native 2× configuration and support/license bytes. The bundle retains the corresponding `Models/Provenance/hat-source-manifest.json`, checkpoint provenance and complete notices alongside the two new assets.

Conversion work caches the exact official attention mask for each fixed shape and lowers overlapping-window `Unfold` through an equivalent shared spatial operation, applied independently across channels. HAT-S retains its channel/window attention, matrix products and softmax. These changes belong to the conversion instance; the original official FP32 reference keeps its own mask calculation and attention implementation. Both shapes have an exact zero-difference full PyTorch lowering check. All seven full output tensors are then compared with the unmodified official FP32 implementation under all four Mac compute requests. No learned weight is quantized. The deterministic mask uses an exact two-value lookup; positional biases are precomputed to avoid excessive GPU specialization memory. `shard_coreml_weights.py` copies and rehashes every typed blob, including direct constexpr input values, into files below 96 MiB; it updates the model specification and recompiles it, without patching compiled binaries.

## Runtime contract

Production uses requireProductionModels. Missing weights, incorrect shapes and invalid predictions fail visibly; deterministic resampling is test-only. The established component-bounded log/HDR/chroma/alpha pipeline is preserved. The model receives peak-normalized, transfer-encoded luminance replicated across RGB channels. Its prediction is restored to log luminance before unchanged color reconstruction.

QuickSRNet clips internally and retains its [-0.02,1.02] validation envelope. EDSR and the HAT-S app contract allow finite raw edge overshoot within [-0.25,1.25] before restoration clamps to the bounded transfer range. Larger or non-finite predictions are refused before durable commit. HAT-S preserves raw predictions so this runtime check remains meaningful. Extreme checkers/noise match the official reference but overshoot the production envelope; they require safe refusal, rather than counting as valid photo outputs. HAT-specific ordinary-photo, HDR, alpha, export, seam and durable-refusal checks remain distinct from tensor parity.

QuickSRNet/EDSR retain their production CPU+Neural Engine restriction and explicit CPU-only support. HAT-S may request foreground GPU outside the simulator; Mac GPU/all requests pass the full-reference checks. The exercised iOS simulator rejects raw HAT-S GPU/all execution plans with Core ML error -14 and logs an unavailable MPSGraph backend. Simulator production routing therefore uses CPU+NE, while direct CPU-only and CPU+NE requests must pass the official-reference cases. Tests also attempt and record both raw GPU failures; these are unavailable-policy observations, never GPU fidelity passes. Background requests remain CPU+NE everywhere. Effective requests follow the frozen job model and are logged truthfully. Physical-phone GPU behavior, latency, image quality and actual ANE placement remain unmeasured; parameter counts and Mac/simulator timings do not establish them.

## Reproducible conversion and verification

Use Python 3.12 with the versions pinned in `ModelConversionTools/requirements.txt`. The environment is a developer tool and does not ship in the app. Official checkpoint URLs, filenames and SHA-256 digests belong in `Targets/TruongScalerApp/Models/Provenance/model-inventory.json`. Preserve all three canonical checkpoints under `ModelConversionTools/checkpoints`; load weights strictly with `weights_only=True`, selecting HAT-S's recorded `params_ema` state.

```sh
python3.12 -m venv ModelConversionTools/.venv
ModelConversionTools/.venv/bin/python -m pip install -r ModelConversionTools/requirements.txt
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_quicksr.py --output <fresh-default-directory>
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_options.py --output <fresh-edsr-directory>
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_hat_s.py --size 192 --precision fp32 --output <fresh-hat-192-directory>
ModelConversionTools/.venv/bin/python ModelConversionTools/convert_hat_s.py --size 256 --precision fp32 --output <fresh-hat-256-directory>
```

Run these heavy steps serially. Reuse an existing environment when present. The default converter creates the QuickSRNet pair and parity/inventory JSON in its output directory. Review those outputs before replacing the corresponding canonical assets and provenance; the converter does not publish them into the app.

`bundle_options.py --converted <fresh-edsr-directory>` merges EDSR assets into an existing canonical default bundle. For a separate review bundle, begin with a copy of the complete `Models/` tree and pass `--models-dir <review-models-directory>`. The bundler verifies input/existing digests and refuses differing existing optional assets. It also refreshes the repository's `Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json`, including when using a separate models directory. An existing HAT pair and its sampled reference cases are retained. Review both models and reference fixtures before publishing a new conversion.

QuickSRNet and EDSR conversion evidence compares full tensors against the unmodified official FP32 PyTorch reference with identical half-rounded inputs under all four Mac compute requests: all, CPU+NE, CPU+GPU and CPU-only. Cases include black, white, near-black, gradients, color/luminance checkers and seeded noise. The gate requires exact shapes, finite output, PSNR ≥50 dB and maximum absolute error <0.02. HAT-S has separate full-reference reports, sampled runtime fixtures and model-specific safety/quality checks. The latest executed status and limits are recorded in VALIDATION.md. Keep detailed measurements and sampled reference fixtures before updating the canonical bundle or validation claims.

For HAT-S, compile each fresh package with `xcrun coremlcompiler compile`, generate a lossless full official FP32 reference cache with `verify_hat_s.py --generate-reference-only --reference-cache <fresh-cache.npz> --size SIZE`, then run that verifier against the compiled asset for each of `cpuOnly`, `cpuAndNeuralEngine`, `cpuAndGPU` and `all`. Keep reference generation and each prediction process separate and serial to bound memory. Use `--samples` to retain the gradient/checker/luminance-checker fixtures. The full cache contains all seven tensors, source/checkpoint identity and input hashes.

`bundle_hat_s.py --converted-root <root> --validation-dir <reports>` expects `publish-{192,256}/HAT_S_x2_SIZE.mlmodelc` and its conversion report, `official-full-SIZE.npz`, `publish-reference-SIZE.json` and all eight `publish-parity-SIZE-POLICY.json` reports. It binds report directory hashes to the exact compiled assets and sampled values to the full FP32 cache, refuses any missing/failed/conflicting input before copying, and publishes the six-model inventory last. `--models-dir` and `--reference-fixture` support a separate review tree. Actual iOS checks and built-app audits are still required after conversion promotion.

```sh
python3 ModelConversionTools/verify_production_assets.py --checkpoints-dir ModelConversionTools/checkpoints
```

The verifier checks compiled asset/directory hashes, every HAT weight-shard hash, checkpoint hashes and pinned vendored sources. Build audits additionally verify the actual app's model tree. Keep all `.mlmodelc` files, including `coremldata.bin` and `weights/weight.bin`, as well as `Models/Provenance`, `Models/Notices`, vendored licenses and fixture provenance in version control. Raw checkpoints, vendor code and Python packages are not app resources.

Model parity is separate from photo quality and safety. Run required-model errors, high-frequency refusal, ordinary photo/HDR/chroma/alpha/export, seams, durable refusal/resume and simulator prediction cases, plus the checks in [DEVELOPMENT.md](DEVELOPMENT.md). [VALIDATION.md](VALIDATION.md) records the latest complete executed validation and its limits. Local results do not establish physical-phone latency, image quality, OS scheduling, signed handoff, ANE placement or equivalence to another editor.
