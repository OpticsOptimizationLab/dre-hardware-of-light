/**
 * CoalescingTest.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 11.3 — Memory Coalescing and Cache Hierarchy
 *
 * Demonstrates the cache line contract: coalesced vs strided access patterns.
 * Use to benchmark memory bandwidth efficiency.
 * Compile: dxc -T cs_6_6 -E CS_CoalescedRead -Fo CoalescingTest.dxil CoalescingTest.hlsl
 */

#ifndef DRE_COALESCING_TEST_HLSL
#define DRE_COALESCING_TEST_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// RT VERTEX FORMAT (§ 11.3)
// Compact layout: only what ClosestHit needs. Position omitted (use DXR intrinsics).
// ─────────────────────────────────────────────────────────────────────────────

struct RTVertex
{
    float3 normal;   // 12 bytes
    float2 uv;       // 8  bytes
    float4 tangent;  // 16 bytes
};                   // 36 bytes (vs 52 for RasterVertex — 30% saving)

struct RasterVertex
{
    float3 position; // 12 bytes
    float3 normal;   // 12 bytes
    float2 uv;       // 8  bytes
    float4 tangent;  // 16 bytes (16 bytes: xyz + sign)
};                   // 52 bytes

// ─────────────────────────────────────────────────────────────────────────────
// SHARED MEMORY FOR SVGF TILE ACCUMULATION (§ 11.3)
// Reduces global reads 4× for 2×2 quad operations.
// ─────────────────────────────────────────────────────────────────────────────

groupshared float4 s_Radiance[8][8];

[numthreads(8, 8, 1)]
void CS_SharedMemDemo(
    uint2 pixel   : SV_DispatchThreadID,
    uint2 localID : SV_GroupThreadID,
    Texture2D<float4> g_InputRadiance : register(t0),
    RWTexture2D<float4> g_Output      : register(u0))
{
    // Each thread loads its pixel into shared memory.
    s_Radiance[localID.y][localID.x] = g_InputRadiance[pixel];
    GroupMemoryBarrierWithGroupSync(); // Ensure all threads have loaded.

    // Read neighbor without a global memory transaction.
    float4 self     = s_Radiance[localID.y][localID.x];
    float4 neighbor = (localID.x < 7)
                    ? s_Radiance[localID.y][localID.x + 1]
                    : self; // Clamp at border.

    g_Output[pixel] = (self + neighbor) * 0.5f;
}

// ─────────────────────────────────────────────────────────────────────────────
// COALESCED G-BUFFER READ (optimal: 2 transactions per warp of 32)
// ─────────────────────────────────────────────────────────────────────────────

cbuffer CoalescingConstants : register(b0)
{
    uint2 g_Resolution;
    uint  _pad0, _pad1;
};

Texture2D<float4>   g_GBufferA   : register(t0); // R16G16B16A16_FLOAT, worldPos + roughness
RWTexture2D<float4> g_OutputTest : register(u0);

[numthreads(8, 8, 1)]
void CS_CoalescedRead(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    // Each thread reads adjacent pixel — COALESCED.
    // Thread 0→pixel(0,0), Thread 1→pixel(1,0) … perfect cache line coverage.
    float4 gbufferA = g_GBufferA[pixel];
    float3 worldPos = gbufferA.xyz;
    float  roughness = gbufferA.w;

    // Write result (trivial, just to exercise the read).
    g_OutputTest[pixel] = float4(worldPos, roughness);
}

// ─────────────────────────────────────────────────────────────────────────────
// CACHE HIERARCHY REFERENCE (§ 11.3)
// ─────────────────────────────────────────────────────────────────────────────

/*
  Cache         | Size (Ampere)                 | Latency  | Contents
  --------------|-------------------------------|----------|--------------------------------
  L1 data       | 32 KB per SM                  | ~20 cyc  | Threadgroup-local data
  L1 texture    | 128 KB per SM                 | ~25 cyc  | Sampled textures, G-Buffer
  Shared memory | 48 KB per SM (up to 100 KB)   | ~20 cyc  | groupshared, inter-thread comm
  L2            | 82 MB (RTX 4090)              | ~200 cyc | All global memory misses
  VRAM          | 24 GB (RTX 4090)              | ~500 cyc | Cold reads, BLAS traversal

  RT path tracer: BLAS traversal + ClosestHit vertex reads = random access = cold VRAM.
  Mitigation: compact RTVertex (36 B vs 52 B), large Ada L2 (82 MB) caches BVH top levels.
*/

#endif // DRE_COALESCING_TEST_HLSL
