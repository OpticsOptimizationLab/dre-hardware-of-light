/**
 * Transparency.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 14.7 — Transparency and Refractive Materials
 *
 * Three transparency strategies:
 *   1. Alpha testing (cutout): AnyHit shader with texture sample
 *   2. Glass/refraction: stochastic Fresnel in PathTrace loop
 *   3. Stochastic transparency: probabilistic accept/reject in AnyHit
 *
 * Glass requires a modified SVGF temporal path (glass mask) to prevent boiling.
 * Compile: dxc -T lib_6_6 -Fo Transparency.dxil Transparency.hlsl
 */

#ifndef DRE_TRANSPARENCY_HLSL
#define DRE_TRANSPARENCY_HLSL

// #include "path/to/dre-physics-of-light/DRE_Vol1_Complete.hlsl"

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

struct Material
{
    float3 baseColor;
    float  roughness;
    float  metallic;
    float  ior;           // 1.0 = opaque, 1.5 = glass, 1.33 = water
    uint   albedoIndex;
    uint   normalIndex;
    uint   roughnessIndex;
    uint   metallicIndex;
    bool   isAlphaTested;
    bool   isGlass;
    float  alphaThreshold; // Default: 0.5
    uint   _pad;
};

StructuredBuffer<Material> g_Materials   : register(t5);
StructuredBuffer<uint3>    g_Indices     : register(t10);
StructuredBuffer<float2>   g_UVs         : register(t11);
SamplerState               g_LinearSamp  : register(s0);

// Glass mask: written by G-Buffer pass, read by SVGF temporal accumulation.
// R8_UNORM: 1.0 = glass/refractive pixel, 0.0 = standard surface.
// One additional G-Buffer RT: ~3.5 MB at 1440p.
RWTexture2D<float> g_GlassMask : register(u3);

struct PathPayload { float3 radiance; float hitT; uint seed; };

float RandomFloat(inout uint seed)
{
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (float)(seed & 0x00FFFFFF) / (float)0x01000000;
}

float2 InterpolateUV(uint primitiveIndex, float2 barycentrics)
{
    uint3 tri = g_Indices[primitiveIndex];
    float2 uv0 = g_UVs[tri.x], uv1 = g_UVs[tri.y], uv2 = g_UVs[tri.z];
    float b1 = barycentrics.x, b2 = barycentrics.y;
    return uv0 * (1.0f - b1 - b2) + uv1 * b1 + uv2 * b2;
}

float Sqr(float x) { return x * x; }

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY 1: ALPHA TEST (cutout transparency) (§ 14.7)
// Foliage, fences, fabric with holes.
// 20–30% cost increase on dense alpha-tested scenes vs fully opaque.
// ─────────────────────────────────────────────────────────────────────────────

[shader("anyhit")]
void AnyHitAlphaTest(inout PathPayload payload,
                     in BuiltInTriangleIntersectionAttributes attrib)
{
    uint     materialID = InstanceID();
    Material mat        = g_Materials[materialID];

    if (!mat.isAlphaTested) return; // Opaque: accept implicitly.

    float2 uv = InterpolateUV(PrimitiveIndex(), attrib.barycentrics);

    Texture2D<float4> albedoTex = ResourceDescriptorHeap[mat.albedoIndex];
    float alpha = albedoTex.SampleLevel(g_LinearSamp, uv, 0).a;

    if (alpha < mat.alphaThreshold)
        IgnoreHit(); // Transparent: continue traversal.
    // else: opaque hit accepted implicitly.
}

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY 3: STOCHASTIC TRANSPARENCY (particles, smoke geometry) (§ 14.7)
// Probabilistic accept/reject: probability = alpha.
// Converges to correct opacity over many samples. Denoiser stabilizes output.
// ─────────────────────────────────────────────────────────────────────────────

[shader("anyhit")]
void AnyHitStochastic(inout PathPayload payload,
                      in BuiltInTriangleIntersectionAttributes attrib)
{
    uint     materialID = InstanceID();
    Material mat        = g_Materials[materialID];

    float2 uv = InterpolateUV(PrimitiveIndex(), attrib.barycentrics);

    Texture2D<float4> albedoTex = ResourceDescriptorHeap[mat.albedoIndex];
    float alpha = albedoTex.SampleLevel(g_LinearSamp, uv, 0).a;

    // Stochastic accept: probability = alpha.
    // At alpha=0.3: 30% of rays treat as opaque, 70% pass through.
    float rng = RandomFloat(payload.seed);
    if (rng > alpha)
        IgnoreHit(); // Transparent: continue traversal.
    // else: accepted as opaque hit. Mean opacity converges to alpha over many samples.
}

// ─────────────────────────────────────────────────────────────────────────────
// STRATEGY 2: GLASS / REFRACTIVE MATERIALS (§ 14.7)
// Call from PathTrace loop when material.isGlass == true.
// Stochastic Fresnel: one direction per sample, denoised over frames.
// ─────────────────────────────────────────────────────────────────────────────

// Returns: new ray direction (reflected or refracted). Updates throughput and ray.
float3 EvaluateGlass(
    float3 wo,            // Outgoing direction (toward camera)
    float3 hitNormal,     // World-space geometric normal
    float  ior,           // Index of refraction (glass: 1.5, water: 1.33)
    float3 tint,          // Glass tint (float3(1,1,1) = clear, float3(0.95,1,0.95) = green)
    inout float3 throughput,
    inout uint seed)
{
    // Determine entering or exiting the medium.
    bool entering = dot(wo, hitNormal) > 0.0f;
    float eta     = entering ? (1.0f / ior) : ior;
    float3 n      = entering ? hitNormal : -hitNormal;

    // Fresnel (Schlick approximation for dielectrics).
    float cosTheta = abs(dot(wo, n));
    float F0       = Sqr((1.0f - ior) / (1.0f + ior));
    float F        = F0 + (1.0f - F0) * pow(1.0f - cosTheta, 5.0f);

    // Stochastic Fresnel: randomly choose reflect or refract.
    float3 wi;
    float rng = RandomFloat(seed);

    if (rng < F)
    {
        // Reflect.
        wi = reflect(-wo, n);
    }
    else
    {
        // Refract (Snell's law).
        wi = refract(-wo, n, eta);

        // Total internal reflection check: refract() returns ~0 at critical angle.
        if (dot(wi, wi) < 0.001f)
            wi = reflect(-wo, n); // TIR: force reflection.
    }

    // Glass attenuates by tint (absorption). No division by F or (1-F):
    // the stochastic choice already accounts for the probability.
    throughput *= tint;

    // IMPORTANT: offset ray origin along the NEW direction (wi), not along normal.
    // Offsetting along normal causes self-intersection when wi points backward.
    return wi; // Caller sets ray.Origin = hitPos + wi * 0.001f
}

// ─────────────────────────────────────────────────────────────────────────────
// GLASS MASK WRITE (G-Buffer pixel shader integration) (§ 14.7)
// Write 1.0 for glass pixels in the G-Buffer pass.
// Required by SVGF temporal accumulation to bypass standard disocclusion detection.
// ─────────────────────────────────────────────────────────────────────────────

void WriteGlassMask(uint2 pixel, float materialIOR)
{
    // IOR != 1.0 → refractive material → glass mask
    float isGlass = (materialIOR != 1.0f) ? 1.0f : 0.0f;
    g_GlassMask[pixel] = isGlass;
}

// ─────────────────────────────────────────────────────────────────────────────
// SVGF TEMPORAL: GLASS-AWARE ALPHA (§ 14.7)
// Standard disocclusion detection misfires on glass (depth changes frame-to-frame
// because reflection depth = infinity, refraction depth = physical surface).
// Glass pixels use higher alpha (less history) to prevent indefinite boiling.
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float> g_GlassMaskSRV : register(t15);

float ComputeTemporalAlpha(uint2 pixel, float2 historyUV,
                           Texture2D<float> historyDepth,
                           Texture2D<float4> historyNormal,
                           Texture2D<float4> currentDepthTex,
                           Texture2D<float4> currentNormalTex)
{
    float glass = g_GlassMaskSRV[pixel];

    if (glass > 0.5f)
    {
        // Glass pixel: use higher alpha (30% current, 70% history).
        // Disable disocclusion detection entirely:
        // glass "disoccludes" every frame due to alternating Fresnel decisions.
        // Stabilizes within 3–7 frames. Without this: permanent boiling.
        return 0.3f;
    }
    else
    {
        // Standard surface: depth + normal disocclusion detection.
        // (full SVGF disocclusion test — simplified here)
        return 0.05f; // Standard blend: 5% current, 95% history
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// COMMON GLASS ARTIFACTS AND FIXES (§ 14.7)
//
//  Black glass:
//    Cause: self-intersection after refraction
//    Fix:   offset ray.Origin along wi (new direction), not along normal
//
//  Glass too bright (energy gain):
//    Cause: throughput divided by F or (1-F)
//    Fix:   remove the division — stochastic choice already accounts for probability
//
//  Fireflies on glass edges:
//    Cause: grazing angle → F≈1, refraction occasionally sampled
//    Fix:   clamp min F to 0.04 (physical F0 for dielectrics)
//
//  TIR black spots inside glass:
//    Cause: refract() returns ~0 vector at critical angle
//    Fix:   check dot(wi,wi) < epsilon → force reflect()
//
//  Glass permanently boiling:
//    Cause: standard SVGF disocclusion detection misfires on alternating Fresnel
//    Fix:   glass mask + modified SVGF alpha (this file, ComputeTemporalAlpha)

#endif // DRE_TRANSPARENCY_HLSL
