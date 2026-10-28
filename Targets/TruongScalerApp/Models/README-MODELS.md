# Bundled trained native 2× models

QuickSRNet-Large is the fast default. EDSR-baseline is the second native 2× model, labeled Better; QuickSRNet is labeled Fast. Every family has 192→384 and 256→512 input/output shapes; the app offers no 4× or denoise stage.

All tensor interfaces are FP16 NCHW. QuickSRNet computes in FP16; EDSR-baseline retains FP32 arithmetic for reference fidelity, including high-frequency inputs. Production requests CPU+Neural Engine or explicit CPU-only use; this does not prove actual ANE placement. A missing model, incompatible shape or invalid prediction fails visibly.

The optional models return raw edge overshoot. Finite values within [-0.25,1.25] are restored through the bounded display-transfer/HDR luminance path; values beyond that range are refused before tile commit. QuickSRNet retains its separate [-0.02,1.02] guard. No trained model is replaced with another model or a resampler after failure. Existing checkpoints always retain their model identity.

Provenance/model-inventory.json records checkpoint/source/licensing/tensor contracts and compiled asset digests. official-parity.json covers QuickSRNet; additional-official-parity.json covers both optional models. Vendored source hashes are in additional-source-manifest.json. Preserve all Notices files when redistributing.

Canonical raw checkpoints are retained once under ModelConversionTools/checkpoints. Neither raw checkpoints nor Python dependencies ship in this app bundle.
