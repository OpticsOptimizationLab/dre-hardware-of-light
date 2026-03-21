/**
 * DRE_Miss.hlsl
 * DRE Vol. 2 — Chapter 13: Miss Shader
 *
 * Returns environment radiance when a ray escapes the scene.
 * Environment map sampled as equirectangular HDR.
 */

Texture2D<float4>   g_EnvMap       : register(t0, space1);
SamplerState        g_LinearSampler : register(s0);

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

static const float PI = 3.14159265358979f;

[shader("miss")]
void Miss(inout RayPayload payload)
{
    float3 dir = WorldRayDirection();

    // Equirectangular UV
    float phi   = atan2(dir.z, dir.x);
    float theta = acos(clamp(dir.y, -1.0f, 1.0f));
    float2 uv   = float2(phi / (2.0f * PI) + 0.5f, theta / PI);

    float3 envRadiance = g_EnvMap.SampleLevel(g_LinearSampler, uv, 0).rgb;

    payload.radiance  += payload.throughput * envRadiance;
    payload.terminated = true;
}

[shader("miss")]
void MissShadow(inout bool isShadowed)
{
    // Shadow ray missed all geometry → not in shadow
    isShadowed = false;
}
