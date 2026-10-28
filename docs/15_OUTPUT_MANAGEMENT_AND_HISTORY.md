# Output management, sharing and processing history

## Libraries and portable results

Input accepts an arbitrary recursive folder of supported photos/RAWs, including loose files. Output is selected and bookmarked independently. Input cannot be nested inside Output; an Output subtree inside Input is excluded from input scans. Known TruongCam metadata/sequence trees are excluded. Failed reconnects preserve bookmarks and existing files.

Before inference, the app freezes the original bytes into content-addressed `comparison-originals/<SHA-256>.<ext>`. That same immutable copy supplies processing and future before/after. Completed photos publish under `originals/YYYY/MM/DD/TS_<jobUUID>.<ext>`, with portable records under `metadata/originals/YYYY/MM/DD/` and small SDR browsing previews under `thumbnails/originals/`. Records preserve hashes, relative paths, actual dimensions, model identifier, scale, grain, format and completion date. Interrupted publication recovers only when saved hashes match; conflicting final files are not overwritten.

Reopening verifies the saved output and retains its recorded model independently of the next-job picker. An absent, changed or unsafe optional original leaves the valid output viewable with a comparison warning. Output retries repeat record verification rather than treating an export as new input. Older app-marked exports without a record remain viewable/shareable with explicit missing model/comparison information; filenames never establish model identity. Thumbnails remain browsing derivatives, not the processing/comparison/export authority.

## Share ownership and latency

A saved photo is shared without exporting or re-encoding it again. The fullscreen viewer owns its native share sheet; batch sharing belongs to the library. They cannot present the same export. This fixes the share sheet being queued behind the fullscreen viewer (“only presenting a single sheet is supported”).

Before presentation, a background I/O owner makes private byte-identical snapshots (APFS clone when available, coordinated copy otherwise). Recorded output SHA-256 values are checked. A share item supplies its type, title and a small system icon explicitly, avoiding a full-resolution DNG decode to produce a preview. Files live until the presenting sheet's dismissal, including an activity extension's use of them. No Photos authorization or writes occur unless the user selects Save Original to Photos.

## Output-only trash

Delete in an Output viewer or Output selection moves app-generated results, their portable records and thumbnails into `.trash/<UUID>/`. Recently Deleted supports selection, Restore and confirmed Delete Permanently. There is no timed automatic deletion. Input has no deletion action and cannot be nested inside the selected Output root. An Output subfolder of Input is allowed and excluded from Input scans.

Each trash entry has a version, owner, hashes, byte counts, original relative paths and a durable move/restore/purge intent. Metadata moves last. Recovery tolerates a partially moved/restored/purged operation. Destinations are never overwritten; changed files and symlinks are refused. A stale confirmation cannot be applied after the root changes. Batches can finish partially when a provider fails; already moved photos remain recoverable. Unrecognized files in a trash directory are never recursively removed.

`comparison-originals/` is shared and retained even when one result is permanently deleted. This protects other comparisons and durable checkpoints; permanently deleting an output does not promise to reclaim its shared original. No automated original cleanup is performed. Human photos/bookmarks/checkpoints are not reset during development or validation.

## Metadata interchange with TruongNoiser

All new Scaler exports preserve the existing ImagingSuite flags (`UpscaledByApp`, `UpscaledFactor`, `Denoised`, `NoiserDenoised`) and add `ScalerUpscaled`. Explicit boolean state remains value-aware; a generic denoise flag alone does not identify Noiser. Info says “app not recorded” for that older state and “Not recorded” when evidence is absent. These are recorded processing claims, not authenticated signatures.

`ProcessingHistoryV1=<base64(JSON)>` is embedded in raster EXIF UserComment and Linear DNG ImageDescription/UserComment/XMP description. JSON schema:

```json
{"version":1,"steps":[{"id":"job UUID","app":"com.iantruong.truongscaler","operation":"upscale","model":"QuickSRNet-Large","scale":2,"date":0,"inputWidth":3024,"inputHeight":4032,"outputWidth":6048,"outputHeight":8064}]}
```

Dates use Foundation Codable seconds since 2001-01-01, and are optional. Step identity is `(id,app,operation)`. Re-exporting a completed job does not append duplicates. The native Scaler event uses actual artifact dimensions/factor/model and the checkpoint completion timestamp. No denoise event is fabricated for old boolean markers. Events contain no file paths, file names or device identifiers. History is bounded to the latest 32 events / 16 KiB JSON, with bounded strings/dimensions; malformed or unknown versions are ignored. Base64 is case-sensitive and parsed before lowercasing legacy marker text. Future marker versions and unrelated comments remain untouched.

For interoperable Noiser history, a producer should preserve inherited flags and ordered history, append its own `denoise` event (`app=com.iantruong.truongnoiser`), and write both `Denoised=true` and `NoiserDenoised=true`. Scaler preserves that evidence when upscaling. The handoff's embedded image already carries this history; generic handoff state only attributes denoising to Noiser when the manifest source identifies Noiser. This contract does not claim that TruongNoiser implements or has been tested against it.

## Before/after semantics

“Before” is the byte-frozen input to the current processing step, archived with the result, and “After” is its saved result. Noiser → Scaler therefore compares denoised input against denoised + upscaled output. Scaler → Noiser should compare upscaled input against upscaled + denoised output in Noiser. This avoids attributing an earlier app's changes to the current model.

A comparison all the way from camera original to the final multi-app result needs the actual original and stage associations. Flags/history alone cannot recreate pixels. Scaler does not invent that comparison, follow untrusted external paths, or modify previous results. Older results without a saved source retain their explicit comparison-unavailable state.

## Validation commands

`swift test --disable-sandbox` exercises storage recovery, metadata round trips and lifecycle contracts. The package's UIKit cases must also execute on a dedicated simulator. The hosted `TruongScalerHostTests` suite additionally exercises the trained pipeline, fullscreen viewer and native sharing inside the app's real UIApplication scene, with isolated preferences and disposable photo folders. Standalone `xctest` cannot attach UIKit modal presentations in its synthetic screen scene and does not prove native share presentation. See [DEVELOPMENT.md](DEVELOPMENT.md) for commands and [VALIDATION.md](VALIDATION.md) for executed results and unmeasured behavior. Physical-phone execution requires applicable authorization.
