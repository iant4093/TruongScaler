# Development and architecture

TruongScaler is a native Swift 6 iOS app backed by a local Swift package. `Package.swift` defines the imaging, storage, background and UI modules; `project.yml` defines the app, widget and hosted UIKit tests. The package minimum is macOS/iOS 26 and the generated app targets iOS 27. Build the tracked `TruongScaler.xcodeproj` with Xcode 27 and its required SDK; restore it from Git if it is missing. `project.yml` is retained for intentional project maintenance with XcodeGen. Python 3 is needed for bundle audits; the optional model conversion environment uses Python 3.12.

## Build and test

From the repository root:

```sh
bash scripts/lint.sh
bash scripts/verify-logic.sh
bash scripts/test.sh native
scripts/build.sh debug
scripts/build.sh release
scripts/build.sh simulator
```

The build script creates unsigned app/widget products and audits their executable, metadata and complete trained-model resources. It uses two build jobs and `build/DerivedData` by default. `TRUONGSCALER_BUILD_JOBS` and `TRUONGSCALER_DERIVED_DATA` override those values. `scripts/package-ipa.sh` validates and packages an existing Release product as `build/ipa/TruongScaler.ipa`, a matching app/widget `TruongScaler.dSYM.zip` and `SHA256SUMS`; it does not install or publish them. The CI workflow publishes those three verified artifacts only after all four gates pass on main.

The native runner executes all nine package suites and the hosted UIKit suite on an available iPhone 17 Simulator with iOS 27+. Set `TRUONGSCALER_SIMULATOR_UDID` to select a particular matching simulator. It never targets a phone or resets photo data. The hosted suite exercises real app-scene modal presentation and can be run independently:

```sh
xcodebuild -jobs 2 -project TruongScaler.xcodeproj \
  -scheme TruongScalerHostTests \
  -destination 'platform=iOS Simulator,id=<test simulator UUID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

The package also exposes individual test schemes to Xcode. Run the relevant package suites on the simulator as well as the Mac package tests; the hosted suite does not replace the package's model, ingestion, export, journal and background suites. A simulator SDK build alone does not execute tests. Standalone simulator `xctest` can exercise package logic but cannot prove successful app-scene modal presentation.

Serialize conversions, builds, tests and compression. Use `scripts/run_bounded.py` when a command needs the repository's process-descendant memory guard. Keep one useful conversion environment and exclude generated builds, logs, caches and result images from Git. Historical result counts and their limits are in [VALIDATION.md](VALIDATION.md); model conversion is in [13_TRAINED_MODEL_INTEGRATION.md](13_TRAINED_MODEL_INTEGRATION.md).

## Pipeline and module responsibilities

| Module | Responsibility |
| --- | --- |
| `TruongScalerCore` | Job/model identity, checked geometry, metadata/history, bookmarks, handoff and diagnostics |
| `CoreIngestion` | Native raster/RAW decoding, independent suite Linear DNG decoding and strip ingestion |
| `MMapCanvas` | Disk-backed pixels, causal tile blending and durable undo journals |
| `MetalColorEngine` | CPU/Metal color transforms, luminance/chroma separation and tile geometry |
| `TiledInferenceEngine` | Required Core ML models, checkpoint ownership and tile execution |
| `CoreExport` / `DNGWriterBridge` | Container capabilities, streamed rendered Linear DNG and metadata |
| `BackgroundJobManager` / `ScalerActivityUI` | Continued-processing delivery, expiration and progress lifecycle |
| `DeepZoomGalleryUI` | Input/output libraries, native viewer, sharing, trash and app processing policy |

Ingestion writes linear extended-range Display P3 RGBA16Float pixels to a 64-byte-row-aligned mmap. Geometry and byte counts use checked arithmetic before file creation or truncation. Reopening a durable canvas requires its exact expected byte length. Strip orientation, source metadata and actual decoded dimensions remain explicit.

The reversible log transform is bounded by the maximum RGB component, since luminance alone understates saturated HDR highlights. Model-facing luminance is restored from log space, peak-normalized and sRGB-transfer encoded, then replicated across the model's three channels. Predictions return to log luminance before the existing Display P3 chroma and alpha reconstruction. CPU/Metal parity, HDR, saturated color, alpha and seam tests protect this contract. Inverse log reconstruction uses a cancellation-safe small-exponent series; the Metal inverse RGB matrix deliberately disables fused contraction to match CPU Float rounding at near-black half-subnormal boundaries. Natural grain retention blends a source-derived Lanczos reference during export and does not change the saved model identity or scale.

The HAT-S feature branch integrates six trained assets: QuickSRNet (Fast, default), EDSR (Balanced) and HAT-S (Best), each at 192 and 256 input edges with 384 and 512 output edges. Build 1008 remains the separate published two-model baseline. This feature has independent conversion, reference, simulator and app/resource evidence in VALIDATION.md. The labels express the intended processing/detail tradeoff, not measured universal quality or phone-speed results.

Tile geometry is model-specific. QuickSRNet/EDSR retain 192/16 and 256/24 input/overlap tiers. HAT-S uses a 32-pixel overlap at both input sizes, recorded with its model identity in the checkpoint. Resume validates that saved pair before writing; the next-job picker cannot replace the model or regenerate old tile geometry. Missing models, invalid tensors and incompatible saved jobs fail visibly. New processing remains native 2× with denoise off; completed legacy artifacts retain their actual dimensions and opaque identifiers.

HAT-S contains attention as well as convolution. Its FP32 conversion candidates cache the official fixed-shape mask and use an equivalent shared spatial `Unfold` lowering; the original official FP32 implementation remains the separate reference. Conversion, full-tensor parity, seam/safety regressions, actual supported simulator predictions and app/widget resource audits are separate required gates. Raw HAT-S GPU requests fail on the exercised simulator, so that target uses CPU+NE; direct CPU requests pass independent reference fixtures. Outside the simulator HAT-S may request foreground GPU, but physical-phone latency, behavior and accelerator placement remain unmeasured. Pinned sources, checkpoint hash and notices are described in [the model guide](13_TRAINED_MODEL_INTEGRATION.md).

RAW recognition delegates camera decoding to the installed native runtime. A recognized extension is not a verified camera compatibility claim. Real Canon EOS R7 CR3 files have not been exercised. Gain-map raster inputs require verified native expanded headroom; an incapable runtime refuses them before creating a destination instead of silently accepting their SDR base. Linear DNG/TIFF remain separate tested HDR paths.

## Durable processing and ownership

Each tile prediction completes before its canvas transaction starts. The executor durably journals the pre-blend rectangle, applies causal overlap blending, range-flushes the canvas, durably advances the checkpoint, then removes the journal. A crash before checkpoint advancement restores exact pre-blend pixels before replay; applying an overlap blend twice is not safe. Corrupt, mismatched or unreadable journal inventories fail before canvas mutation. Recovery must remain idempotent.

Resume validates model identity, geometry, source contracts, normalization and journal versions before writes. It reads the model from the saved job, independently of the next-job picker. Progress counts committed work. Stop may drain an in-flight prediction, but its accepted frontier cannot regress or start the next batch photo. Generation-scoped ownership prevents late picker, decode, export, task or reset callbacks from replacing newer state or releasing another operation's grant.

The system continued-processing task owns the single system progress card and Stop action on supported iOS versions. Auto-save progress reserves a unit for export/record publication, so inference completion is followed by saving before success. Expiration requests a durable pause. Remaining batch photos wait for foreground after a background completion. CPU+NE is the production model request; background color work uses CPU. Requests and simulator observations do not establish physical ANE execution or OS scheduling.

The native system-green UI, shared zoom transform, fitted/rotated comparison geometry and concurrency-safe tiled-renderer snapshots are maintained behavior. Folder grants and mmap readers must outlive blocking work. Bounded display caches and small SDR thumbnails serve browsing; full-resolution buffers remain authoritative for processing, comparison and export.

## Export and metadata contracts

All output headroom decisions measure the final RGB component peak after grain blending. Rendered Linear DNG is developed RGB, not a reconstructed camera mosaic. It uses UInt16 SDR at DNG 1.4/reference 1 or absolute Float16 HDR at DNG 1.7/reference 2, with `ProfileDynamicRange` headroom, white level 1 and baseline exposure 0. The color matrix describes linear Display P3 output. The streamed writer uses classic TIFF offsets and refuses output beyond its 4 GiB format limit; BigTIFF is not implemented.

LZW TIFF retains half-float HDR and alpha. PNG is 16-bit SDR and refuses overrange pixels. HEIC HDR is verified by decoding each finalized export; loss of highlights/colors is an explicit error. Regenerated HDR gain maps are not implemented, and stale source maps are never attached to processed pixels. JPEG is 8-bit SDR with alpha flattened onto black. Match Source routes RAW to Linear DNG, HDR HEIF to verified HEIC, alpha raster to PNG and other inputs to JPEG.

Exports publish atomically and report their concrete format, actual dimensions/scale and measured headroom. Preserve supported EXIF/GPS, orientation, output color interpretation and bounded processing history. Camera MakerNote fidelity and arbitrary raw tag passthrough are not promised. The independent suite Linear DNG reader validates structural/sample tags and supports the existing legacy integer convention; malformed present sample tags must not silently select defaults. App Group handoff copies image bytes and validates manifests; it is not a zero-copy transfer.

See [15_OUTPUT_MANAGEMENT_AND_HISTORY.md](15_OUTPUT_MANAGEMENT_AND_HISTORY.md) for portable records, frozen originals, trash recovery and metadata interchange. Human photos, outputs, bookmarks and checkpoints are never reset as a development shortcut.
