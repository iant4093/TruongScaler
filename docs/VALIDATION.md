# Validation record

The launch/repository baseline was validated locally on **2026-10-28**; the subsequent hosted-GPU precision follow-up is recorded separately below. Current commands and required checks are in [DEVELOPMENT.md](DEVELOPMENT.md). Generated logs/results stay in the ignored `build/` directory. The preceding application review is recorded separately below; historical agent evidence is archived outside the source repository.


## HAT-S native 2× feature — 2026-10-28

This feature branch adds QuickSRNet (Fast, default), EDSR (Balanced) and HAT-S (Best), with two shapes each. Build 1008 remains the separately published two-model baseline. The labels express intended tradeoffs; no physical-phone quality ranking or speed guarantee is established.

| Final executed check | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: |
| Mac package, complete strict concurrency and warnings as errors | 445 | 1 | 0 |
| All nine actual iOS simulator package suites | 477 | 1 | 0 |
| Actual app-hosted UIKit tests, including production screenshot capture | 19 | 0 | 0 |
| Python metadata/process-supervision fixtures | 13 | 0 | 0 |

There were **496 actual iOS passes**, including capture. Repeated executions are not added to these counts. The optional 48 MP I/O benchmark was skipped on each package platform. All three unsigned device Debug/Release and simulator app/widget builds and six-model resource audits passed. A separate binary audit verified device arm64/IOS unsigned executables, simulator IOSSIMULATOR slices with linker ad-hoc signatures and no development team. Release packaging verifies matching external app/widget dSYM UUIDs and archive checksums. Builds are separate from executed tests.

The new official `HAT-S_SRx2.pth` checkpoint has SHA-256 `3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf`; the pinned source revision is `1638a9a822581657811867bf670717f8371fc3e5`, with 9,473,471 loaded parameters. Both static shapes preserve FP32 arithmetic and FP16 tensor boundaries. The independent original official FP32 reference retains its own masks and `nn.Unfold`. Full tensors use identical half-rounded inputs; lossless reference caches record input/source/checkpoint hashes. Neither a shared custom reference nor a stub supplies the expected output.

| HAT-S input shape | Mac compute requests | Full-tensor cases | Minimum PSNR | Maximum absolute error |
| --- | ---: | ---: | ---: | ---: |
| 192 | 4 | 28 | 73.1168 dB | 0.000978232 |
| 256 | 4 | 28 | 73.1703 dB | 0.000978232 |

All 56 comparisons passed exact-shape, finite-output, PSNR ≥50 dB and maximum-error <0.02 gates. Black, white, near-black, gradients, color/luminance checkers and seeded noise are covered. Extreme checker/noise predictions faithfully reproduce the official network's excursions beyond the production envelope; these require safe refusal before durable commit and are not ordinary-photo quality passes. The eight `hat-official-parity-SIZE-POLICY.json` reports, source/checkpoint manifests, sampled fixtures and complete HAT/BasicSR/timm notices ship with the assets. Existing QuickSRNet/EDSR asset digests are unchanged.

Actual iOS simulator execution separately compared three independent sampled patterns for both shapes under raw CPU-only and CPU+NE requests: **12 predictions**, each with 1,024 official FP32 reference samples, unchanged fidelity gates and non-constant output assertions. Both raw GPU/all requests were also attempted for both shapes. The exercised simulator rejected those four model loads with Core ML execution-plan error **-14**, logging `MpsGraph backend validation on incompatible OS (11)`. These are **unavailable-policy observations, not GPU parity passes**. Production therefore restricts simulator HAT-S to CPU+NE (or explicit CPU-only). Outside the simulator HAT-S may request foreground GPU, while background requests remain CPU+NE. Physical-phone GPU behavior, latency and actual accelerator placement remain unmeasured. `hat-ios-compute-observations.json` records this distinction.

Required-model photo checks passed flower reconstruction at both shapes, landscape color, HDR/headroom, alpha, seam/halo limits, TIFF and DNG export/reingest, unsafe-prediction refusal and exact saved-model recovery. HAT-S records a 32-pixel overlap in both tiers; existing QuickSRNet/EDSR 16/24-pixel overlaps are unchanged. Unknown or mismatched model/geometry resumes are refused before modifying canvas/journal bytes. Compute-policy race tests retain a newer background request and report the frozen job's effective request. No source photo, bookmark or human checkpoint was deleted or relabeled.

The app-hosted capture used the actual production initializer and bundled models: it processed the flower with HAT-S and the landscape with QuickSRNet, saved portable records, reopened the HAT-S before/after, then captured all four README screens and current model settings. Real UIKit share, selection, trash, layout and presentation tests also passed. The screenshots illustrate the interface and do not establish physical-phone quality.

Warm Mac full-tensor predictions were approximately **0.43–0.48 seconds at 192** and **0.78 seconds at 256** for GPU-enabled requests, versus approximately **2.8 / 5.6 seconds** for CPU requests. These are measured Mac tiles, not full RAW/phone timings. Simulator CPU attention is substantially slower: its complete native run took about 26.8 minutes. Native CI now allows 60 minutes within a 65-minute job, retaining all checks and assertions.

The conversion caches the exact fixed mask and shares an equivalent spatial index lowering for `Unfold`; both sizes have a zero-difference full PyTorch lowering check. Its two-value mask encoding is lossless; learned weights remain FP32. Precomputed positional biases avoid the excessive specialization memory observed with a rejected compact-gather candidate. Typed weight blobs are rehashed byte-for-byte after lossless file sharding, including direct constexpr inputs. Final canonical prediction/conversion processes stayed below the 8 GiB footprint guard; maximum observed canonical parity footprint was 6,705 MiB. An earlier compact candidate exceeded the guard and was terminated; it is excluded from shipped assets. The final Mac suite peaked at 5,667 MiB. The native wrapper's 689 MiB command-descendant peak excludes CoreSimulator services outside its ancestry. Source, checkpoint, asset, notice and built-app hashes are streamed.

SwiftLint, actionlint, offline zizmor and ShellCheck passed. Generated candidates, logs, full reference caches, result bundles and environments remain outside version control. One shared conversion environment is retained; rejected/duplicate task-owned model candidates are removed after validation. Physical phone execution, signed handoff, Files-provider behavior, OS scheduling, real Canon R7 CR3 compatibility, phone memory/latency and physical image quality remain unmeasured. No phone session was manipulated and no new app release was published.

## Hosted-GPU precision follow-up — 2026-10-28

The first hosted run correctly stopped publication on a CPU/Metal parity failure. Stage-isolation telemetry identified a synthetic shadow sample stored as half bits 142 on CPU versus 141 on the hosted GPU (about 8.46e-6 versus 8.40e-6). Forward tensors matched; fused inverse-matrix arithmetic crossed one Float16 subnormal boundary. An independent Double-expm1 oracle also reproduced precision loss from evaluating `exp(x)-1` near black.

Both inverse paths now use a cancellation-safe small-exponent series, and Metal disables contraction only inside the inverse RGB matrix block to preserve the CPU's separately rounded Float operations. The mathematical curve, half storage, model assets, normalization and export policies are unchanged. The original absolute 2e-2 / relative 5e-3 parity limits were retained. Thirteen focused Metal tests pass, including the Double oracle and exact isolated matrix sample; full strict Mac execution passed **432 tests with 1 optional skip**, plus 4 Python fixtures and all asset/checkpoint hashes. Maximum relative CPU/Metal difference was 0.00171527, compared with 0.00704225 before the matrix repair.

The complete native/bundle counts in the following baseline predate this shader follow-up. Current full native, build, analysis and release gates are independently established by the linked GitHub workflow for the current commit. A failed or superseded run cannot publish the latest release.

## Launch and repository validation — 2026-10-28

| Check | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: |
| Mac Swift package, strict concurrency and warnings as errors | 430 | 1 | 0 |
| All nine iOS package test bundles | 462 | 1 | 0 |
| App-hosted UIKit regressions | 18 | 0 | 0 |
| Opt-in production README capture | 1 | 0 | 0 |
| Python built-metadata fixtures | 4 | 0 | 0 |

The two optional 48 MP I/O benchmarks were skipped. The normal CI hosted suite also skips the opt-in documentation capture; its separate local execution used the real required-model production initializer, processed both CC0 samples, saved/reopened their portable records and captured all four README screens. These counts represent **481 actual iOS passes** including capture, without counting builds as tests or adding repeated executions. Screenshots and attribution are maintained under `docs/screenshots/`.

Unsigned device Debug, device Release and Simulator app/widget builds, complete strict concurrency, compiler warnings as errors and Xcode static analysis passed. Audits verified the actual bundle metadata, background identifier family, system-green asset, four model/resource digests, raw checkpoint hashes, native device platform and arm64 executables. Release packaging verified both unsigned bundles, matching external app/widget dSYM UUIDs, ZIP integrity and SHA-256 checksums for the IPA and symbols archive. Release stripping applies only to linked executables, preserving Swift package object files needed during linking.

SwiftLint reported no violations across 59 production Swift files. ShellCheck, actionlint, local zizmor and staged Gitleaks scanning passed. Pinned official vendored model sources remain byte-for-byte unchanged; their original whitespace is retained. Package fixture resources are declared explicitly, desktop-only ExifTool sub-checks are platform guarded, and test setup/teardown and concurrent draw counters are actor/thread safe. Standalone UIKit geometry fixtures still emit deprecation diagnostics for the sceneless `UIWindow(frame:)` initializer; real app-scene tests use `UIWindow(windowScene:)`. The AppIntents metadata tool's no-framework notice is unrelated to a compiler warning or a failed test.

Heavy local commands ran serially with two build jobs and an 8 GiB command-descendant footprint guard including compressed memory. Final observed command-tree peaks were 371 MiB for Mac tests, 203 MiB for the complete native run, 614 MiB for device builds, 648 MiB for the Simulator build and 572 MiB for analysis. Short packaging commands can finish before the first memory sample. CoreSimulator services outside command ancestry are not included; observed system memory pressure remained normal.

The repository contains maintained source, regression fixtures, trained assets/checkpoints, provenance/notices, the tracked native project and reproducible build/test/package scripts. Historical agent directories, copied reference trees, one-off probes/transcripts and obsolete design documents were removed from the repository and archived locally. Generated environments, builds, logs, signing material and personal Xcode state are excluded from version control. GitHub's [CI and IPA release workflow](https://github.com/iant4093/TruongScaler/actions/workflows/ci.yml) independently runs four gates before publishing an unsigned release from main; hosted results are visible there.

## Pre-cleanup application review — 2026-10-27

## Executed checks

| Suite | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: |
| Mac Swift package | 430 | 1 | 0 |
| iOS library/viewer | 191 | 1 | 0 |
| iOS background | 60 | 0 | 0 |
| iOS trained models/reference/quality | 23 | 0 | 0 |
| iOS export | 35 | 0 | 0 |
| iOS core/handoff/history | 32 | 0 | 0 |
| iOS mmap/journal | 18 | 0 | 0 |
| iOS ingestion | 20 | 0 | 0 |
| iOS native hosted UIKit | 18 | 0 | 0 |
| Python built-metadata fixtures | 4 | 0 | 0 |

There were **397 actual iOS test passes**. Counts overlap across platforms. The optional 48 MP I/O benchmark was skipped on Mac and iOS; permission-denied journal recovery and HDR success-or-refusal assertions executed. App compilation is not counted as a test pass.

Unsigned device Debug, device Release and simulator Debug app/widget builds passed. Their executable, Info.plist, extension, accent, background identifier and trained-resource audits passed. Each app contained all four required native 2× variants, provenance and notices, without an embedded test bundle. Raw checkpoint SHA-256 verification passed. No model/conversion assets changed in that review pass.

Heavy checks ran serially with two build jobs and an 8 GiB per-process footprint guard. Measured command-descendant peaks were 358 MiB for the Mac run and 578 MiB for the iOS/build pipeline; CoreSimulator services outside command ancestry were not included. Existing unrelated compiler/AppIntents warnings remained in successful build logs.

## Regression coverage in the latest pass

- Missing, changed or unsafe optional comparison-original links leave a valid saved output viewable with a warning; symlink targets, output bytes and record bytes remain unchanged.
- Cancelled/refused folder requests cannot orphan Checking state or supersede an active request; scope-grant ownership remains balanced.
- Changing output roots during record verification produces recoverable viewer state and cannot overwrite a newer photo generation. Actual UIKit capture verified the error and Back control.
- A journal inventory permission error refuses resume without mutating canvas/sidecars. After access returns, exact overlap rollback and repeated recovery succeed on Mac and iOS.
- Malformed present DNG BitsPerSample/SampleFormat tags are rejected before destination creation or truncation. Independent SDR/HDR fixtures cover both direct and universal decode paths; genuinely absent legacy tags retain their defaults.
- Native gain-map decoding is checked before mmap creation. A capable runtime must recover strict 4.0 HDR samples/luminance; an incapable runtime must return the dedicated refusal error and preserve source/existing destination bytes without creating a new destination.

The broader retained tests cover trained-reference parity, required-model failures, quality/alpha/HDR/seams, legacy identity and dimensions, checkpoint transactions, Stop/reset/lifecycle ownership, metadata/container fidelity, output publication/trash recovery and native viewer/sharing behavior. Test names containing review identifiers remain regression coverage.

## Verified limits and unmeasured behavior

HDR gain-map expansion succeeded on Mac. The exercised iOS simulator process returned the SDR base for both simulator-generated and known Mac-generated JPEG fixtures, and lacked usable native reconstruction metadata. It now refuses that input explicitly. Separate linear DNG/TIFF and pipeline tests establish HDR coverage there; they do not establish gain-map codec support.

Real Canon EOS R7 CR3 input has **not been tested**. CR3 recognition and native RAW APIs do not establish decoding, orientation, color, metadata, HDR, memory use or export fidelity for that camera. Synthetic raster/DNG fixtures are not substitutes for real camera samples.

Physical-phone latency, image quality, memory behavior, ANE placement, Files-provider behavior, continued-processing scheduling and signed cross-app handoff remain unmeasured. CPU+NE requests do not prove accelerator placement. Mac/simulator results do not establish equivalence to another photo editor. No physical-device Xcode session, phone signing/install/uninstall/run, publication or deployment was performed during this validation.

Preserved product contracts include native system-green UI, fixed 2× QuickSRNet/EDSR choices at both memory tiers, denoise off, required production weights, durable mmap/journal replay, explicit saved model/dimensions/history, persistent before/after and non-destructive handling of human files/bookmarks/checkpoints.

## CI-host integration follow-up

The Xcode 27.1 hosted run passed all nine package suites, including the repaired Metal regressions, then reached its 20-minute limit as app-hosted tests began. The native budget is now 40 minutes within a 45-minute job. Hosted tests no longer link a second automatic package product: they resolve package code through the application test host. A fresh local DerivedData run passed 18 hosted tests with 1 optional documentation skip; duplicate-class diagnostics fell from 23 to 0, and all four built model assets verified.

The command supervisor now forwards SIGINT/SIGTERM only to its own unreaped command session, escalates resistant descendants, and atomically records the interruption. Eight Python metadata/process-supervision tests passed, including unrelated-process survival. This prevents canceled checks from leaving their task-owned child commands running. Stage reports also retain elapsed time. Current hosted completion and release status remain available in the GitHub workflow.

The following hosted run passed all nine package suites and three other gates, but its cold system share service exceeded a test helper's nominal 1.5-second wait. That test now uses a bounded 15-second monotonic deadline, waits for the actual native presentation transition to finish, reports the failed phase, and dismisses its controller before releasing the fixture window. All identity/stale-callback assertions remain. Three consecutive focused local runs passed; the complete app-hosted suite then passed 18 tests with one optional documentation skip. This test-only follow-up does not change application behavior or model assets; its final hosted status is established by CI.
