#include "DNGWriterCBridge.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <limits>
#include <new>
#include <string>
#include <vector>

namespace {

#pragma pack(push, 1)
struct TIFFEntry {
    uint16_t tag;
    uint16_t type;
    uint32_t count;
    uint32_t valueOrOffset;
};
#pragma pack(pop)

enum TIFFType : uint16_t {
    TIFF_BYTE = 1,
    TIFF_ASCII = 2,
    TIFF_SHORT = 3,
    TIFF_LONG = 4,
    TIFF_RATIONAL = 5,
    TIFF_SBYTE = 6,
    TIFF_UNDEFINED = 7,
    TIFF_SSHORT = 8,
    TIFF_SLONG = 9,
    TIFF_SRATIONAL = 10,
    TIFF_FLOAT = 11,
    TIFF_DOUBLE = 12
};

/// Classic (non-Big) TIFF stores every offset/byte count in a uint32.
static const uint64_t kClassicTIFFMaxOffset = 0xFFFFFFFFULL;
static const uint16_t kPhotometricLinearRaw = 34892;
static const uint16_t kTagImageDescription = 270;
static const uint16_t kTagMake = 271;
static const uint16_t kTagModel = 272;
static const uint16_t kTagSoftware = 305;
static const uint16_t kTagDateTime = 306;
static const uint16_t kTagXMP = 700;
static const uint16_t kTagExifIFD = 34665;
static const uint16_t kTagGPSIFD = 34853;
static const uint16_t kTagProfileDynamicRange = 52551;

struct PendingTag {
    uint16_t tag = 0;
    uint16_t type = 0;
    uint32_t count = 0;
    std::vector<uint8_t> payload;
};

struct IfdPlan {
    std::vector<PendingTag> tags;
    std::vector<uint32_t> extraOffsets;
    uint32_t offset = 0;
};

static size_t tiffTypeSize(uint16_t type) {
    switch (type) {
        case TIFF_BYTE:
        case TIFF_ASCII:
        case TIFF_SBYTE:
        case TIFF_UNDEFINED:
            return 1;
        case TIFF_SHORT:
        case TIFF_SSHORT:
            return 2;
        case TIFF_LONG:
        case TIFF_SLONG:
        case TIFF_FLOAT:
            return 4;
        case TIFF_RATIONAL:
        case TIFF_SRATIONAL:
        case TIFF_DOUBLE:
            return 8;
        default:
            return 0;
    }
}

static void appendLE16(std::vector<uint8_t>& b, uint16_t v) {
    b.push_back(static_cast<uint8_t>(v & 0xFF));
    b.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
}

static void appendLE32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 0; i < 4; ++i) {
        b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
    }
}

static void appendBE16(std::vector<uint8_t>& b, uint16_t v) {
    b.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    b.push_back(static_cast<uint8_t>(v & 0xFF));
}

static void appendBE32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 3; i >= 0; --i) {
        b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
    }
}

static std::vector<uint8_t> shortPayload(const std::vector<uint16_t>& values) {
    std::vector<uint8_t> payload;
    payload.reserve(values.size() * 2);
    for (uint16_t v : values) appendLE16(payload, v);
    return payload;
}

static std::vector<uint8_t> longPayload(const std::vector<uint32_t>& values) {
    std::vector<uint8_t> payload;
    payload.reserve(values.size() * 4);
    for (uint32_t v : values) appendLE32(payload, v);
    return payload;
}

static std::vector<uint8_t> bytePayload(const std::vector<uint8_t>& values) {
    return values;
}

static void addTag(std::vector<PendingTag>& tags,
                   uint16_t tag,
                   uint16_t type,
                   uint32_t count,
                   std::vector<uint8_t> payload) {
    PendingTag t;
    t.tag = tag;
    t.type = type;
    t.count = count;
    t.payload = std::move(payload);
    tags.push_back(std::move(t));
}

static void addShortTag(std::vector<PendingTag>& tags, uint16_t tag, uint16_t value) {
    addTag(tags, tag, TIFF_SHORT, 1, shortPayload({value}));
}

static void addShort3Tag(std::vector<PendingTag>& tags, uint16_t tag,
                         uint16_t v0, uint16_t v1, uint16_t v2) {
    addTag(tags, tag, TIFF_SHORT, 3, shortPayload({v0, v1, v2}));
}

static void addLongTag(std::vector<PendingTag>& tags, uint16_t tag, uint32_t value) {
    addTag(tags, tag, TIFF_LONG, 1, longPayload({value}));
}

static void addLong3Tag(std::vector<PendingTag>& tags, uint16_t tag,
                        uint32_t v0, uint32_t v1, uint32_t v2) {
    addTag(tags, tag, TIFF_LONG, 3, longPayload({v0, v1, v2}));
}

static void addAsciiTag(std::vector<PendingTag>& tags, uint16_t tag, const std::string& s) {
    std::vector<uint8_t> payload(s.begin(), s.end());
    payload.push_back(0);
    addTag(tags, tag, TIFF_ASCII, static_cast<uint32_t>(payload.size()), std::move(payload));
}

static void addByte4Tag(std::vector<PendingTag>& tags, uint16_t tag,
                        uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) {
    addTag(tags, tag, TIFF_BYTE, 4, bytePayload({b0, b1, b2, b3}));
}

static PendingTag* findTag(std::vector<PendingTag>& tags, uint16_t tag) {
    for (auto& t : tags) {
        if (t.tag == tag) return &t;
    }
    return nullptr;
}

static const PendingTag* findTag(const std::vector<PendingTag>& tags, uint16_t tag) {
    for (const auto& t : tags) {
        if (t.tag == tag) return &t;
    }
    return nullptr;
}

/// IFD0 tags owned by the writer. Metadata entries may replace only the descriptive
/// subset below; structural tags would corrupt the container, so collisions are errors.
static bool isReservedMainTag(uint16_t tag) {
    switch (tag) {
        case 254: case 256: case 257: case 258: case 259: case 262:
        case 273: case 274: case 277: case 278: case 279: case 284:
        case 339: case 34665: case 34853:
        case 50706: case 50707: case 50708: case 50714: case 50717:
        case 50721: case 50728: case 50730: case 50778: case 50879:
        case 52551:
            return true;
        default:
            return false;
    }
}

static bool isOverridableMainTag(uint16_t tag) {
    switch (tag) {
        case kTagImageDescription: case kTagMake: case kTagModel:
        case kTagSoftware: case kTagDateTime: case kTagXMP:
            return true;
        default:
            return false;
    }
}

static uint32_t alignUp2(uint64_t value) {
    return static_cast<uint32_t>((value + 1) & ~static_cast<uint64_t>(1));
}

static uint32_t alignUp16(uint64_t value) {
    return static_cast<uint32_t>((value + 15) & ~static_cast<uint64_t>(15));
}

static std::string defaultDateTimeUTC() {
    std::time_t now = std::time(nullptr);
    std::tm tmValue{};
#if defined(_WIN32)
    gmtime_s(&tmValue, &now);
#else
    gmtime_r(&now, &tmValue);
#endif
    char buffer[32] = {0};
    std::strftime(buffer, sizeof(buffer), "%Y:%m:%d %H:%M:%S", &tmValue);
    return std::string(buffer);
}

static std::vector<uint8_t> srationalMatrix(const float* matrix) {
    static const double kLinearDisplayP3InverseXYZ[9] = {
         2.4934969119414254, -0.9313836179191239, -0.40271078445071684,
        -0.8294889695615747,  1.7626640603183463,  0.023624685841943577,
         0.0358458302437845, -0.07617238926804182, 0.9568845240076872
    };
    std::vector<uint8_t> payload;
    payload.reserve(72);
    for (int i = 0; i < 9; ++i) {
        double value = matrix ? static_cast<double>(matrix[i]) : kLinearDisplayP3InverseXYZ[i];
        if (!std::isfinite(value)) value = 0.0;
        long long numerator = std::llround(value * 1000000.0);
        if (numerator > std::numeric_limits<int32_t>::max()) numerator = std::numeric_limits<int32_t>::max();
        if (numerator < std::numeric_limits<int32_t>::min()) numerator = std::numeric_limits<int32_t>::min();
        appendLE32(payload, static_cast<uint32_t>(static_cast<int32_t>(numerator)));
        appendLE32(payload, 1000000u);
    }
    return payload;
}

static std::vector<uint8_t> rationalTriple(const float* values) {
    std::vector<uint8_t> payload;
    payload.reserve(24);
    for (int i = 0; i < 3; ++i) {
        double value = values ? static_cast<double>(values[i]) : 1.0;
        if (!std::isfinite(value) || value <= 0.0) value = 1.0;
        if (value < 1e-6) value = 1e-6;
        uint32_t numerator = static_cast<uint32_t>(std::llround(value * 10000.0));
        if (numerator == 0) numerator = 1;
        appendLE32(payload, numerator);
        appendLE32(payload, 10000u);
    }
    return payload;
}

static bool appendSrational(std::vector<uint8_t>& payload, double value) {
    if (!std::isfinite(value)) return false;
    long long numerator = std::llround(value * 1000000.0);
    if (numerator > std::numeric_limits<int32_t>::max()) return false;
    if (numerator < std::numeric_limits<int32_t>::min()) return false;
    appendLE32(payload, static_cast<uint32_t>(static_cast<int32_t>(numerator)));
    appendLE32(payload, 1000000u);
    return true;
}

} // namespace

extern "C" bool TSWriteStreamingLinearDNG16(
    const char* outputFilePath,
    const DNGLinearExportConfig* config,
    DNGStripFillCallback stripCallback,
    void* userContext,
    char* errorOutBuffer,
    size_t errorOutBufferCapacity
) {
    auto writeErr = [&](const char* msg) -> bool {
        if (errorOutBuffer && errorOutBufferCapacity > 0) {
            std::snprintf(errorOutBuffer, errorOutBufferCapacity, "%s", msg);
        }
        return false;
    };

    if (!outputFilePath || !config || !stripCallback) {
        return writeErr("Invalid DNG export parameters");
    }
    if (config->width == 0 || config->height == 0) {
        return writeErr("Invalid DNG dimensions: width and height must be > 0");
    }
    if (config->metadataEntryCount > 0 && config->metadataEntries == nullptr) {
        return writeErr("DNG metadata entries pointer is null while count is non-zero");
    }

    const uint32_t W = config->width;
    const uint32_t H = config->height;
    uint32_t rowsPerStrip = config->rowsPerStrip > 0 ? config->rowsPerStrip : 256;
    if (rowsPerStrip > H) rowsPerStrip = H;

    const uint64_t numStrips64 = (static_cast<uint64_t>(H) + rowsPerStrip - 1) / rowsPerStrip;
    if (numStrips64 == 0 || numStrips64 > 0xFFFFFFFFULL) {
        return writeErr("DNG strip count is not representable");
    }
    const uint32_t numStrips = static_cast<uint32_t>(numStrips64);

    uint16_t orientation = config->orientation;
    if (orientation == 0) orientation = 1;
    if (orientation > 8) {
        return writeErr("DNG orientation must be in 1...8");
    }

    // ---- R8 representation selection and consistency validation ----
    if (config->profileDynamicRange != 0 && config->profileDynamicRange != 1) {
        return writeErr("DNG profileDynamicRange must be 0 (omit) or 1 (HDR)");
    }
    const bool hdrProfile = config->profileDynamicRange == 1;
    uint16_t sampleFormat = config->sampleFormat;
    if (sampleFormat == 0) sampleFormat = hdrProfile ? 3 : 1;
    if (sampleFormat != 1 && sampleFormat != 3) {
        return writeErr("DNG sampleFormat must be 1 (unsigned integer) or 3 (IEEE float)");
    }
    const bool floatSamples = sampleFormat == 3;

    const double hintMaxOutputValue = static_cast<double>(config->hintMaxOutputValue);
    if (!std::isfinite(hintMaxOutputValue) || hintMaxOutputValue < 0.0) {
        return writeErr("DNG hintMaxOutputValue must be finite and >= 0");
    }
    if (hdrProfile) {
        if (hintMaxOutputValue <= 0.0 || hintMaxOutputValue > 65504.0) {
            return writeErr("HDR ProfileDynamicRange requires a finite hintMaxOutputValue in (0, 65504]");
        }
        if (!floatSamples) {
            return writeErr("HDR ProfileDynamicRange requires 16-bit IEEE Float samples (sampleFormat=3)");
        }
    } else if (hintMaxOutputValue > 0.0) {
        return writeErr("hintMaxOutputValue requires profileDynamicRange=1 (HDR)");
    }

    uint16_t colorimetricReference = config->colorimetricReference;
    if (colorimetricReference == 0) colorimetricReference = hdrProfile ? 2 : 1;
    if (colorimetricReference != 1 && colorimetricReference != 2) {
        return writeErr("DNG colorimetricReference must be 1 (perceptual SDR) or 2 (HDR)");
    }
    if (hdrProfile) {
        if (colorimetricReference != 2) {
            return writeErr("HDR output-referred DNG requires ColorimetricReference=2");
        }
    } else if (colorimetricReference != 1) {
        return writeErr("SDR rendered DNG requires ColorimetricReference=1");
    }

    // New files never use BaselineExposure as a headroom multiplier: encoding is either
    // q/65535 (SDR) or absolute Float16 (HDR). The legacy integer+H encoding is read-only
    // backward compatibility and is no longer written.
    const double baselineExposure = static_cast<double>(config->baselineExposure);
    if (!std::isfinite(baselineExposure)) {
        return writeErr("DNG baselineExposure must be finite");
    }
    if (std::fabs(baselineExposure) > 1e-6) {
        return writeErr("Rendered DNG BaselineExposure must be 0; HDR overrange is stored as "
                        "absolute Float16 samples with ProfileDynamicRange");
    }

    auto readVersion = [](uint16_t major, uint16_t minor, uint16_t patch, uint16_t build,
                          uint16_t derivedMajor, uint16_t derivedMinor,
                          uint16_t out[4]) {
        if (major == 0 && minor == 0 && patch == 0 && build == 0) {
            out[0] = derivedMajor; out[1] = derivedMinor; out[2] = 0; out[3] = 0;
        } else {
            if (major == 0) return false;
            out[0] = major; out[1] = minor; out[2] = patch; out[3] = build;
        }
        return true;
    };
    uint16_t dngVersion[4] = {0, 0, 0, 0};
    uint16_t dngBackwardVersion[4] = {0, 0, 0, 0};
    const uint16_t derivedMinor = hdrProfile ? 7 : 4;
    const uint16_t derivedBackwardMinor = hdrProfile ? 7 : 1;
    if (!readVersion(config->dngVersionMajor, config->dngVersionMinor,
                     config->dngVersionPatch, config->dngVersionBuild,
                     1, derivedMinor, dngVersion)) {
        return writeErr("DNGVersion major must be non-zero when any version component is supplied");
    }
    if (!readVersion(config->dngBackwardVersionMajor, config->dngBackwardVersionMinor,
                     config->dngBackwardVersionPatch, config->dngBackwardVersionBuild,
                     1, derivedBackwardMinor, dngBackwardVersion)) {
        return writeErr("DNGBackwardVersion major must be non-zero when any component is supplied");
    }
    auto versionAtLeast = [](const uint16_t version[4], uint16_t major, uint16_t minor) {
        if (version[0] != major) return version[0] > major;
        return version[1] >= minor;
    };
    if (floatSamples && !versionAtLeast(dngVersion, 1, 4)) {
        return writeErr("IEEE floating point samples require DNGVersion 1.4.0.0 or later");
    }
    if (hdrProfile) {
        if (!versionAtLeast(dngVersion, 1, 7)) {
            return writeErr("HDR output-referred DNG requires DNGVersion 1.7.0.0 or later");
        }
        if (!versionAtLeast(dngBackwardVersion, 1, 7)) {
            return writeErr("HDR output-referred DNG requires DNGBackwardVersion 1.7.0.0 or later");
        }
    }
    if (!versionAtLeast(dngBackwardVersion, 1, 1)) {
        return writeErr("DNGBackwardVersion must be at least 1.1.0.0");
    }

    uint16_t whiteLevel = config->whiteLevel;
    if (whiteLevel == 0) whiteLevel = floatSamples ? 1 : 65535;
    if (whiteLevel <= config->blackLevel) {
        return writeErr("DNG whiteLevel must be greater than blackLevel");
    }
    if (floatSamples && whiteLevel != 1) {
        return writeErr("floating point DNG WhiteLevel must be 1 (DNG 1.7.1 p29)");
    }
    if (!floatSamples && whiteLevel != 65535) {
        return writeErr("16-bit unsigned SDR DNG WhiteLevel must be 65535");
    }

    // Rendered pixels are 3 x uint16 per pixel. Classic TIFF (not BigTIFF) cannot
    // address more than 4 GiB, so reject the export explicitly instead of writing
    // truncated/wrapped offsets.
    const uint64_t totalPixelBytes = static_cast<uint64_t>(W) * static_cast<uint64_t>(H) * 6ULL;
    if (totalPixelBytes > kClassicTIFFMaxOffset) {
        return writeErr("Rendered Linear DNG exceeds the classic TIFF 32-bit limit (4 GiB); "
                        "BigTIFF is not implemented, reduce the output dimensions");
    }
    const uint64_t maxStripBytes = static_cast<uint64_t>(rowsPerStrip) * static_cast<uint64_t>(W) * 6ULL;
    if (maxStripBytes > kClassicTIFFMaxOffset) {
        return writeErr("DNG strip byte count exceeds the classic TIFF 32-bit limit (4 GiB)");
    }

    IfdPlan ifds[3];

    // ---- IFD0 (main image / DNG) ----
    std::vector<PendingTag>& main = ifds[0].tags;
    addLongTag(main, 254, 0);                          // NewSubfileType: full resolution
    addLongTag(main, 256, W);                          // ImageWidth
    addLongTag(main, 257, H);                          // ImageLength
    addShort3Tag(main, 258, 16, 16, 16);               // BitsPerSample
    addShortTag(main, 259, 1);                         // Compression: none
    addShortTag(main, 262, kPhotometricLinearRaw);     // PhotometricInterpretation: LinearRaw
    addAsciiTag(main, kTagMake, config->cameraMake ? config->cameraMake : "TruongScaler");
    addAsciiTag(main, kTagModel, config->cameraModel ? config->cameraModel : "TruongScaler Linear RAW");

    addTag(main, 273, TIFF_LONG, numStrips, std::vector<uint8_t>(static_cast<size_t>(numStrips) * 4, 0));
    addShortTag(main, 274, orientation);               // Orientation (pixels are already upright)
    addShortTag(main, 277, 3);                         // SamplesPerPixel
    addLongTag(main, 278, rowsPerStrip);               // RowsPerStrip

    std::vector<uint32_t> stripByteCounts;
    stripByteCounts.reserve(numStrips);
    for (uint32_t s = 0; s < numStrips; ++s) {
        const uint64_t startRow = static_cast<uint64_t>(s) * rowsPerStrip;
        const uint64_t remaining = static_cast<uint64_t>(H) - startRow;
        const uint64_t rows = std::min<uint64_t>(rowsPerStrip, remaining);
        stripByteCounts.push_back(static_cast<uint32_t>(rows * W * 6ULL));
    }
    addTag(main, 279, TIFF_LONG, numStrips, longPayload(stripByteCounts));
    addShortTag(main, 284, 1);                         // PlanarConfiguration: chunky
    addShort3Tag(main, 339, sampleFormat, sampleFormat, sampleFormat); // SampleFormat

    const std::string software = config->software
        ? std::string(config->software)
        : std::string("TruongScaler 1.0 (ImagingSuite)");
    addAsciiTag(main, kTagSoftware, software);

    const std::string dateTime = config->dateTime ? std::string(config->dateTime) : defaultDateTimeUTC();
    addAsciiTag(main, kTagDateTime, dateTime);

    const double displayHeadroom = hdrProfile ? hintMaxOutputValue : 1.0;
    std::string imageDescription;
    if (config->imageDescription) {
        imageDescription = config->imageDescription;
    } else {
        char description[320] = {0};
        if (floatSamples) {
            std::snprintf(description, sizeof(description),
                          "TruongScaler Linear DNG; SampleFormat=Float16; "
                          "WorkingSpace=LinearDisplayP3; HeadroomScale=%.6g; HeadroomEV=%.6g",
                          displayHeadroom, std::log2(displayHeadroom));
        } else {
            std::snprintf(description, sizeof(description),
                          "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; "
                          "HeadroomScale=%.6g; HeadroomEV=%.6g",
                          displayHeadroom, std::log2(displayHeadroom));
        }
        imageDescription = description;
    }
    addAsciiTag(main, kTagImageDescription, imageDescription);

    if (config->xmpByteCount > 0) {
        if (!config->xmpData) {
            return writeErr("DNG XMP pointer is null while xmpByteCount is non-zero");
        }
        if (config->xmpByteCount > kClassicTIFFMaxOffset) {
            return writeErr("DNG XMP payload exceeds the classic TIFF 32-bit limit");
        }
        std::vector<uint8_t> xmp(static_cast<size_t>(config->xmpByteCount));
        std::memcpy(xmp.data(), config->xmpData, static_cast<size_t>(config->xmpByteCount));
        addTag(main, kTagXMP, TIFF_BYTE, static_cast<uint32_t>(xmp.size()), std::move(xmp));
    }

    // Placeholders; their offsets are filled after all IFD sizes are known.
    addLongTag(main, kTagExifIFD, 0);
    addLongTag(main, kTagGPSIFD, 0);

    addByte4Tag(main, 50706, static_cast<uint8_t>(dngVersion[0]), static_cast<uint8_t>(dngVersion[1]),
                static_cast<uint8_t>(dngVersion[2]), static_cast<uint8_t>(dngVersion[3]));
    addByte4Tag(main, 50707, static_cast<uint8_t>(dngBackwardVersion[0]), static_cast<uint8_t>(dngBackwardVersion[1]),
                static_cast<uint8_t>(dngBackwardVersion[2]), static_cast<uint8_t>(dngBackwardVersion[3]));
    const std::string uniqueCameraModel = config->uniqueCameraModel
        ? std::string(config->uniqueCameraModel)
        : (config->cameraModel ? std::string(config->cameraModel) : std::string("TruongScaler Linear RAW"));
    addAsciiTag(main, 50708, uniqueCameraModel);       // UniqueCameraModel
    addShort3Tag(main, 50714, config->blackLevel, config->blackLevel, config->blackLevel);
    addLong3Tag(main, 50717, whiteLevel, whiteLevel, whiteLevel);
    addTag(main, 50721, TIFF_SRATIONAL, 9, srationalMatrix(config->colorMatrix1));
    addTag(main, 50728, TIFF_RATIONAL, 3, rationalTriple(config->asShotNeutral));

    std::vector<uint8_t> baselinePayload;
    if (!appendSrational(baselinePayload, 0.0)) {
        return writeErr("DNG baselineExposure is outside the representable SRATIONAL range");
    }
    addTag(main, 50730, TIFF_SRATIONAL, 1, std::move(baselinePayload));
    addShortTag(main, 50778, 21);                      // CalibrationIlluminant1: D65
    addShortTag(main, 50879, colorimetricReference);   // ColorimetricReference: 1 SDR / 2 HDR

    if (hdrProfile) {
        // ProfileDynamicRange (52551, DNG 1.7.1 p94): SHORT version=1, SHORT dynamicRange=1
        // (HDR), FLOAT HintMaxOutputValue (linear-gamma absolute peak).
        // The DNG spec does not state the byte order of this packed UNDEFINED struct; Adobe
        // DNG files and ExifTool's DNG table use BIG-endian for the inner fields even in a
        // little-endian TIFF ("not indicated in spec"). The outer TIFF stays little-endian.
        std::vector<uint8_t> payload;
        payload.reserve(8);
        appendBE16(payload, 1);
        appendBE16(payload, 1);
        const float hint = static_cast<float>(hintMaxOutputValue);
        uint32_t hintBits = 0;
        std::memcpy(&hintBits, &hint, 4);
        appendBE32(payload, hintBits);
        addTag(main, kTagProfileDynamicRange, TIFF_UNDEFINED, 8, std::move(payload));
    }

    // ---- Caller-supplied EXIF / GPS / IFD0 metadata ----
    for (size_t i = 0; i < config->metadataEntryCount; ++i) {
        const DNGMetadataEntry& entry = config->metadataEntries[i];
        if (entry.ifd > DNG_METADATA_IFD_GPS) {
            return writeErr("DNG metadata entry has an invalid IFD selector");
        }
        const size_t elementSize = tiffTypeSize(entry.type);
        if (elementSize == 0) {
            return writeErr("DNG metadata entry has an unsupported TIFF field type");
        }
        const uint64_t byteCount64 = static_cast<uint64_t>(entry.count) * elementSize;
        if (byteCount64 > kClassicTIFFMaxOffset) {
            return writeErr("DNG metadata entry payload exceeds the classic TIFF 32-bit limit");
        }
        const size_t byteCount = static_cast<size_t>(byteCount64);
        if (byteCount > 0 && entry.data == nullptr) {
            return writeErr("DNG metadata entry data pointer is null");
        }

        std::vector<PendingTag>& target = ifds[entry.ifd].tags;
        PendingTag* existing = findTag(target, entry.tag);
        if (entry.ifd == DNG_METADATA_IFD_MAIN) {
            if (isReservedMainTag(entry.tag)) {
                return writeErr("DNG metadata entry collides with a writer-owned structural tag");
            }
            if (existing && !isOverridableMainTag(entry.tag)) {
                return writeErr("DNG metadata entry duplicates a writer-owned IFD0 tag");
            }
        } else if (existing) {
            return writeErr("DNG metadata entry contains a duplicate EXIF/GPS tag");
        }

        std::vector<uint8_t> payload(byteCount);
        if (byteCount > 0) {
            std::memcpy(payload.data(), entry.data, byteCount);
        }
        if (existing) {
            existing->type = entry.type;
            existing->count = entry.count;
            existing->payload = std::move(payload);
        } else {
            addTag(target, entry.tag, entry.type, entry.count, std::move(payload));
        }
    }

    // Ascending tag order is required by TIFF readers.
    for (auto& ifd : ifds) {
        std::sort(ifd.tags.begin(), ifd.tags.end(),
                  [](const PendingTag& a, const PendingTag& b) { return a.tag < b.tag; });
        if (ifd.tags.size() > 0xFFFFULL) {
            return writeErr("DNG IFD has more than 65535 entries");
        }
    }

    const uint64_t ifd0Size = 2ULL + 12ULL * ifds[0].tags.size() + 4ULL;
    const uint64_t exifSize = 2ULL + 12ULL * ifds[1].tags.size() + 4ULL;
    const uint64_t gpsSize = 2ULL + 12ULL * ifds[2].tags.size() + 4ULL;
    const uint64_t exifOffset64 = 8ULL + ifd0Size;
    const uint64_t gpsOffset64 = exifOffset64 + exifSize;
    const uint64_t extraStart64 = gpsOffset64 + gpsSize;
    if (extraStart64 > kClassicTIFFMaxOffset) {
        return writeErr("DNG metadata header exceeds the classic TIFF 32-bit limit (4 GiB)");
    }

    ifds[0].offset = 8;
    ifds[1].offset = static_cast<uint32_t>(exifOffset64);
    ifds[2].offset = static_cast<uint32_t>(gpsOffset64);

    if (PendingTag* pointer = findTag(ifds[0].tags, kTagExifIFD)) {
        pointer->payload = longPayload({ifds[1].offset});
    }
    if (PendingTag* pointer = findTag(ifds[0].tags, kTagGPSIFD)) {
        pointer->payload = longPayload({ifds[2].offset});
    }

    // Extra payload area after the three IFDs.
    uint64_t extraCursor = extraStart64;
    for (auto& ifd : ifds) {
        ifd.extraOffsets.assign(ifd.tags.size(), 0);
        for (size_t i = 0; i < ifd.tags.size(); ++i) {
            if (ifd.tags[i].payload.size() > 4) {
                extraCursor = (extraCursor + 1) & ~static_cast<uint64_t>(1);
                if (extraCursor > kClassicTIFFMaxOffset) {
                    return writeErr("DNG metadata payload exceeds the classic TIFF 32-bit limit (4 GiB)");
                }
                ifd.extraOffsets[i] = static_cast<uint32_t>(extraCursor);
                extraCursor += ifd.tags[i].payload.size();
            }
        }
    }
    const uint64_t firstStripOffset64 = (extraCursor + 15ULL) & ~static_cast<uint64_t>(15);
    if (firstStripOffset64 > kClassicTIFFMaxOffset ||
        firstStripOffset64 + totalPixelBytes > kClassicTIFFMaxOffset) {
        return writeErr("Rendered Linear DNG exceeds the classic TIFF 32-bit limit (4 GiB); "
                        "BigTIFF is not implemented, reduce the output dimensions");
    }

    if (PendingTag* stripOffsets = findTag(ifds[0].tags, 273)) {
        uint64_t offsetCursor = firstStripOffset64;
        for (uint32_t s = 0; s < numStrips; ++s) {
            if (offsetCursor > kClassicTIFFMaxOffset) {
                return writeErr("DNG strip offset exceeds the classic TIFF 32-bit limit (4 GiB)");
            }
            const uint32_t value = static_cast<uint32_t>(offsetCursor);
            std::memcpy(stripOffsets->payload.data() + static_cast<size_t>(s) * 4, &value, 4);
            offsetCursor += stripByteCounts[s];
        }
    } else {
        return writeErr("Internal DNG writer error: strip offsets tag missing");
    }

    std::vector<uint8_t> header(static_cast<size_t>(firstStripOffset64), 0);
    header[0] = 'I';
    header[1] = 'I';
    const uint16_t magic = 42;
    std::memcpy(header.data() + 2, &magic, 2);
    const uint32_t ifdStart = 8;
    std::memcpy(header.data() + 4, &ifdStart, 4);

    for (auto& ifd : ifds) {
        const uint16_t entryCount = static_cast<uint16_t>(ifd.tags.size());
        const size_t base = static_cast<size_t>(ifd.offset);
        std::memcpy(header.data() + base, &entryCount, 2);
        for (size_t i = 0; i < ifd.tags.size(); ++i) {
            const PendingTag& tag = ifd.tags[i];
            TIFFEntry entry{};
            entry.tag = tag.tag;
            entry.type = tag.type;
            entry.count = tag.count;
            if (tag.payload.size() <= 4) {
                std::memcpy(&entry.valueOrOffset, tag.payload.data(), tag.payload.size());
            } else {
                entry.valueOrOffset = ifd.extraOffsets[i];
                std::memcpy(header.data() + ifd.extraOffsets[i], tag.payload.data(), tag.payload.size());
            }
            std::memcpy(header.data() + base + 2 + i * sizeof(TIFFEntry), &entry, sizeof(TIFFEntry));
        }
        const uint32_t nextIFD = 0;
        std::memcpy(header.data() + base + 2 + ifd.tags.size() * sizeof(TIFFEntry), &nextIFD, 4);
    }

    FILE* fp = std::fopen(outputFilePath, "wb");
    if (!fp) {
        return writeErr("Failed to open output DNG file for writing");
    }
    auto abortWrite = [&](const char* msg) -> bool {
        std::fclose(fp);
        std::remove(outputFilePath);
        return writeErr(msg);
    };

    if (std::fwrite(header.data(), 1, header.size(), fp) != header.size()) {
        return abortWrite("Failed to write DNG header");
    }

    std::vector<uint16_t> stripBuffer;
    try {
        stripBuffer.resize(static_cast<size_t>(W) * rowsPerStrip * 3);
    } catch (const std::bad_alloc&) {
        return abortWrite("Unable to allocate the DNG strip buffer");
    }

    for (uint32_t s = 0; s < numStrips; ++s) {
        const uint32_t startRow = s * rowsPerStrip;
        const uint32_t rowCount = std::min(rowsPerStrip, H - startRow);
        if (!stripCallback(userContext, startRow, rowCount, stripBuffer.data())) {
            return abortWrite("DNG strip callback returned false");
        }
        const size_t bytesToWrite = static_cast<size_t>(rowCount) * W * 3 * sizeof(uint16_t);
        if (std::fwrite(stripBuffer.data(), 1, bytesToWrite, fp) != bytesToWrite) {
            return abortWrite("Failed to write DNG strip payload");
        }
    }

    if (std::fflush(fp) != 0) {
        return abortWrite("Failed to flush DNG output");
    }
    if (std::fclose(fp) != 0) {
        std::remove(outputFilePath);
        return writeErr("Failed to close DNG output");
    }
    return true;
}
