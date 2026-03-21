/**
 * DRE_Vol2_Complete.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * by JM Sage
 *
 * Single-file assembly. Copy into your project and include once.
 * Requires: DRE_Vol1_Complete.hlsl (companion to Vol. 1)
 *           Shader Model 6.6 — compile with: dxc -T cs_6_6 or lib_6_6
 *
 * Contents:
 *   § 1  Wave & Divergence Utilities         (Ch. 11)
 *   § 2  Occupancy Constants                 (Ch. 11)
 *   § 3  Render Graph Resource Declarations  (Ch. 12)
 *   § 4  DXR Ray Tracing Shaders             (Ch. 13)
 *   § 5  ReSTIR DI — Reservoir Sampling      (Ch. 14)
 *   § 6  SVGF Denoising                      (Ch. 14)
 */

#ifndef DRE_VOL2_COMPLETE_HLSL
#define DRE_VOL2_COMPLETE_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// § 1  WAVE & DIVERGENCE UTILITIES  (Ch. 11.1 — The SIMD Contract)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns the divergence factor for the current wave.
 * 0.0 = perfectly converged. > 0.2 = measurable performance problem.
 */
float GetWaveDivergenceFactor()
{
    uint4  ballot      = WaveActiveBallot(true);
    uint   activeLanes = countbits(ballot.x) + countbits(ballot.y)
                       + countbits(ballot.z) + countbits(ballot.w);
    return 1.0f - (float)activeLanes / (float)WaveGetLaneCount();
}

/**
 * Wave-aware Russian Roulette. (Ch. 11.1)
 * Keeps the wave alive as long as any lane survives — avoids premature
 * wave termination that serializes remaining work.
 * Equivalent to Vol. 1 WaveRussianRoulette with hardware explanation.
 */
bool WaveRR(float survivalProb, float rng, inout float3 throughput)
{
    if (survivalProb <= 0.0f) return false;
    bool survive = (rng < survivalProb);
    if (!WaveActiveAnyTrue(survive)) return false;
    if (survive) throughput /= survivalProb;
    return survive;
}

// ─────────────────────────────────────────────────────────────────────────────
// § 2  OCCUPANCY CONSTANTS  (Ch. 11.2 — Register Pressure and Occupancy)
// ─────────────────────────────────────────────────────────────────────────────

static const uint  AMPERE_REGS_PER_SM         = 65536;
static const uint  AMPERE_MAX_THREADS_PER_SM  = 1536;
static const uint  AMPERE_WARP_SIZE           = 32;
static const uint  RDNA3_WAVE_SIZE            = 64;

// Occupancy cliff: PathTrace() kernel reaches ~38-44 regs → 65-80% occupancy on 8x8
// D_GGX: ~8 regs, EvaluateCookTorrance: ~16 regs, PathTrace full: ~38-44 regs

// ─────────────────────────────────────────────────────────────────────────────
// § 3  DXR PAYLOAD  (Ch. 13 — Hardware Ray Tracing Sovereignty)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_RayPayload
{
    float3 radiance;
    float3 throughput;
    float3 nextOrigin;
    float3 nextDir;
    uint   bounceDepth;
    uint   seed;
    bool   terminated;
};

struct DRE_ShadowPayload
{
    bool isShadowed;
};

// ─────────────────────────────────────────────────────────────────────────────
// § 4  RESAMPLING UTILITIES  (Ch. 14.3 — ReSTIR DI)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_Reservoir
{
    uint   y;       // Selected sample (light index)
    float  w_sum;   // Sum of candidate weights
    uint   M;       // Candidate count
    float  W;       // Unbiased contribution weight
};

static DRE_Reservoir DRE_CreateReservoir()
{
    DRE_Reservoir r;
    r.y = 0; r.w_sum = 0.0f; r.M = 0; r.W = 0.0f;
    return r;
}

bool DRE_UpdateReservoir(inout DRE_Reservoir r, uint candidate, float w, inout uint seed)
{
    r.w_sum += w;
    r.M     += 1;
    if (frac(sin((float)(seed++) * 78.233f) * 43758.5f) < (w / r.w_sum))
    {
        r.y = candidate;
        return true;
    }
    return false;
}

void DRE_FinalizeReservoir(inout DRE_Reservoir r, float p_hat_y)
{
    r.W = (p_hat_y > 1e-6f) ? (r.w_sum / ((float)r.M * p_hat_y)) : 0.0f;
}

// ─────────────────────────────────────────────────────────────────────────────
// § 5  SVGF EDGE-STOP WEIGHTS  (Ch. 14.6 — SVGF Denoising)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * SVGF_EdgeWeight — combined edge-stopping function.
 * Used in the à-trous wavelet filter passes.
 *
 * @param centerLum   Luminance at center pixel
 * @param sampleLum   Luminance at sample pixel
 * @param variance    Estimated variance at center pixel
 * @param nDot        dot(centerNormal, sampleNormal)
 * @param depthRatio  |centerDepth - sampleDepth| / |centerDepth|
 */
float SVGF_EdgeWeight(float centerLum, float sampleLum, float variance,
                      float nDot, float depthRatio,
                      float phiColor, float phiNormal, float phiDepth)
{
    float wColor  = exp(-abs(centerLum - sampleLum) / (phiColor * sqrt(max(variance, 1e-8f)) + 1e-8f));
    float wNormal = pow(max(nDot, 0.0f), phiNormal);
    float wDepth  = exp(-depthRatio * phiDepth);
    return wColor * wNormal * wDepth;
}

// B-spline kernel for 5x5 à-trous
static const float DRE_ATROUS_KERNEL[3] = { 3.0f/8.0f, 1.0f/4.0f, 1.0f/16.0f };

#endif // DRE_VOL2_COMPLETE_HLSL
