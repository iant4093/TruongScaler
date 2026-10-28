# Validation record

The launch/repository baseline was validated locally on **2026-10-28**; the subsequent hosted-GPU precision follow-up is recorded separately below. Current commands and required checks are in [DEVELOPMENT.md](DEVELOPMENT.md). Generated logs/results stay in the ignored `build/` directory. The preceding application review is recorded separately below; historical agent evidence is archived outside the source repository.



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
