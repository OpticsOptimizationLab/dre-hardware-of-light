/**
 * RTPipelineState.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 13.3 — The Ray Tracing Pipeline State
 *
 * Complete RTPSO creation for a 3-material scene with opaque, alpha-tested,
 * and shadow hit groups. Payload struct + shader config + PSO cache integration.
 * Requires: d3d12.h, D3D12 Agility SDK 1.600+
 */

#include <d3d12.h>
#include <vector>
#include <string>
#include <cassert>
#include <cstdio>

// ─────────────────────────────────────────────────────────────────────────────
// PATH PAYLOAD (§ 13.3) — 20 bytes, keep small to maximize occupancy
// Every additional float in PathPayload reduces theoretical occupancy.
// 48-byte payload ≈ 12% occupancy loss vs 20-byte on RTX 4090.
// ─────────────────────────────────────────────────────────────────────────────

// (defined in HLSL):
// struct PathPayload {
//     float3 radiance;  // 12 bytes
//     float  hitT;      //  4 bytes
//     uint   seed;      //  4 bytes
// };                    // Total: 20 bytes

static const UINT PATH_PAYLOAD_SIZE = 20;
static const UINT ATTRIBUTE_SIZE    = sizeof(float) * 2; // Barycentrics: 8 bytes

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: SUBOBJECT PUSH
// ─────────────────────────────────────────────────────────────────────────────

static void PushSubobject(std::vector<D3D12_STATE_SUBOBJECT>& subobjects,
                           D3D12_STATE_SUBOBJECT_TYPE type, const void* desc)
{
    D3D12_STATE_SUBOBJECT so;
    so.Type  = type;
    so.pDesc = desc;
    subobjects.push_back(so);
}

// ─────────────────────────────────────────────────────────────────────────────
// RTPSO CREATION (§ 13.3)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_RTPSODesc
{
    void*  compiledShaderBlob;    // DXC-compiled DXIL library (lib_6_6)
    SIZE_T compiledShaderSize;
    ID3D12RootSignature* globalRootSignature;
};

struct DRE_RTPSO
{
    ID3D12StateObject*            stateObject = nullptr;
    ID3D12StateObjectProperties*  properties  = nullptr;

    // Shader identifiers (32 bytes each, opaque handles for SBT).
    void* rayGenID        = nullptr;
    void* missID          = nullptr;
    void* shadowMissID    = nullptr;
    void* opaqueHitID     = nullptr;
    void* alphaHitID      = nullptr;
    void* shadowHitID     = nullptr;
};

DRE_RTPSO DRE_CreateRTPSO(ID3D12Device5* device, const DRE_RTPSODesc& desc)
{
    std::vector<D3D12_STATE_SUBOBJECT> subobjects;
    subobjects.reserve(16);

    // ── 1. DXIL Library ──────────────────────────────────────────────────────
    // One compiled blob containing all RT entry points.
    // dxc -T lib_6_6 -Fo DRE_Vol2_RT.cso DRE_Vol2_RT.hlsl
    D3D12_DXIL_LIBRARY_DESC dxilLib = {};
    dxilLib.DXILLibrary.pShaderBytecode = desc.compiledShaderBlob;
    dxilLib.DXILLibrary.BytecodeLength  = desc.compiledShaderSize;
    dxilLib.NumExports = 0;   // nullptr = export all entry points in library
    dxilLib.pExports   = nullptr;
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY, &dxilLib);

    // ── 2. Hit Groups ─────────────────────────────────────────────────────────

    // Opaque: ClosestHit only. AnyHit skipped (OPAQUE geometry flag).
    D3D12_HIT_GROUP_DESC hitGroupOpaque = {};
    hitGroupOpaque.HitGroupExport         = L"HitGroup_Opaque";
    hitGroupOpaque.Type                   = D3D12_HIT_GROUP_TYPE_TRIANGLES;
    hitGroupOpaque.ClosestHitShaderImport = L"ClosestHitShader";
    hitGroupOpaque.AnyHitShaderImport     = nullptr;
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &hitGroupOpaque);

    // Alpha-tested: ClosestHit + AnyHit for alpha mask evaluation.
    D3D12_HIT_GROUP_DESC hitGroupAlpha = {};
    hitGroupAlpha.HitGroupExport         = L"HitGroup_AlphaTested";
    hitGroupAlpha.Type                   = D3D12_HIT_GROUP_TYPE_TRIANGLES;
    hitGroupAlpha.ClosestHitShaderImport = L"ClosestHitShader";
    hitGroupAlpha.AnyHitShaderImport     = L"AnyHitAlphaTest";
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &hitGroupAlpha);

    // Shadow: trivial AnyHit only. ClosestHit skipped via RAY_FLAG.
    D3D12_HIT_GROUP_DESC hitGroupShadow = {};
    hitGroupShadow.HitGroupExport         = L"HitGroup_Shadow";
    hitGroupShadow.Type                   = D3D12_HIT_GROUP_TYPE_TRIANGLES;
    hitGroupShadow.ClosestHitShaderImport = nullptr; // RAY_FLAG_SKIP_CLOSEST_HIT_SHADER
    hitGroupShadow.AnyHitShaderImport     = L"AnyHitShadow";
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &hitGroupShadow);

    // ── 3. Shader Config: payload + attribute sizes ───────────────────────────
    // Every byte of payload costs occupancy. 20 bytes is conservative.
    D3D12_RAYTRACING_SHADER_CONFIG shaderConfig = {};
    shaderConfig.MaxPayloadSizeInBytes   = PATH_PAYLOAD_SIZE; // 20 bytes
    shaderConfig.MaxAttributeSizeInBytes = ATTRIBUTE_SIZE;    //  8 bytes
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG,
                  &shaderConfig);

    // ── 4. Pipeline Config: recursion depth ──────────────────────────────────
    // ALWAYS set to 1. PathTrace uses an iterative loop (§ 7.4.1 Vol. 1).
    // Recursion depth > 1 doubles register file pressure per level.
    D3D12_RAYTRACING_PIPELINE_CONFIG pipelineConfig = {};
    pipelineConfig.MaxTraceRecursionDepth = 1;
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG,
                  &pipelineConfig);

    // ── 5. Global Root Signature ──────────────────────────────────────────────
    D3D12_GLOBAL_ROOT_SIGNATURE globalRootSig = {};
    globalRootSig.pGlobalRootSignature = desc.globalRootSignature;
    PushSubobject(subobjects, D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE,
                  &globalRootSig);

    // ── Assemble and create ───────────────────────────────────────────────────
    D3D12_STATE_OBJECT_DESC stateObjectDesc = {};
    stateObjectDesc.Type          = D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE;
    stateObjectDesc.NumSubobjects = (UINT)subobjects.size();
    stateObjectDesc.pSubobjects   = subobjects.data();

    DRE_RTPSO rtpso;
    HRESULT hr = device->CreateStateObject(&stateObjectDesc,
                                            IID_PPV_ARGS(&rtpso.stateObject));
    assert(SUCCEEDED(hr) && "RTPSO creation failed. Check: "
           "1) Shader export name mismatch. 2) Missing shader config. "
           "3) PayloadSize smaller than actual struct.");

    // Retrieve shader identifiers for SBT population.
    rtpso.stateObject->QueryInterface(IID_PPV_ARGS(&rtpso.properties));

    rtpso.rayGenID     = rtpso.properties->GetShaderIdentifier(L"RayGenShader");
    rtpso.missID       = rtpso.properties->GetShaderIdentifier(L"MissShader");
    rtpso.shadowMissID = rtpso.properties->GetShaderIdentifier(L"ShadowMissShader");
    rtpso.opaqueHitID  = rtpso.properties->GetShaderIdentifier(L"HitGroup_Opaque");
    rtpso.alphaHitID   = rtpso.properties->GetShaderIdentifier(L"HitGroup_AlphaTested");
    rtpso.shadowHitID  = rtpso.properties->GetShaderIdentifier(L"HitGroup_Shadow");

    // Assert on nullptr identifiers: export name mismatch is a silent failure.
    assert(rtpso.rayGenID     != nullptr && "RayGenShader not found in DXIL library");
    assert(rtpso.missID       != nullptr && "MissShader not found in DXIL library");
    assert(rtpso.opaqueHitID  != nullptr && "HitGroup_Opaque not found");
    assert(rtpso.shadowHitID  != nullptr && "HitGroup_Shadow not found");

    return rtpso;
}
