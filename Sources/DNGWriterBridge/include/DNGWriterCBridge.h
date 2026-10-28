#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// IFD selector used by `DNGMetadataEntry.ifd`.
enum {
    DNG_METADATA_IFD_MAIN = 0, ///< TIFF IFD0 (image / TIFF tags, DNG tags, XMP)
    DNG_METADATA_IFD_EXIF = 1, ///< EXIF IFD (referenced by tag 34665)
    DNG_METADATA_IFD_GPS  = 2  ///< GPS IFD (referenced by tag 34853)
};

/// TIFF 6.0 field type codes accepted by `DNGMetadataEntry.type`.
enum {
    DNG_TIFF_TYPE_BYTE      = 1,
    DNG_TIFF_TYPE_ASCII     = 2,
    DNG_TIFF_TYPE_SHORT     = 3,
    DNG_TIFF_TYPE_LONG      = 4,
    DNG_TIFF_TYPE_RATIONAL  = 5,
    DNG_TIFF_TYPE_SBYTE     = 6,
    DNG_TIFF_TYPE_UNDEFINED = 7,
    DNG_TIFF_TYPE_SSHORT    = 8,
    DNG_TIFF_TYPE_SLONG     = 9,
    DNG_TIFF_TYPE_SRATIONAL = 10,
    DNG_TIFF_TYPE_FLOAT     = 11,
    DNG_TIFF_TYPE_DOUBLE    = 12
};

/// One caller-supplied TIFF/EXIF/GPS field.
///
/// `data` must point at exactly `count * typeSize(type)` bytes encoded in little-endian
/// (TIFF byte order). The writer copies the bytes while the call is running, so the
/// caller may release them after `TSWriteStreamingLinearDNG16` returns.
typedef struct {
    uint16_t tag;       ///< TIFF tag id
    uint16_t ifd;       ///< DNG_METADATA_IFD_MAIN / EXIF / GPS
    uint16_t type;      ///< DNG_TIFF_TYPE_* value
    uint32_t count;     ///< element count
    const void* data;   ///< little-endian payload; required when count > 0
} DNGMetadataEntry;

/// Streaming rendered-Linear-DNG export configuration.
///
/// The writer produces an uncompressed 16-bit, 3-samples-per-pixel rendered
/// LinearRaw DNG (PhotometricInterpretation = 34892) holding absolute linear
/// Display P3 components (see `docs/DEVELOPMENT.md`):
///
/// * SDR (`sampleFormat = 1`, no ProfileDynamicRange): `q = round(clamp(v,0,1) * 65535)`,
///   DNGVersion 1.4.0.0, ColorimetricReference 1, WhiteLevel 65535, BaselineExposure 0.
/// * HDR (`sampleFormat = 3`, `profileDynamicRange = 1`): little-endian IEEE Float16 bit
///   patterns, DNGVersion 1.7.0.0, ColorimetricReference 2, WhiteLevel 1, BaselineExposure 0,
///   ProfileDynamicRange tag 52551 with `hintMaxOutputValue = H`.
///
/// Fields are intentionally ordered for source compatibility with the original
/// pre-repair C struct; the v2 and v3 fields were appended at the end.
typedef struct {
    uint32_t width;                 ///< Pixels per row (> 0)
    uint32_t height;                ///< Rows (> 0)
    uint32_t rowsPerStrip;          ///< Default 256; clamped to height
    const char* cameraMake;         ///< Nullable; default "TruongScaler"
    const char* cameraModel;        ///< Nullable; default "TruongScaler Linear RAW"
    const float* colorMatrix1;      ///< Nullable; 9 floats, XYZ(D65) -> linear Display P3.
                                    ///< When nil, the rendered-P3 inverse matrix is used.
                                    ///< Never pass source-camera calibration here.
    const float* asShotNeutral;     ///< Nullable; 3 floats. When nil/zero, {1,1,1} is written
                                    ///< (rendered pixels are already white-balanced).
    float baselineExposure;         ///< log2(H) headroom exponent. Default 0.
    uint16_t blackLevel;            ///< Default 0
    uint16_t whiteLevel;            ///< Default 65535; must be > blackLevel

    // ---- v2 additive fields (append-only; keep this order) ----
    uint16_t orientation;           ///< TIFF Orientation (1...8); 0 is treated as 1.
    const char* uniqueCameraModel;  ///< Nullable; default cameraModel / suite model
    const char* software;           ///< Nullable; default "TruongScaler 1.0 (ImagingSuite)".
                                    ///< Never contains a pipeline `Denoised=` marker.
    const char* imageDescription;   ///< Nullable; default generated headroom marker:
                                    ///< "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3;
                                    ///<  HeadroomScale=<H>; HeadroomEV=<log2 H>"
    const char* dateTime;           ///< Nullable; default current UTC (tag 306)
    const DNGMetadataEntry* metadataEntries; ///< Nullable when count == 0
    size_t metadataEntryCount;      ///< Number of entries in `metadataEntries`
    const void* xmpData;            ///< Nullable; raw XMP packet for IFD0 tag 700
    size_t xmpByteCount;            ///< Bytes in `xmpData`
    uint16_t colorimetricReference; ///< DNG 50879. 0 is derived: 1 for SDR, 2 for HDR.

    // ---- v3 additive fields (R8; append-only; keep this order) ----
    /// TIFF SampleFormat (tag 339). 1 = unsigned integer (SDR), 3 = IEEE floating point (HDR).
    /// 0 is derived from `profileDynamicRange`/`hintMaxOutputValue`: float when HDR, integer for SDR.
    uint16_t sampleFormat;
    /// 1 = write DNG ProfileDynamicRange tag 52551 (HDR profile); 0 = omit (SDR default).
    uint16_t profileDynamicRange;
    /// `HintMaxOutputValue` (H) for HDR profiles. > 0 writes the hint; 0 omits it (SDR).
    /// Must be finite, > 0 and <= 65504 when `profileDynamicRange == 1`.
    float hintMaxOutputValue;
    /// Explicit DNGVersion components (tag 50706). All zero derives 1.4.0.0 for SDR and
    /// 1.7.0.0 for HDR. A non-zero major enables caller-supplied version components.
    uint16_t dngVersionMajor;
    uint16_t dngVersionMinor;
    uint16_t dngVersionPatch;
    uint16_t dngVersionBuild;
    /// Explicit DNGBackwardVersion components (tag 50707). All zero derives 1.1.0.0 for SDR
    /// and 1.7.0.0 for HDR.
    uint16_t dngBackwardVersionMajor;
    uint16_t dngBackwardVersionMinor;
    uint16_t dngBackwardVersionPatch;
    uint16_t dngBackwardVersionBuild;
} DNGLinearExportConfig;

/// Callback invoked by the C++ DNG writer for each strip [startRow ..< startRow + rowCount].
/// The callee must fill `dstRGB16Buffer` with `width * rowCount * 3` little-endian uint16_t values.
/// Returns true on success, false to abort.
typedef bool (*DNGStripFillCallback)(
    void* userContext,
    uint32_t startRow,
    uint32_t rowCount,
    uint16_t* dstRGB16Buffer
);

/// Writes a 16-bit uncompressed rendered Linear DNG by streaming strips via
/// `stripCallback`. SDR output is DNG 1.4.0.0 / ColorimetricReference 1 with quantized
/// UInt16 samples; HDR output is DNG 1.7.0.0 / ColorimetricReference 2 with absolute
/// IEEE Float16 bit patterns. Lays out IFD0 + optional EXIF IFD (34665) + GPS IFD (34853)
/// + XMP (700), sorts IFD0 entries ascending, and writes correct offsets/byte counts.
///
/// Only one strip buffer (`width * rowsPerStrip * 3` uint16 values) is allocated; the
/// full canvas is never materialized. With `sampleFormat = 3` the callback's UInt16 words
/// are written verbatim as little-endian Float16 bit patterns (no reinterpretation).
///
/// On failure returns false, fills `errorOutBuffer` with an actionable message, and
/// removes the partially written file. Total pixel payloads beyond the classic 32-bit
/// TIFF limit (> 4 GiB) are rejected explicitly; BigTIFF is not implemented.
bool TSWriteStreamingLinearDNG16(
    const char* outputFilePath,
    const DNGLinearExportConfig* config,
    DNGStripFillCallback stripCallback,
    void* userContext,
    char* errorOutBuffer,
    size_t errorOutBufferCapacity
);

#ifdef __cplusplus
}
#endif
