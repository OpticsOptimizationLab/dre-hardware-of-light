// DRE_Vol2_RT.hlsl, The ray generation shader.
// This file includes DRE_Vol1_Complete.hlsl from the Volume 1 companion repository.
// All BRDF functions, importance sampling, MIS, and Russian Roulette are inherited.

#include "dre-physics-of-light/DRE_Vol1_Complete.hlsl"

// Constants.
static const uint NUM_RAY_TYPES = 2; // Primary + Shadow.

// Global resources, bound via the global root signature.
RaytracingAccelerationStructure g_TLAS        : register(t0);
RWTexture2D<float4>             g_Output      : register(u0);
Texture2D<float4>               g_GBufferA    : register(t1); // WorldPos.xyz + roughness
Texture2D<float4>               g_GBufferB    : register(t2); // Normal.xyz + metallic
Texture2D<float4>               g_GBufferC    : register(t3); // Albedo.rgb + AO
Texture2D<float2>               g_Velocity    : register(t4); // Motion vectors
StructuredBuffer<Material>      g_Materials   : register(t5);
ConstantBuffer<CameraData>      g_Camera      : register(b0);
ConstantBuffer<FrameData>       g_Frame       : register(b1);

// Per-pixel surface data buffer, written by ClosestHit, read by RayGen.
// This is NOT in the payload. Surface data goes to global memory (§ 13.3.2).
RWStructuredBuffer<SurfaceHit>  g_SurfaceHits : register(u1);

[shader("raygeneration")]
void RayGenShader()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dims  = DispatchRaysDimensions().xy;

    // Initialize per-pixel RNG. Seed from pixel coordinate + frame index.
    uint seed = InitRNG(pixel, g_Frame.frameIndex);

    // Construct primary ray from camera.
    float2 uv = (float2(pixel) + 0.5f) / float2(dims);
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y = -ndc.y; // Flip Y for DX convention.

    float3 origin    = g_Camera.position;
    float3 direction = normalize(
        g_Camera.forward
        + ndc.x * g_Camera.right * g_Camera.tanHalfFovX
        + ndc.y * g_Camera.up    * g_Camera.tanHalfFovY
    );

    // PathTrace() from Volume 1, Chapter 7.4.1.
    // The function is unchanged. TraceRay() and TraceShadowRay()
    // are now resolved, they call the DXR intrinsics below.
    float3 radiance = PathTrace(origin, direction, seed);

    // Write to output UAV.
    g_Output[pixel] = float4(radiance, 1.0f);
}