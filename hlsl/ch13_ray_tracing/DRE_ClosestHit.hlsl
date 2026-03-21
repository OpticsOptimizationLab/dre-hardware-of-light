/**
 * DRE_ClosestHit.hlsl
 * DRE Vol. 2 — Chapter 13.5: ClosestHit Material Bridge
 *
 * Closest-hit shader. Reads geometry attributes, evaluates
 * EvaluateCookTorrance(), and returns radiance + next bounce direction.
 *
 * Payload layout must match RayPayload in DRE_RayGen.hlsl.
 */

#include "DRE_Vol1_Complete.hlsl"

// G-Buffer SRVs
Texture2D<float4>  g_AlbedoMap    : register(t1);
Texture2D<float4>  g_NormalMap    : register(t2);
Texture2D<float2>  g_RoughnessMap : register(t3);  // x=roughness, y=metalness
SamplerState       g_LinearSampler : register(s0);

struct RayPayload
{
    float3 radiance;
    float3 throughput;
    float3 nextOrigin;
    float3 nextDir;
    uint   bounceDepth;
    uint   seed;
    bool   terminated;
};

struct Attributes { float2 bary; };

[shader("closesthit")]
void ClosestHit(inout RayPayload payload, in Attributes attr)
{
    if (payload.terminated) return;

    // Reconstruct hit geometry
    float3 hitPos    = WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
    float3 N         = GetInterpolatedNormal(PrimitiveIndex(), attr.bary);  // custom helper
    float2 uv        = GetInterpolatedUV(PrimitiveIndex(), attr.bary);

    // Sample material maps
    float3 albedo    = g_AlbedoMap.SampleLevel(g_LinearSampler, uv, 0).rgb;
    float  roughness = g_RoughnessMap.SampleLevel(g_LinearSampler, uv, 0).x;
    float  metalness = g_RoughnessMap.SampleLevel(g_LinearSampler, uv, 0).y;

    // Derive F0 from metalness
    float3 F0 = lerp(0.04f.xxx, albedo, metalness);

    float3 V = -WorldRayDirection();

    // Sample next direction via VNDF (from Vol. 1 Ch. 9.2)
    float2 u = float2(Rand(payload.seed), Rand(payload.seed));
    float  alpha = roughness * roughness;
    float3 H = SampleVNDF(V, alpha, alpha, u);
    float3 L = reflect(-V, H);

    // Evaluate BRDF
    float3 brdf = EvaluateCookTorrance(L, V, N, F0, roughness);
    float  NdotL = saturate(dot(N, L));
    float  pdf   = VNDF_PDF(V, H, N, alpha);

    if (pdf > 1e-6f)
        payload.throughput *= brdf * NdotL / pdf;

    // Russian Roulette
    float survivalProb = saturate(max(payload.throughput.r, max(payload.throughput.g, payload.throughput.b)));
    if (!WaveRussianRoulette(survivalProb, Rand(payload.seed), payload.throughput))
    {
        payload.terminated = true;
        return;
    }

    // Offset ray origin to avoid self-intersection (Wächter & Binder 2019)
    payload.nextOrigin = OffsetRayOrigin(hitPos, N);
    payload.nextDir    = L;
    payload.bounceDepth++;
}
