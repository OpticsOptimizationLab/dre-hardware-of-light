/**
 * GBuffer.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 14.2 — Hybrid RT + Rasterization Pipeline
 *
 * G-Buffer layout constants, SRV declarations, and unpack helpers.
 * Include this in any compute or RT shader that reads from the G-Buffer.
 * Compile: dxc -T cs_6_6 -HV 2021 -Fo GBuffer.cso GBuffer.hlsl
 */

#ifndef DRE_GBUFFER_HLSL
#define DRE_GBUFFER_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// G-BUFFER FORMAT REFERENCE (§ 12.2, 14.2)
//
//  RT0: R16G16B16A16_FLOAT  — xyz=worldPos,  w=roughness       — 28.2 MB at 1440p
//  RT1: R16G16B16A16_FLOAT  — xyz=normal,    w=metallic        — 28.2 MB
//  RT2: R8G8B8A8_UNORM      — xyz=albedo,    w=AO              — 14.1 MB
//  RT3: R16G16_FLOAT        — xy=velocity (pixel space)        — 14.1 MB
//  DS:  D32_FLOAT           — linear depth                     — 14.1 MB
//  Glass mask: R8_UNORM     — 1=glass/refractive pixel         — 3.5 MB
//
//  Total G-Buffer: ~102 MB at 1440p native.
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float4> g_GBufferA : register(t1); // worldPos (xyz) + roughness (w)
Texture2D<float4> g_GBufferB : register(t2); // normal (xyz) + metallic (w)
Texture2D<float4> g_GBufferC : register(t3); // albedo (xyz) + AO (w)
Texture2D<float2> g_Velocity : register(t4); // motion vectors, pixel space

// ─────────────────────────────────────────────────────────────────────────────
// SURFACE HIT: UNPACKED G-BUFFER DATA
// Used by ReSTIR, PathTrace, NRC, and all RT passes.
// ─────────────────────────────────────────────────────────────────────────────

struct SurfaceHit
{
    float3 worldPos;   // World-space surface position
    float3 normal;     // World-space geometric normal (normalized)
    float3 albedo;     // Linear-space albedo RGB
    float  roughness;  // Perceptual roughness [0, 1]
    float  metallic;   // Metallic factor [0, 1]
    float  ao;         // Ambient occlusion [0, 1]
    bool   valid;      // False for sky pixels (no geometry)
};

// ─────────────────────────────────────────────────────────────────────────────
// LOAD PRIMARY SURFACE FROM G-BUFFER
// Call from any compute/RT shader that processes primary visibility.
// ─────────────────────────────────────────────────────────────────────────────

SurfaceHit LoadPrimarySurface(uint2 pixel)
{
    float4 gbA = g_GBufferA[pixel];
    float4 gbB = g_GBufferB[pixel];
    float4 gbC = g_GBufferC[pixel];

    SurfaceHit s;
    s.worldPos  = gbA.xyz;
    s.roughness = gbA.w;
    s.normal    = normalize(gbB.xyz);
    s.metallic  = gbB.w;
    s.albedo    = gbC.xyz;
    s.ao        = gbC.w;
    s.valid     = (dot(gbA.xyz, gbA.xyz) > 0.001f); // Sky pixels have worldPos == 0

    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// GEOMETRY SIMILARITY TEST
// Used by ReSTIR temporal/spatial reuse to reject incompatible neighbors.
// ─────────────────────────────────────────────────────────────────────────────

bool IsGeometrySimilar(SurfaceHit a, SurfaceHit b)
{
    // Depth test: relative depth difference < 10%.
    float depthA = length(a.worldPos);
    float depthB = length(b.worldPos);
    bool  depthSimilar = abs(depthA - depthB) / max(depthA, 0.001f) < 0.1f;

    // Normal test: angle < ~25 degrees (cos(25°) ≈ 0.906).
    bool normalSimilar = dot(a.normal, b.normal) > 0.906f;

    return depthSimilar && normalSimilar;
}

// ─────────────────────────────────────────────────────────────────────────────
// DISOCCLUSION DETECTION (used by SVGF temporal accumulation)
// Returns true if the pixel was newly revealed this frame (no valid history).
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float>  g_HistoryDepth  : register(t6);
Texture2D<float4> g_HistoryNormal : register(t7);

bool IsDisoccluded(uint2 pixel, float2 historyUV)
{
    float depthCurrent = length(g_GBufferA[pixel].xyz);

    // Sample history depth at reprojected UV.
    // Use linear clamp sampler for sub-pixel accuracy.
    float2 res;
    g_HistoryDepth.GetDimensions(res.x, res.y);
    uint2  historyPixel = uint2(historyUV * res);
    float  depthHistory  = g_HistoryDepth[historyPixel];
    float3 normalHistory = g_HistoryNormal[historyPixel].xyz;
    float3 normalCurrent = g_GBufferB[pixel].xyz;

    bool depthDiff   = abs(depthCurrent - depthHistory) / max(depthCurrent, 0.001f) > 0.1f;
    bool normalDiff  = dot(normalCurrent, normalHistory) < 0.9f;

    return depthDiff || normalDiff;
}

// ─────────────────────────────────────────────────────────────────────────────
// LUMINANCE HELPER (used by ReSTIR target PDF)
// ─────────────────────────────────────────────────────────────────────────────

float Luminance(float3 rgb)
{
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

#endif // DRE_GBUFFER_HLSL
