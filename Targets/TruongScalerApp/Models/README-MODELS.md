# Bundled trained native 2× models

The choices are QuickSRNet (Fast, default), EDSR-baseline (Balanced) and HAT-S (Best). These labels describe intended time/detail tradeoffs, not measured phone-quality guarantees. Every family has 192→384 and 256→512 input/output shapes; the app offers no 4× or denoise stage.

All tensor interfaces are FP16 NCHW. QuickSRNet computes in FP16; EDSR-baseline and HAT-S retain FP32 arithmetic for reference fidelity, including high-frequency inputs. QuickSRNet/EDSR retain their validated CPU+Neural Engine routing restriction. HAT-S may request foreground GPU outside the simulator; Mac full-reference checks pass, while physical-phone GPU behavior remains unmeasured. The exercised simulator rejects raw GPU plans (-14), so its production route uses CPU+Neural Engine. Both simulator CPU requests pass the official fixtures. Background requests remain CPU+Neural Engine. Requests do not prove actual ANE placement. A missing model, incompatible shape or invalid prediction fails visibly.

The optional models return raw edge overshoot. Finite values within [-0.25,1.25] are restored through the bounded display-transfer/HDR luminance path; values beyond that range are refused before tile commit. QuickSRNet retains its separate [-0.02,1.02] guard. No trained model is replaced with another model or a resampler after failure. Existing checkpoints always retain their model identity.

`Provenance/model-inventory.json` records checkpoint/source/licensing/tensor contracts and whole compiled-asset digests, including every HAT-S weight shard. `official-parity.json` covers QuickSRNet; `additional-official-parity.json` covers EDSR. The eight `hat-official-parity-SIZE-POLICY.json` reports compare full HAT-S tensors with the independent official FP32 reference. Source hashes are pinned in the corresponding upstream, additional and HAT source manifests. Preserve all BSD/MIT/Apache notices when redistributing.

HAT-S records a 32-pixel overlap at both input sizes; QuickSRNet/EDSR keep 16/24 pixels. Its exact fixed attention mask is stored losslessly as a two-value lookup. Learned weights and attention arithmetic remain FP32. Precomputed positional biases bound GPU specialization memory; lossless weight-file sharding keeps ordinary Git blobs below 96 MiB. No learned weight is quantized by this storage operation.

Canonical raw checkpoints are retained once under ModelConversionTools/checkpoints. Neither raw checkpoints nor Python dependencies ship in this app bundle.
