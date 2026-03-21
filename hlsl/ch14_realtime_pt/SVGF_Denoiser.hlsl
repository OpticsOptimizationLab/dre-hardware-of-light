/**
 * SVGF_Denoiser.hlsl
 * DRE Vol. 2 — Chapter 14.6: Denoising with SVGF
 *
 * Spatiotemporal Variance-Guided Filtering.
 * Reference: Schied et al. 2017 — "Spatiotemporal Variance-Guided Filtering:
 *            Real-Time Reconstruction for Path-Traced Global Illumination"
 *
 * Passes:
 *   1. Temporal accumulation (CS_TemporalAccumulate)
 *   2. Variance estimation  (CS_EstimateVariance)
 *   3. À-trous wavelet filter, 4 iterations (CS_AtrousFilter)
 */

// ─────────────────────────────────────────────────────────────────────────────
// PASS 1: Temporal Accumulation
// Blend current noisy frame with history. α = 0.1 → 90% history weight.
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float4>   g_CurrentColor   : register(t0);
Texture2D<float4>   g_HistoryColor   : register(t1);
Texture2D<float2>   g_MotionVectors  : register(t2);
Texture2D<float>    g_CurrentDepth   : register(t3);
Texture2D<float>    g_HistoryDepth   : register(t4);
RWTexture2D<float4> g_AccumulatedOut : register(u0);
RWTexture2D<float2> g_MomentsOut     : register(u1);  // xy = E[L], E[L²]

cbuffer SVGF_Constants : register(b0)
{
    float g_Alpha;          // Temporal blend factor, typically 0.1
    float g_AlphaMoments;   // Moments blend factor, typically 0.2
    uint  g_FrameIndex;
    float _pad;
};

[numthreads(8, 8, 1)]
void CS_TemporalAccumulate(uint3 tid : SV_DispatchThreadID)
{
    float2 uv     = (tid.xy + 0.5f) / float2(1920, 1080);  // replace with cbuffer dims
    float2 motion = g_MotionVectors[tid.xy];
    float2 prevUV = uv - motion;

    float3 current  = g_CurrentColor[tid.xy].rgb;
    float3 history  = 0.0f;
    bool   valid    = all(prevUV >= 0.0f) && all(prevUV <= 1.0f);

    if (valid)
    {
        float  depthCurr = g_CurrentDepth[tid.xy];
        float2 prevPx    = prevUV * float2(1920, 1080);
        float  depthPrev = g_HistoryDepth[(uint2)prevPx];

        // Depth test: reject if depth mismatch > 10%
        valid = (abs(depthCurr - depthPrev) / max(depthCurr, 1e-4f)) < 0.1f;
    }

    float alpha = valid ? g_Alpha : 1.0f;

    if (valid)
        history = g_HistoryColor[uint2(prevUV * float2(1920, 1080))].rgb;

    float3 accumulated = lerp(history, current, alpha);
    g_AccumulatedOut[tid.xy] = float4(accumulated, 1.0f);

    // Moments: first and second moment for variance estimation
    float2 prevMoments = valid ? g_MomentsOut[uint2(prevUV * float2(1920, 1080))] : 0.0f;
    float  lum         = dot(current, float3(0.2126f, 0.7152f, 0.0722f));
    float2 moments     = float2(lum, lum * lum);
    g_MomentsOut[tid.xy] = lerp(prevMoments, moments, g_AlphaMoments);
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 3: À-Trous Wavelet Filter
// Edge-stopping filter with luminance, normal, and depth weights.
// Run 4 times with stepWidth = 1, 2, 4, 8.
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float4>   g_FilterInput    : register(t5);
Texture2D<float4>   g_GBuffer_Normal : register(t6);  // xyz=world normal
Texture2D<float>    g_GBuffer_Depth  : register(t7);
Texture2D<float>    g_Variance       : register(t8);
RWTexture2D<float4> g_FilterOutput   : register(u2);

cbuffer FilterConstants : register(b1)
{
    uint  g_StepWidth;      // 1, 2, 4, 8 for the 4 iterations
    float g_PhiColor;       // Edge-stop weight for color (typically 10.0)
    float g_PhiNormal;      // Edge-stop weight for normals (typically 128.0)
    float g_PhiDepth;       // Edge-stop weight for depth (typically 1.0)
};

// B-spline kernel weights for 5x5 à-trous
static const float c_kernel[3] = { 3.0f/8.0f, 1.0f/4.0f, 1.0f/16.0f };

[numthreads(8, 8, 1)]
void CS_AtrousFilter(uint3 tid : SV_DispatchThreadID)
{
    float3 centerColor  = g_FilterInput[tid.xy].rgb;
    float3 centerNormal = g_GBuffer_Normal[tid.xy].xyz;
    float  centerDepth  = g_GBuffer_Depth[tid.xy];
    float  centerVar    = g_Variance[tid.xy];
    float  centerLum    = dot(centerColor, float3(0.2126f, 0.7152f, 0.0722f));

    float3 colorSum  = 0.0f;
    float  weightSum = 0.0f;

    [unroll]
    for (int y = -2; y <= 2; ++y)
    {
        [unroll]
        for (int x = -2; x <= 2; ++x)
        {
            int2 samplePos = (int2)tid.xy + int2(x, y) * (int)g_StepWidth;
            float kernelW  = c_kernel[abs(x)] * c_kernel[abs(y)];

            float3 sampleColor  = g_FilterInput[samplePos].rgb;
            float3 sampleNormal = g_GBuffer_Normal[samplePos].xyz;
            float  sampleDepth  = g_GBuffer_Depth[samplePos];
            float  sampleLum    = dot(sampleColor, float3(0.2126f, 0.7152f, 0.0722f));

            // Luminance edge-stop (variance-adaptive)
            float  lumDiff   = abs(centerLum - sampleLum);
            float  wColor    = exp(-lumDiff / (g_PhiColor * sqrt(max(centerVar, 1e-8f)) + 1e-8f));

            // Normal edge-stop
            float  nDot      = saturate(dot(centerNormal, sampleNormal));
            float  wNormal   = pow(max(nDot, 0.0f), g_PhiNormal);

            // Depth edge-stop
            float  depthDiff = abs(centerDepth - sampleDepth) / (abs(centerDepth) + 1e-4f);
            float  wDepth    = exp(-depthDiff * g_PhiDepth);

            float  w = kernelW * wColor * wNormal * wDepth;
            colorSum  += sampleColor * w;
            weightSum += w;
        }
    }

    g_FilterOutput[tid.xy] = float4(colorSum / max(weightSum, 1e-6f), 1.0f);
}
