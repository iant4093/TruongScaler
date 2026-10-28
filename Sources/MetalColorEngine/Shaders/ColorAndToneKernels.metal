#include <metal_stdlib>
using namespace metal;

struct TileToneParams {
    uint inputSize;
    uint outputSize;
    uint scaleFactor;
    float alphaConstant;
    float logConstantK;
};

kernel void rgba16f_to_planar_log_rgb(
    device const half4* srcRGBA [[buffer(0)]],
    device half* dstPlanarRGB [[buffer(1)]],
    device half* dstAlpha [[buffer(2)]],
    constant TileToneParams& params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.inputSize || gid.y >= params.inputSize) return;
    uint idx = gid.y * params.inputSize + gid.x;
    uint planeSize = params.inputSize * params.inputSize;
    half4 px = srcRGBA[idx];

    float r = clamp(float(px.x), 0.0f, 65500.0f);
    float g = clamp(float(px.y), 0.0f, 65500.0f);
    float b = clamp(float(px.z), 0.0f, 65500.0f);

    float invK = 1.0f / max(params.logConstantK, 1e-6f);
    dstPlanarRGB[0 * planeSize + idx] = half(log(1.0f + params.alphaConstant * r) * invK);
    dstPlanarRGB[1 * planeSize + idx] = half(log(1.0f + params.alphaConstant * g) * invK);
    dstPlanarRGB[2 * planeSize + idx] = half(log(1.0f + params.alphaConstant * b) * invK);
    dstAlpha[idx] = px.w;
}

kernel void planar_log_rgb_to_replicated_y_and_cbcr(
    device const half* srcPlanarRGB [[buffer(0)]],
    device half* dstReplicatedY [[buffer(1)]],
    device float* dstCb [[buffer(2)]],
    device float* dstCr [[buffer(3)]],
    constant TileToneParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.inputSize || gid.y >= params.inputSize) return;
    uint idx = gid.y * params.inputSize + gid.x;
    uint planeSize = params.inputSize * params.inputSize;

    float rn = clamp(float(srcPlanarRGB[0 * planeSize + idx]), 0.0f, 1.0f);
    float gn = clamp(float(srcPlanarRGB[1 * planeSize + idx]), 0.0f, 1.0f);
    float bn = clamp(float(srcPlanarRGB[2 * planeSize + idx]), 0.0f, 1.0f);

    float y  = 0.22897456f * rn + 0.69173852f * gn + 0.07928691f * bn;
    float cb = 0.54305895f * (bn - y);
    float cr = 0.64848699f * (rn - y);

    half yh = half(y);
    dstReplicatedY[0 * planeSize + idx] = yh;
    dstReplicatedY[1 * planeSize + idx] = yh;
    dstReplicatedY[2 * planeSize + idx] = yh;
    dstCb[idx] = cb;
    dstCr[idx] = cr;
}

inline float4 catmullRomWeights(float t) {
    float t2 = t * t;
    float w0 = t * (t * (-0.5f * t + 1.0f) - 0.5f);
    float w1 = t2 * (1.5f * t - 2.5f) + 1.0f;
    float w2 = t * (t * (-1.5f * t + 2.0f) + 0.5f);
    float w3 = t2 * (0.5f * t - 0.5f);
    return float4(w0, w1, w2, w3);
}

inline float stableExpMinusOne(float x) {
    // exp(x) rounds near 1 before subtraction, losing shadow bits. Metal has no expm1;
    // the degree-six series has < 1.1e-10 truncation error on [0, 0.125].
    if (x < 0.125f) {
        return x * (1.0f + x * (0.5f + x * (1.0f / 6.0f + x *
            (1.0f / 24.0f + x * (1.0f / 120.0f + x * (1.0f / 720.0f))))));
    }
    return exp(x) - 1.0f;
}

kernel void reconstruct_upscaled_rgba16f(
    device const half* srcUpscaledY [[buffer(0)]],
    device const float* srcCb [[buffer(1)]],
    device const float* srcCr [[buffer(2)]],
    device const half* srcAlpha [[buffer(3)]],
    device half4* dstUpscaledRGBA [[buffer(4)]],
    constant TileToneParams& params [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputSize || gid.y >= params.outputSize) return;
    uint outIdx = gid.y * params.outputSize + gid.x;
    uint outPlaneSize = params.outputSize * params.outputSize;

    float yUp = (float(srcUpscaledY[0 * outPlaneSize + outIdx]) +
                 float(srcUpscaledY[1 * outPlaneSize + outIdx]) +
                 float(srcUpscaledY[2 * outPlaneSize + outIdx])) * (1.0f / 3.0f);

    float u = (float(gid.x) + 0.5f) / float(params.scaleFactor) - 0.5f;
    float v = (float(gid.y) + 0.5f) / float(params.scaleFactor) - 0.5f;
    int i0 = int(floor(u));
    int j0 = int(floor(v));
    float4 wx = catmullRomWeights(u - float(i0));
    float4 wy = catmullRomWeights(v - float(j0));
    float wvx[4] = {wx.x, wx.y, wx.z, wx.w};
    float wvy[4] = {wy.x, wy.y, wy.z, wy.w};

    float cbUp = 0.0f, crUp = 0.0f, aUp = 0.0f;
    int limit = int(params.inputSize) - 1;
    for (int n = -1; n <= 2; ++n) {
        int sy = clamp(j0 + n, 0, limit);
        float wy_n = wvy[n + 1];
        for (int m = -1; m <= 2; ++m) {
            int sx = clamp(i0 + m, 0, limit);
            float w = wy_n * wvx[m + 1];
            uint sIdx = uint(sy) * params.inputSize + uint(sx);
            cbUp += w * srcCb[sIdx];
            crUp += w * srcCr[sIdx];
            aUp  += w * float(srcAlpha[sIdx]);
        }
    }

    cbUp = clamp(cbUp, -0.55f, 0.55f);
    crUp = clamp(crUp, -0.55f, 0.55f);
    aUp  = clamp(aUp, 0.0f, 1.0f);

    float rn, bn, gn;
    {
        // Match the CPU's separately rounded Float operations. A fused Y + coefficient * Cr
        // changes the near-zero cancellation enough to cross a half-subnormal boundary.
        #pragma METAL fp contract(off)
        rn = clamp(yUp + 1.54205088f * crUp, 0.0f, 1.2f);
        bn = clamp(yUp + 1.84142182f * cbUp, 0.0f, 1.2f);
        // Inverse of the Display P3 forward matrix above:
        //   R = Y + 1.54205088 Cr, B = Y + 1.84142182 Cb,
        //   G = Y - 0.51043918 Cr - 0.21106322 Cb.
        // These green coefficients are the numerically inverted values of the
        // K_R/K_G/K_B luminances and the 0.54305895/0.64848699 chroma scales; they
        // are not independently rounded constants.
        gn = clamp(yUp - 0.51043918f * crUp - 0.21106322f * cbUp, 0.0f, 1.2f);
    }

    float invAlpha = 1.0f / max(params.alphaConstant, 1e-6f);
    float rLin = max(0.0f, stableExpMinusOne(rn * params.logConstantK) * invAlpha);
    float gLin = max(0.0f, stableExpMinusOne(gn * params.logConstantK) * invAlpha);
    float bLin = max(0.0f, stableExpMinusOne(bn * params.logConstantK) * invAlpha);

    dstUpscaledRGBA[outIdx] = half4(half(rLin), half(gLin), half(bLin), half(aUp));
}
