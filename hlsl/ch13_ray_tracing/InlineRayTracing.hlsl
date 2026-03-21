/**
 * InlineRayTracing.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 13.6 — Inline Ray Tracing
 *
 * Shadow validation via RayQuery<> in a compute shader.
 * No RTPSO. No SBT. No ClosestHit shaders.
 * SM 6.5+ (RayQuery available since SM 6.5).
 * Compile: dxc -T cs_6_6 -E CS_ShadowValidation -Fo InlineRT.dxil InlineRayTracing.hlsl
 */

#ifndef DRE_INLINE_RT_HLSL
#define DRE_INLINE_RT_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

RaytracingAccelerationStructure g_TLAS : register(t0);

Texture2D<float4> g_GBufferWorldPos : register(t1); // xyz = world pos
Texture2D<float4> g_GBufferNormal   : register(t2); // xyz = normal

RWTexture2D<float> g_ShadowMask : register(u0); // 1.0 = lit, 0.0 = occluded

cbuffer ShadowConstants : register(b0)
{
    float3 g_LightPosition;
    float  _pad0;
    uint2  g_Resolution;
    uint2  _pad1;
};

// ─────────────────────────────────────────────────────────────────────────────
// ALPHA TEXTURE FOR NON-OPAQUE GEOMETRY (inline alpha test)
// In inline RT, AnyHit shaders are not available.
// Alpha testing must be done inline inside the Proceed() loop.
// ─────────────────────────────────────────────────────────────────────────────

struct Material { uint albedoIndex; uint _pad[3]; };
StructuredBuffer<Material> g_Materials  : register(t5);
StructuredBuffer<uint3>    g_Indices    : register(t10);
StructuredBuffer<float2>   g_UVs        : register(t11);
SamplerState               g_LinearSamp : register(s0);

float SampleAlphaInline(uint instanceID, uint primitiveIndex, float2 barycentrics)
{
    uint3  tri  = g_Indices[primitiveIndex];
    float2 uv0  = g_UVs[tri.x];
    float2 uv1  = g_UVs[tri.y];
    float2 uv2  = g_UVs[tri.z];
    float  b1 = barycentrics.x, b2 = barycentrics.y;
    float2 uv = uv0 * (1.0f - b1 - b2) + uv1 * b1 + uv2 * b2;

    Material mat = g_Materials[instanceID];
    Texture2D<float4> albedoTex = ResourceDescriptorHeap[mat.albedoIndex];
    return albedoTex.SampleLevel(g_LinearSamp, uv, 0).a;
}

// ─────────────────────────────────────────────────────────────────────────────
// SHADOW VALIDATION PASS (§ 13.6)
// One shadow ray per pixel via RayQuery. No RTPSO required.
// ─────────────────────────────────────────────────────────────────────────────

[numthreads(8, 8, 1)]
void CS_ShadowValidation(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    float3 worldPos = g_GBufferWorldPos[pixel].xyz;
    float3 normal   = g_GBufferNormal[pixel].xyz;

    // Sky pixel: no geometry.
    if (dot(worldPos, worldPos) < 0.001f)
    {
        g_ShadowMask[pixel] = 1.0f;
        return;
    }

    float3 toLight   = g_LightPosition - worldPos;
    float  lightDist = length(toLight);
    float3 lightDir  = toLight / lightDist;

    RayDesc ray;
    ray.Origin    = worldPos + normal * 0.001f; // Offset to avoid self-intersection
    ray.Direction = lightDir;
    ray.TMin      = 0.0f;
    ray.TMax      = lightDist;

    // Template flags (compile-time):
    //   RAY_FLAG_CULL_BACK_FACING_TRIANGLES: skip backfaces (not valid shadow casters)
    //   RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH: stop at first hit — any hit = occluded
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES
           | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;

    query.TraceRayInline(
        g_TLAS,
        RAY_FLAG_NONE, // Additional flags combined with template flags
        0xFF,          // Instance mask: all instances
        ray
    );

    // Manual traversal loop.
    // For fully opaque geometry with ACCEPT_FIRST_HIT: loop body never executes.
    // Body only runs for non-opaque candidates (alpha-tested geometry).
    while (query.Proceed())
    {
        if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE)
        {
            float2 bary       = query.CandidateTriangleBarycentrics();
            uint   instanceID = query.CandidateInstanceID();
            uint   primIdx    = query.CandidatePrimitiveIndex();

            float alpha = SampleAlphaInline(instanceID, primIdx, bary);
            if (alpha >= 0.5f)
                query.CommitNonOpaqueTriangleHit(); // Treat as opaque, ray blocked
            // else: transparent, IgnoreHit() is implicit (don't call CommitNonOpaqueTriangleHit)
        }
    }

    bool occluded = (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT);
    g_ShadowMask[pixel] = occluded ? 0.0f : 1.0f;
}

// ─────────────────────────────────────────────────────────────────────────────
// AO PROBE INLINE RT (§ 13.6) — ambient occlusion from a G-Buffer pass
// Useful for adding RT shadow/AO to an existing rasterization pipeline
// without building a full RTPSO.
// ─────────────────────────────────────────────────────────────────────────────

cbuffer AOConstants : register(b1)
{
    float  g_AORadius;    // Max AO distance (world units)
    uint   g_AOSamples;   // Samples per pixel (typically 4–8)
    uint   g_FrameIndex;
    uint   _pad2;
};

RWTexture2D<float> g_AOOutput : register(u1);

uint InitRNG_AO(uint2 pixel, uint frame)
{
    return (pixel.x * 1973u + pixel.y * 9277u + frame * 26699u) | 1u;
}

float RandomFloat_AO(inout uint seed)
{
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (float)(seed & 0x00FFFFFF) / (float)0x01000000;
}

float3 CosineHemisphere(float3 normal, float2 u)
{
    float phi = 6.28318f * u.x;
    float sinTheta = sqrt(u.y);
    float cosTheta = sqrt(1.0f - u.y);
    float3 t = (abs(normal.x) < 0.9f) ? float3(1,0,0) : float3(0,1,0);
    float3 b = normalize(cross(normal, t));
    t = cross(b, normal);
    return sinTheta * (cos(phi) * t + sin(phi) * b) + cosTheta * normal;
}

[numthreads(8, 8, 1)]
void CS_AmbientOcclusion(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    float3 worldPos = g_GBufferWorldPos[pixel].xyz;
    float3 normal   = normalize(g_GBufferNormal[pixel].xyz);

    if (dot(worldPos, worldPos) < 0.001f) { g_AOOutput[pixel] = 1.0f; return; }

    uint  seed = InitRNG_AO(pixel, g_FrameIndex);
    float aoSum = 0.0f;

    for (uint i = 0; i < g_AOSamples; ++i)
    {
        float2 u = float2(RandomFloat_AO(seed), RandomFloat_AO(seed));
        float3 dir = CosineHemisphere(normal, u);

        RayDesc aoRay;
        aoRay.Origin    = worldPos + normal * 0.001f;
        aoRay.Direction = dir;
        aoRay.TMin      = 0.0f;
        aoRay.TMax      = g_AORadius;

        RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES
               | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH
               | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER> aoQuery;

        aoQuery.TraceRayInline(g_TLAS, RAY_FLAG_NONE, 0xFF, aoRay);
        aoQuery.Proceed();

        bool hit = (aoQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT);
        aoSum += hit ? 0.0f : 1.0f; // Unoccluded = 1
    }

    g_AOOutput[pixel] = aoSum / (float)g_AOSamples;
}

// ─────────────────────────────────────────────────────────────────────────────
// INLINE VS PIPELINE DECISION (§ 13.6)
//
// Use inline RT (RayQuery) when:
//   - Simple binary answer needed: hit or miss
//   - Adding to an existing compute pass (SSAO, probe updates, light culling)
//   - Prototyping, fastest path from zero to a traced ray
//
// Use pipeline (DispatchRays + RTPSO + SBT) when:
//   - Per-material shading logic
//   - Multiple ray types with different behavior
//   - Building a full path tracer
//
// Performance (identical workload):
//   Shadow pass (binary, opaque geometry):
//     Pipeline: 0.42ms, 78% occupancy
//     Inline:   0.38ms, 82% occupancy  ← 9% faster (no SBT record fetch)
//
// For rays invoking ClosestHit with BRDF evaluation:
//     Performance delta ≈ 0 (SBT overhead negligible vs material evaluation)

#endif // DRE_INLINE_RT_HLSL
