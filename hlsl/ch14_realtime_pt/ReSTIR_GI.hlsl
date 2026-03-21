/**
 * ReSTIR_GI.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 14.4 — ReSTIR GI: Global Illumination
 *
 * One-bounce indirect illumination via spatiotemporal reservoir resampling.
 * Extends ReSTIR DI (§ 14.3) to store secondary hit points instead of light indices.
 * Requires: GBuffer.hlsl, Vol. 1 DRE_Vol1_Complete.hlsl (SampleVNDF, EvaluateCookTorrance)
 * Compile: dxc -T cs_6_6 -E ReSTIR_GI_TraceIndirect -Fo ReSTIR_GI.dxil ReSTIR_GI.hlsl
 */

#ifndef DRE_RESTIR_GI_HLSL
#define DRE_RESTIR_GI_HLSL

// #include "path/to/dre-physics-of-light/DRE_Vol1_Complete.hlsl"
// #include "GBuffer.hlsl"

// ─────────────────────────────────────────────────────────────────────────────
// GI RESERVOIR (§ 14.4) — 52 bytes per pixel
// Stores a secondary hit point (vs DI reservoir which stores a light index).
// ─────────────────────────────────────────────────────────────────────────────

struct GIReservoir
{
    float3 secondaryHitPos;    // 12 bytes — world-space secondary hit position
    float3 secondaryHitNormal; // 12 bytes — normal at secondary hit
    float3 secondaryRadiance;  // 12 bytes — outgoing radiance (direct + WRC)
    float  weightSum;          //  4 bytes
    float  W;                  //  4 bytes — unbiased contribution weight
    uint   M;                  //  4 bytes — candidate count (M-cap: 20×current.M)
};                             // Total: ~52 bytes

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

RaytracingAccelerationStructure g_TLAS : register(t0);

Texture2D<float4> g_GBufferA : register(t1);
Texture2D<float4> g_GBufferB : register(t2);
Texture2D<float4> g_GBufferC : register(t3);
Texture2D<float2> g_Velocity : register(t4);

RWStructuredBuffer<GIReservoir> g_GIReservoirs_Current  : register(u0);
RWStructuredBuffer<GIReservoir> g_GIReservoirs_History  : register(u1);
RWStructuredBuffer<GIReservoir> g_GIReservoirs_Final    : register(u2);

cbuffer FrameConstants : register(b0)
{
    uint   g_FrameIndex;
    uint2  g_Resolution;
    uint   _pad;
    float3 g_CameraPos;
    float  _pad2;
};

static const uint  RESTIR_GI_M_CAP              = 20;
static const uint  RESTIR_GI_SPATIAL_NEIGHBORS  = 4;
static const float RESTIR_GI_SPATIAL_RADIUS     = 25.0f; // pixels

// ─────────────────────────────────────────────────────────────────────────────
// RNG (deterministic, reproducible)
// ─────────────────────────────────────────────────────────────────────────────

uint InitRNG(uint2 pixel, uint frame)
{
    return (pixel.x * 1973u + pixel.y * 9277u + frame * 26699u) | 1u;
}

float RandomFloat(inout uint seed)
{
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (float)(seed & 0x00FFFFFF) / (float)0x01000000;
}

float2 RandomFloat2(inout uint seed)
{
    return float2(RandomFloat(seed), RandomFloat(seed));
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

uint PixelIndex(uint2 pixel)
{
    return pixel.y * g_Resolution.x + pixel.x;
}

float Luminance(float3 rgb)
{
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

void StoreEmptyReservoir(uint2 pixel)
{
    GIReservoir r = (GIReservoir)0;
    g_GIReservoirs_Current[PixelIndex(pixel)] = r;
}

bool IsInsideScreen(float2 uv)
{
    return all(uv >= 0.0f) && all(uv < 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 1: TRACE ONE INDIRECT BOUNCE (§ 14.4)
// ─────────────────────────────────────────────────────────────────────────────

struct PathPayload
{
    float3 radiance;
    float  hitT;
    uint   seed;
};

struct SurfaceHit
{
    float3 worldPos;
    float3 normal;
    float3 albedo;
    float  roughness;
    float  metallic;
    bool   valid;
};

SurfaceHit LoadPrimary(uint2 pixel)
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
    s.valid     = dot(gbA.xyz, gbA.xyz) > 0.001f;
    return s;
}

// Forward declaration: implemented in DRE_Vol2_RT.hlsl
void TraceRayDRE(float3 origin, float3 dir, inout PathPayload payload);
SurfaceHit ReconstructSecondaryHit(uint2 pixel);
float3 EvaluateDirectLightingCheap(SurfaceHit hit);
float3 QueryWRC(float3 worldPos, float3 normal);

[numthreads(8, 8, 1)]
void ReSTIR_GI_TraceIndirect(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    SurfaceHit primary = LoadPrimary(pixel);
    if (!primary.valid) { StoreEmptyReservoir(pixel); return; }

    uint seed = InitRNG(pixel, g_FrameIndex);

    float3 wo = normalize(g_CameraPos - primary.worldPos);

    // Sample indirect direction from VNDF (Vol. 1 § 9.2).
    // SampleVNDF and VNDF_PDF imported from DRE_Vol1_Complete.hlsl.
    float3 wi  = SampleVNDF(wo, primary.normal, primary.roughness, RandomFloat2(seed));
    float  pdf = VNDF_PDF(wo, wi, primary.normal, primary.roughness);

    if (pdf < 1e-7f) { StoreEmptyReservoir(pixel); return; }

    PathPayload payload;
    payload.hitT    = -1.0f;
    payload.seed    = seed;
    payload.radiance = float3(0, 0, 0);

    TraceRayDRE(primary.worldPos + primary.normal * 0.001f, wi, payload);

    GIReservoir r = (GIReservoir)0;

    if (payload.hitT > 0.0f)
    {
        SurfaceHit secondary = ReconstructSecondaryHit(pixel);

        // Direct lighting at secondary hit (using current frame's ReSTIR DI result).
        float3 directAtSecondary = EvaluateDirectLightingCheap(secondary);

        // World Radiance Cache for multi-bounce beyond 1 (§ 14.5).
        float3 indirectAtSecondary = QueryWRC(secondary.worldPos, secondary.normal);

        r.secondaryHitPos    = secondary.worldPos;
        r.secondaryHitNormal = secondary.normal;
        r.secondaryRadiance  = directAtSecondary + indirectAtSecondary;

        // Target PDF: importance of this indirect sample.
        // p̂ = luminance(BRDF × radiance × cosθ)
        float3 brdf = EvaluateCookTorrance(wo, wi, primary.normal,
                                            primary.albedo, primary.roughness, primary.metallic);
        float cosTheta = saturate(dot(wi, primary.normal));
        float pHat = Luminance(brdf * r.secondaryRadiance * cosTheta);

        r.weightSum = (pdf > 1e-7f) ? pHat / pdf : 0.0f;
        r.W = (pHat > 0) ? r.weightSum / pHat : 0.0f;
        r.M = 1;
    }

    g_GIReservoirs_Current[PixelIndex(pixel)] = r;
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 2: TEMPORAL REUSE WITH VISIBILITY VALIDATION (§ 14.4)
// Validation ray is MANDATORY to prevent ghosting (costs ~0.2ms at 1440p).
// ─────────────────────────────────────────────────────────────────────────────

bool TraceShadowRay(float3 origin, float3 dir, float maxT);

[numthreads(8, 8, 1)]
void ReSTIR_GI_Temporal(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    SurfaceHit primary = LoadPrimary(pixel);
    if (!primary.valid) return;

    uint seed = InitRNG(pixel, g_FrameIndex * 7919u);

    GIReservoir current = g_GIReservoirs_Current[PixelIndex(pixel)];

    // Reproject to previous frame.
    float2 velocity   = g_Velocity[pixel];
    float2 prevUV     = ((float2(pixel) + 0.5f) / float2(g_Resolution)) - velocity;
    bool   validHist  = IsInsideScreen(prevUV);

    if (validHist)
    {
        uint2 prevPixel = (uint2)(prevUV * float2(g_Resolution));
        GIReservoir history = g_GIReservoirs_History[PixelIndex(prevPixel)];

        // Geometry similarity test.
        float4 prevGbA = g_GBufferA[prevPixel];
        SurfaceHit prevSurf;
        prevSurf.worldPos = prevGbA.xyz;
        prevSurf.normal   = normalize(g_GBufferB[prevPixel].xyz);
        float relativeDepth = abs(length(primary.worldPos) - length(prevSurf.worldPos))
                            / max(length(primary.worldPos), 0.001f);
        float normalAlign   = dot(primary.normal, prevSurf.normal);
        validHist = (relativeDepth < 0.1f) && (normalAlign > 0.906f);

        if (validHist && history.M > 0)
        {
            // M-cap: limit history age to prevent bias accumulation.
            history.M = min(history.M, RESTIR_GI_M_CAP * current.M);

            // Temporal visibility: is the stored secondary hit still reachable?
            float3 toSecondary = history.secondaryHitPos - primary.worldPos;
            float  dist        = length(toSecondary);

            bool reachable = !TraceShadowRay(
                primary.worldPos + primary.normal * 0.001f,
                toSecondary / max(dist, 0.001f),
                dist * 1.05f);

            if (!reachable)
                history.M = 0; // Stale: secondary hit blocked, discard history

            // Merge reservoirs using MIS weight.
            if (history.M > 0)
            {
                float3 wo = normalize(g_CameraPos - primary.worldPos);
                float3 wi = normalize(history.secondaryHitPos - primary.worldPos);
                float3 brdf = EvaluateCookTorrance(wo, wi, primary.normal,
                                                    primary.albedo, primary.roughness,
                                                    primary.metallic);
                float cosTheta = saturate(dot(wi, primary.normal));
                float pHat = Luminance(brdf * history.secondaryRadiance * cosTheta);

                float mergeWeight = pHat * history.W * (float)history.M;

                current.weightSum += mergeWeight;
                current.M         += history.M;

                if (RandomFloat(seed) < mergeWeight / max(current.weightSum, 1e-7f))
                {
                    current.secondaryHitPos    = history.secondaryHitPos;
                    current.secondaryHitNormal = history.secondaryHitNormal;
                    current.secondaryRadiance  = history.secondaryRadiance;
                }
            }
        }
    }

    // Recompute unbiased contribution weight.
    if (current.M > 0)
    {
        float3 wo = normalize(g_CameraPos - primary.worldPos);
        float3 wi = normalize(current.secondaryHitPos - primary.worldPos);
        float3 brdf = EvaluateCookTorrance(wo, wi, primary.normal,
                                            primary.albedo, primary.roughness, primary.metallic);
        float cosTheta = saturate(dot(wi, primary.normal));
        float pHat = Luminance(brdf * current.secondaryRadiance * cosTheta);
        current.W = (pHat > 0) ? current.weightSum / ((float)current.M * pHat) : 0.0f;
    }

    g_GIReservoirs_Final[PixelIndex(pixel)] = current;
}

// ─────────────────────────────────────────────────────────────────────────────
// COST REFERENCE (§ 14.4) — RTX 4090, 1440p
//
//  Pass 1 (trace 1 indirect bounce):    ~1.1ms
//  Pass 2 (temporal + validation ray):  ~0.37ms
//  Total temporal-only ReSTIR GI:       ~1.47ms
//
//  Optional Pass 3 (spatial reuse, K=4 neighbors):  ~0.6ms additional
//  Total with spatial: ~2.1ms
//
//  Adaptive budget: disable spatial reuse first when frame > 16.6ms.
//  Highest cost-per-quality tradeoff in the pipeline.

#endif // DRE_RESTIR_GI_HLSL
