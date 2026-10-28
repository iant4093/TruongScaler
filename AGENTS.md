# TruongScaler development instructions

Work directly in this project. Read `README.md`, `docs/DEVELOPMENT.md` and `docs/VALIDATION.md`; also read `docs/13_TRAINED_MODEL_INTEGRATION.md` before changing the model contract and `docs/15_OUTPUT_MANAGEMENT_AND_HISTORY.md` before changing library storage or metadata.

- TruongCam is strictly read-only. Do not edit TruongNoiser.
- Preserve the native system-green UI, viewer layout/concurrency, folder grants, task ownership, Stop/reset recovery, durable mmap/journal replay, metadata and HDR/export contracts.
- The authorized models are QuickSRNet (Fast, default) and EDSR (Better), each with 192 and 256 input shapes. New processing is fixed at native 2× with denoise off. Resume uses the recorded model; never mix models within a saved canvas.
- Preserve separate input/output libraries, arbitrary recursive photo/RAW input folders, portable result records, deduplicated original archives and persistent before/after on reopen.
- Preserve opaque legacy identifiers and actual artifact dimensions/history. Refuse incompatible resumes before writing files. Never delete or relabel human checkpoints, bookmarks, photos or outputs.
- Production uses `.requireProductionModels`. Missing weights, incompatible shapes and invalid predictions are errors; deterministic resampling is explicit test-only behavior.
- Keep provenance, SHA-256 verification and license notices for every shipped variant. Compare conversions with the official trained PyTorch reference under all available compute policies, including high-frequency cases.
- Run `swift test`, actual iOS simulator regressions for UIKit changes, and unsigned device Debug/Release plus simulator app/widget builds for model/resource changes. Compilation alone does not exercise UIKit. Audit the final app resources.
- Do not manipulate the human's physical-device Xcode session, sign/install/uninstall/run on a phone, publish or deploy without applicable authorization. Treat phone speed, OS scheduling, ANE placement, real Canon R7 CR3 compatibility and physical image quality as unmeasured until exercised.
- Serialize heavy conversion/build/test tasks and bound process-tree memory, including compression. Prefer one retained conversion environment. Keep generated logs, builds and agent artifacts outside version control; remove task-owned obsolete caches after validation.
