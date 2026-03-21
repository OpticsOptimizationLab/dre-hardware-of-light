/**
 * BindlessRT.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 12.3 — Descriptor Heaps and Bindless
 *
 * ClosestHit shader demonstrating SM 6.6 bindless texture access via
 * ResourceDescriptorHeap[]. No per-dispatch binding updates needed.
 * Compile: dxc -T lib_6_6 -HV 2021 -Fo BindlessRT.cso BindlessRT.hlsl
 */

#ifndef DRE_BINDLESS_RT_HLSL
#define DRE_BINDLESS_RT_HLSL

// Requires Vol. 1 companion code for BRDF evaluation.
// #include "path/to/dre-physics-of-light/DRE_Vol1_Complete.hlsl"

// ─────────────────────────────────────────────────────────────────────────────
// DESCRIPTOR HEAP SLOT LAYOUT (§ 12.3)
// Must match DREDescriptorSlot enum in C++ and heap fill order.
// ─────────────────────────────────────────────────────────────────────────────

static const uint SLOT_GBUFFER_A       = 0;  // R16G16B16A16: worldPos + roughness
static const uint SLOT_GBUFFER_B       = 1;  // R16G16B16A16: normal + metallic
static const uint SLOT_GBUFFER_C       = 2;  // R8G8B8A8:     albedo + AO
static const uint SLOT_GBUFFER_VEL     = 3;  // R16G16:       velocity (pixel space)
static const uint SLOT_MATERIAL_BUF    = 4;  // StructuredBuffer<Material>
static const uint SLOT_OUTPUT_UAV      = 5;  // RWTexture2D radiance output
static const uint SLOT_DENOISED_UAV    = 6;  // RWTexture2D denoised output
static const uint SLOT_HISTORY_SRV     = 7;  // History radiance (temporal)
static const uint SLOT_RESERVOIR_A     = 8;  // ReSTIR DI reservoir ping
static const uint SLOT_RESERVOIR_B     = 9;  // ReSTIR DI reservoir pong
static const uint SLOT_SURFACE_HITS    = 10; // UAV: SurfaceHit per pixel
static const uint SLOT_TEXTURES_BASE   = 11; // Material textures start here (unbounded)

// ─────────────────────────────────────────────────────────────────────────────
// MATERIAL STRUCT (matches C++ DRE_MaterialDesc)
// ─────────────────────────────────────────────────────────────────────────────

struct Material
{
    float3 baseColor;
    float  roughness;
    float  metallic;
    float  ior;           // 1.0 = opaque, 1.5 = glass
    uint   albedoIndex;   // Bindless heap slot
    uint   normalIndex;
    uint   roughnessIndex;
    uint   metallicIndex;
    bool   isAlphaTested;
    bool   isGlass;
    uint2  _pad;
};

// ─────────────────────────────────────────────────────────────────────────────
// PATH PAYLOAD (§ 13.3 — keep as small as possible)
// ─────────────────────────────────────────────────────────────────────────────

struct PathPayload
{
    float3 radiance;   // 12 bytes
    float  hitT;       //  4 bytes
    uint   seed;       //  4 bytes
};                     // Total: 20 bytes — conservative, preserves occupancy

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCE DECLARATIONS
// ─────────────────────────────────────────────────────────────────────────────

RaytracingAccelerationStructure g_TLAS     : register(t0);
StructuredBuffer<Material>      g_Materials: register(t5);

SamplerState g_LinearSampler : register(s0);

cbuffer CameraConstants : register(b0)
{
    float3 g_CameraPos;
    float  _pad0;
    float4x4 g_ViewProj;
    uint   g_FrameIndex;
    uint3  _pad1;
};

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: UV interpolation from barycentric coordinates
// ─────────────────────────────────────────────────────────────────────────────

// Vertex UV buffer — one per BLAS mesh, accessed via InstanceID indexing.
// In production, use a StructuredBuffer array indexed by InstanceID.
// Simplified here: single UV buffer for demo purposes.
StructuredBuffer<float2> g_UVs    : register(t10);
StructuredBuffer<uint3>  g_Indices: register(t11);

float2 InterpolateUV(uint primitiveIndex, float2 barycentrics)
{
    uint3 tri = g_Indices[primitiveIndex];
    float2 uv0 = g_UVs[tri.x];
    float2 uv1 = g_UVs[tri.y];
    float2 uv2 = g_UVs[tri.z];
    float2 bary = barycentrics;
    return uv0 * (1.0f - bary.x - bary.y) + uv1 * bary.x + uv2 * bary.y;
}

// ─────────────────────────────────────────────────────────────────────────────
// CLOSEST HIT SHADER: BINDLESS MATERIAL EVALUATION
// ─────────────────────────────────────────────────────────────────────────────

[shader("closesthit")]
void ClosestHitShader(inout PathPayload payload,
                      in BuiltInTriangleIntersectionAttributes attrib)
{
    uint materialID = InstanceID();
    Material mat = g_Materials[materialID];

    float2 uv = InterpolateUV(PrimitiveIndex(), attrib.barycentrics);

    // SM 6.6 bindless: index into the heap directly by slot number.
    // No per-dispatch binding change. No root signature update.
    Texture2D<float4> albedoTex    = ResourceDescriptorHeap[mat.albedoIndex];
    Texture2D<float4> roughnessTex = ResourceDescriptorHeap[mat.roughnessIndex];
    Texture2D<float4> normalTex    = ResourceDescriptorHeap[mat.normalIndex];

    float4 albedo    = albedoTex.SampleLevel(g_LinearSampler, uv, 0);
    float  roughness = roughnessTex.SampleLevel(g_LinearSampler, uv, 0).g;
    float3 tsNormal  = normalTex.SampleLevel(g_LinearSampler, uv, 0).xyz * 2.0f - 1.0f;

    // Alpha test.
    if (mat.isAlphaTested && albedo.a < 0.5f)
    {
        IgnoreHit();
        return;
    }

    // Transform normal from tangent-space to world-space.
    // ObjectToWorld3x4() provides the instance-to-world matrix.
    float3 worldNormal = normalize(mul(tsNormal, (float3x3)ObjectToWorld3x4()));

    // Hit world position.
    float3 worldPos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();

    // Store hit distance in payload for PathTrace loop control.
    payload.hitT = RayTCurrent();

    // Minimal shading: store albedo as radiance (full BRDF from Vol. 1 PathTrace).
    payload.radiance = albedo.rgb;
}

// ─────────────────────────────────────────────────────────────────────────────
// REQUIREMENTS FOR BINDLESS (§ 12.3)
// ─────────────────────────────────────────────────────────────────────────────
//
//  1. Heap must be SHADER_VISIBLE (D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE).
//  2. Range declared with DESCRIPTORS_VOLATILE | DATA_VOLATILE flags.
//  3. DXC: -HV 2021 or SM 6.6 target. ResourceDescriptorHeap is a SM 6.6 feature.
//  4. Agility SDK 1.600.10+ for SM 6.6 on Windows 10.
//
// ADDING A NEW MATERIAL (zero infrastructure change):
//  1. Load new textures.
//  2. Write SRVs into next available slots in the heap.
//  3. Create Material entry with new slot indices.
//  4. Add TLAS instance with InstanceID pointing to the new material.
//  Done. No root signature changes. No RTPSO rebuild.

#endif // DRE_BINDLESS_RT_HLSL
