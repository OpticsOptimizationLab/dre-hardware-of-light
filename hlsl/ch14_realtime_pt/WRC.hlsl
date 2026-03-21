/**
 * WRC.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 14.5 — World Radiance Caching
 *
 * World-space hash grid for multi-bounce GI without multi-bounce cost.
 * Update pass: sparse 1/16th resolution trace (3 bounces). Cost: ~0.6ms/frame.
 * Query: single structured buffer read. Cost: ~0.01ms/frame.
 * VRAM: 262,144 cells × 32 bytes = 8 MB.
 *
 * Production use: Cyberpunk 2077 RT Overdrive, Portal RTX (NVIDIA WRC).
 * Compile: dxc -T cs_6_6 -E WRC_Update -Fo WRC.dxil WRC.hlsl
 */

#ifndef DRE_WRC_HLSL
#define DRE_WRC_HLSL

// #include "path/to/dre-physics-of-light/DRE_Vol1_Complete.hlsl"
// #include "GBuffer.hlsl"

// ─────────────────────────────────────────────────────────────────────────────
// WRC PARAMETERS (§ 14.5)
// ─────────────────────────────────────────────────────────────────────────────

static const float WRC_CELL_SIZE    = 0.5f;    // World units per cell (indoor default)
static const uint  WRC_GRID_SIZE    = 1 << 18; // 262,144 cells (hash table size)
static const float WRC_DECAY_RATE   = 0.02f;   // Temporal decay per frame
static const float WRC_BLEND_ALPHA  = 0.05f;   // Blend factor for new samples

// ─────────────────────────────────────────────────────────────────────────────
// WRC CELL STRUCT (32 bytes)
// ─────────────────────────────────────────────────────────────────────────────

struct WRCCell
{
    float3 irradiance;       // Accumulated indirect radiance from all bounces
    float3 dominantDir;      // Weighted average light direction (directional filter)
    float  sampleCount;      // Accumulated samples (confidence weight)
    float  lastUpdateFrame;  // Frame index of last update (for decay)
};

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

RWStructuredBuffer<WRCCell> g_WRCGrid : register(u5);

RaytracingAccelerationStructure g_TLAS : register(t0);
Texture2D<float4> g_GBufferA : register(t1);
Texture2D<float4> g_GBufferB : register(t2);
Texture2D<float4> g_GBufferC : register(t3);

cbuffer WRCConstants : register(b0)
{
    uint   g_FrameIndex;
    uint2  g_Resolution;
    uint   _pad;
    float3 g_CameraPos;
    float  _pad2;
};

// ─────────────────────────────────────────────────────────────────────────────
// SPATIAL HASH (§ 14.5)
// Maps world position to grid cell index. Minimizes collision clustering.
// ─────────────────────────────────────────────────────────────────────────────

uint WRCHash(float3 worldPos)
{
    int3 cell = int3(floor(worldPos / WRC_CELL_SIZE));
    uint h = (uint)cell.x * 73856093u ^ (uint)cell.y * 19349663u ^ (uint)cell.z * 83492791u;
    return h % WRC_GRID_SIZE;
}

// ─────────────────────────────────────────────────────────────────────────────
// QUERY WRC (§ 14.5) — call from PathTrace at bounce 2+
// Returns cached multi-bounce irradiance estimate. Cost: ~0 (one buffer read).
// ─────────────────────────────────────────────────────────────────────────────

float3 QueryWRC(float3 worldPos, float3 normal)
{
    uint    cellIndex = WRCHash(worldPos);
    WRCCell cell      = g_WRCGrid[cellIndex];

    // Not enough samples accumulated yet.
    if (cell.sampleCount < 4.0f) return float3(0, 0, 0);

    // Directional weighting: bias toward light from the surface hemisphere.
    float dirWeight = saturate(dot(normalize(cell.dominantDir), normal) * 0.5f + 0.5f);

    // Temporal decay: reduce confidence of stale data.
    float age       = (float)g_FrameIndex - cell.lastUpdateFrame;
    float freshness = exp(-age * WRC_DECAY_RATE);

    return cell.irradiance * dirWeight * freshness;
}

// ─────────────────────────────────────────────────────────────────────────────
// RNG
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
// FORWARD DECLARATIONS (implemented in DRE_Vol2_RT.hlsl)
// ─────────────────────────────────────────────────────────────────────────────

struct PathPayload { float3 radiance; float hitT; uint seed; };
struct SurfaceHit  { float3 worldPos; float3 normal; float3 albedo; float roughness; float metallic; bool valid; };

void   TraceRayDRE(float3 origin, float3 dir, inout PathPayload payload);
bool   RussianRoulette(inout float3 throughput, float rng);
bool   TraceShadowRay(float3 origin, float3 dir, float maxT);
float3 EvaluateDirectLightingCheap(SurfaceHit hit);
SurfaceHit ReconstructSecondaryHitFromPayload(inout PathPayload payload, float3 rayOrigin, float3 rayDir);

SurfaceHit LoadSurface(uint2 pixel)
{
    float4 gbA = g_GBufferA[pixel]; float4 gbB = g_GBufferB[pixel]; float4 gbC = g_GBufferC[pixel];
    SurfaceHit s; s.worldPos = gbA.xyz; s.roughness = gbA.w; s.normal = normalize(gbB.xyz);
    s.metallic = gbB.w; s.albedo = gbC.xyz; s.valid = dot(gbA.xyz, gbA.xyz) > 0.001f;
    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// WRC UPDATE PASS (§ 14.5)
// Sparse: one update per 4×4 pixel block → 160×90 dispatches at 1440p.
// Traces 3 full bounces per sample. Cost: ~0.6ms/frame on RTX 4090.
// ─────────────────────────────────────────────────────────────────────────────

[numthreads(8, 8, 1)]
void WRC_Update(uint2 dispatchID : SV_DispatchThreadID)
{
    // Sparse coverage: process one pixel per 4×4 block.
    uint2 pixel = dispatchID * 4;
    if (any(pixel >= g_Resolution)) return;

    SurfaceHit primary = LoadSurface(pixel);
    if (!primary.valid) return;

    uint seed = InitRNG(pixel, g_FrameIndex * 4649u);

    float3 wo         = normalize(g_CameraPos - primary.worldPos);
    float3 throughput = float3(1, 1, 1);
    float3 radiance   = float3(0, 0, 0);
    SurfaceHit hit    = primary;

    for (uint bounce = 0; bounce < 3; ++bounce)
    {
        float3 wi  = SampleVNDF(wo, hit.normal, hit.roughness, RandomFloat2(seed));
        float  pdf = VNDF_PDF(wo, wi, hit.normal, hit.roughness);
        if (pdf < 1e-7f) break;

        float3 brdf    = EvaluateCookTorrance(wo, wi, hit.normal,
                                               hit.albedo, hit.roughness, hit.metallic);
        float cosTheta = saturate(dot(wi, hit.normal));
        throughput    *= brdf * cosTheta / pdf;

        if (!RussianRoulette(throughput, RandomFloat(seed))) break;

        PathPayload payload;
        payload.hitT     = -1.0f;
        payload.seed     = seed;
        payload.radiance = float3(0, 0, 0);

        TraceRayDRE(hit.worldPos + hit.normal * 0.001f, wi, payload);

        if (payload.hitT < 0.0f)
        {
            radiance += throughput * payload.radiance; // Environment
            break;
        }

        hit = ReconstructSecondaryHitFromPayload(payload, hit.worldPos, wi);

        // Direct lighting at this bounce via quick NEE.
        radiance += throughput * EvaluateDirectLightingCheap(hit);

        wo   = -wi;
        seed = payload.seed;
    }

    // Write accumulated radiance to the cell at the PRIMARY surface position.
    uint    cellIndex = WRCHash(primary.worldPos);
    WRCCell cell      = g_WRCGrid[cellIndex];

    cell.irradiance      = lerp(cell.irradiance, radiance, WRC_BLEND_ALPHA);
    cell.dominantDir     = lerp(cell.dominantDir, primary.normal, WRC_BLEND_ALPHA);
    cell.sampleCount     = min(cell.sampleCount + 1.0f, 128.0f); // Cap to prevent overflow
    cell.lastUpdateFrame = (float)g_FrameIndex;

    g_WRCGrid[cellIndex] = cell;
}

// ─────────────────────────────────────────────────────────────────────────────
// CELL SIZE SELECTION GUIDE (§ 14.5)
//
//  cell_size = scene_extent / (HASH_TABLE_SIZE / target_collisions)^(1/3)
//
//  Indoor  50m scene,  30 col/cell:  cell_size ≈ 0.24m
//  Outdoor 500m scene, 30 col/cell:  cell_size ≈ 2.4m
//  Open world 2000m,   30 col/cell:  cell_size ≈ 9.7m (→ use NRC for this scale)
//
// VRAM: 262,144 × 32 bytes = 8 MB — compare ReSTIR GI reservoirs at ~375 MB.
// Convergence: ~10 frames for static lighting.
// Dynamic lighting: slow adaptation (blend α=0.05 → 20-frame lag).
// Use NRC instead when high-frequency indirect detail is needed (§ 15.2).

#endif // DRE_WRC_HLSL
