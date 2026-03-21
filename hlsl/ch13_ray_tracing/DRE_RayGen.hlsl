/**
 * DRE_RayGen.hlsl
 * DRE Vol. 2 — Chapter 13.5: PathTrace() Integration
 *
 * Ray generation shader. Dispatches PathTrace() for every pixel.
 * This is the DXR shader that makes Vol. 1 Ch. 7.4.1 execute.
 *
 * Requires:
 *   DRE_Vol1_Complete.hlsl (from dre-physics-of-light repo)
 *   DRE_TLAS bound as SRV at t0
 *   g_OutputUAV bound as UAV at u0
 */

#include "DRE_Vol1_Complete.hlsl"

RaytracingAccelerationStructure g_TLAS        : register(t0);
RWTexture2D<float4>              g_OutputUAV   : register(u0);

cbuffer FrameConstants : register(b0)
{
    float4x4 g_InvViewProj;
    float3   g_CameraPos;
    uint     g_FrameIndex;
    uint     g_SamplesPerPixel;
    uint     g_MaxBounces;
    float2   _pad;
};

[shader("raygeneration")]
void RayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim   = DispatchRaysDimensions().xy;

    // Reconstruct world-space ray from pixel position
    float2 uv  = (launchIndex + 0.5f) / float2(launchDim);
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y      = -ndc.y;

    float4 worldTarget = mul(g_InvViewProj, float4(ndc, 1.0f, 1.0f));
    worldTarget.xyz   /= worldTarget.w;

    float3 rayOrigin = g_CameraPos;
    float3 rayDir    = normalize(worldTarget.xyz - rayOrigin);

    // Initialize per-pixel RNG (PCG hash of pixel + frame)
    uint seed = launchIndex.x + launchIndex.y * launchDim.x + g_FrameIndex * launchDim.x * launchDim.y;

    // Accumulate samples
    float3 radiance = 0.0f;
    for (uint s = 0; s < g_SamplesPerPixel; ++s)
    {
        radiance += PathTrace(g_TLAS, rayOrigin, rayDir, g_MaxBounces, seed + s);
    }
    radiance /= (float)g_SamplesPerPixel;

    // Temporal blend with previous frame
    float3 prev = g_OutputUAV[launchIndex].rgb;
    float  alpha = (g_FrameIndex == 0) ? 1.0f : 0.05f;  // α=0.05 = 95% history
    g_OutputUAV[launchIndex] = float4(lerp(prev, radiance, alpha), 1.0f);
}
