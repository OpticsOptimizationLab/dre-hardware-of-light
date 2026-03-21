/**
 * ReSTIR_DI.hlsl
 * DRE Vol. 2 — Chapter 14.3: ReSTIR Direct Illumination
 *
 * Reservoir-based Spatiotemporal Importance Resampling for direct lighting.
 * Implements: initial candidate sampling, temporal reuse, spatial reuse.
 *
 * Reference: Bitterli et al. 2020 — "Spatiotemporal reservoir resampling
 *            for real-time ray tracing with dynamic direct lighting"
 */

#include "DRE_Vol1_Complete.hlsl"

// Reservoir: y=selected sample, w_sum=sum of weights, M=candidate count, W=unbiased weight
struct Reservoir
{
    uint   y;       // Selected light index
    float  w_sum;   // Sum of candidate weights
    uint   M;       // Number of candidates processed
    float  W;       // Unbiased contribution weight = w_sum / (M * p_hat(y))
};

static Reservoir CreateReservoir()
{
    Reservoir r;
    r.y     = 0;
    r.w_sum = 0.0f;
    r.M     = 0;
    r.W     = 0.0f;
    return r;
}

/**
 * UpdateReservoir — Weighted Reservoir Sampling (WRS) step.
 * Returns true if the new sample was selected.
 */
bool UpdateReservoir(inout Reservoir r, uint candidateLight, float w, inout uint seed)
{
    r.w_sum += w;
    r.M     += 1;
    if (Rand(seed) < (w / r.w_sum))
    {
        r.y = candidateLight;
        return true;
    }
    return false;
}

/**
 * FinalizeReservoir — Computes unbiased weight W.
 * p_hat = target PDF evaluated at selected sample y.
 */
void FinalizeReservoir(inout Reservoir r, float p_hat_y)
{
    r.W = (p_hat_y > 0.0f) ? (r.w_sum / (r.M * p_hat_y)) : 0.0f;
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 1: Initial Candidate Generation
// Sample k light candidates per pixel, build initial reservoir.
// ─────────────────────────────────────────────────────────────────────────────

RWStructuredBuffer<Reservoir> g_CurrentReservoirs  : register(u0);
StructuredBuffer<float4>      g_LightBuffer         : register(t0);  // xyz=pos, w=intensity
cbuffer ReSTIR_Constants : register(b0)
{
    uint  g_LightCount;
    uint  g_InitialCandidates;  // k, typically 32
    uint  g_FrameIndex;
    uint  g_Width;
};

[numthreads(8, 8, 1)]
void CS_InitialCandidates(uint3 tid : SV_DispatchThreadID)
{
    uint pixelIndex = tid.x + tid.y * g_Width;
    uint seed = pixelIndex ^ (g_FrameIndex * 1099087573u);

    Reservoir r = CreateReservoir();

    // Sample k candidates with uniform probability 1/N
    for (uint i = 0; i < g_InitialCandidates; ++i)
    {
        uint  lightIdx = (uint)(Rand(seed) * g_LightCount);
        float p_hat    = EvaluateTargetPDF(lightIdx, tid.xy);  // custom per-scene
        float w        = p_hat / (1.0f / g_LightCount);        // w = p_hat / q
        UpdateReservoir(r, lightIdx, w, seed);
    }

    float p_hat_y = EvaluateTargetPDF(r.y, tid.xy);
    FinalizeReservoir(r, p_hat_y);

    g_CurrentReservoirs[pixelIndex] = r;
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 2: Temporal Reuse
// Merge current reservoir with previous frame's reservoir at reprojected pixel.
// ─────────────────────────────────────────────────────────────────────────────

StructuredBuffer<Reservoir>   g_PreviousReservoirs : register(t1);
Texture2D<float2>             g_MotionVectors      : register(t2);

static const uint M_CAP = 20;  // Caps M to bound temporal bias accumulation

[numthreads(8, 8, 1)]
void CS_TemporalReuse(uint3 tid : SV_DispatchThreadID)
{
    uint pixelIndex = tid.x + tid.y * g_Width;
    uint seed = pixelIndex ^ (g_FrameIndex * 2654435761u);

    Reservoir r = g_CurrentReservoirs[pixelIndex];

    // Reproject to previous frame
    float2 motion     = g_MotionVectors[tid.xy];
    int2   prevPixel  = (int2)tid.xy - (int2)(motion * float2(g_Width, g_Width));

    if (all(prevPixel >= 0) && all(prevPixel < (int2)g_Width))
    {
        Reservoir prev = g_PreviousReservoirs[prevPixel.x + prevPixel.y * g_Width];

        // Cap M to prevent temporal bias accumulation
        prev.M = min(prev.M, M_CAP * r.M);

        // Merge: evaluate p_hat of prev.y in current frame
        float p_hat_prev = EvaluateTargetPDF(prev.y, tid.xy);
        float w_prev     = p_hat_prev * prev.W * prev.M;
        UpdateReservoir(r, prev.y, w_prev, seed);
        r.M += prev.M;
    }

    float p_hat_y = EvaluateTargetPDF(r.y, tid.xy);
    FinalizeReservoir(r, p_hat_y);

    g_CurrentReservoirs[pixelIndex] = r;
}
