/**
 * ShaderBindingTable.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 13.4 — The Shader Binding Table
 *
 * Generalized SBT builder for N materials and R ray types.
 * Layout: [RayGen] [Miss × R] [HitGroup × N × R]
 *
 * WARNING: Wrong stride or wrong InstanceContributionToHitGroupIndex produces
 * silent material routing bugs — objects render with the wrong material.
 * No runtime validation catches this.
 */

#include <d3d12.h>
#include <vector>
#include <cassert>
#include <cstring>

static const UINT SHADER_ID_SIZE = D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES; // 32 bytes
static const UINT SBT_ALIGNMENT  = D3D12_RAYTRACING_SHADER_RECORD_BYTE_ALIGNMENT; // 32 bytes

// Round up to next multiple of alignment.
static UINT Align(UINT size, UINT alignment)
{
    return (size + alignment - 1) & ~(alignment - 1);
}

// ─────────────────────────────────────────────────────────────────────────────
// MATERIAL BINDING DATA (per material, per primary ray)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_SBTMaterial
{
    void*                     primaryHitGroupID;     // Shader identifier (32 bytes)
    D3D12_GPU_VIRTUAL_ADDRESS materialCBVAddress;    // Per-material constant buffer
    bool                      isAlphaTested;
};

// ─────────────────────────────────────────────────────────────────────────────
// SBT DESCRIPTOR
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_SBTDesc
{
    // Shader identifiers from RTPSO (§ 13.3).
    void* rayGenShaderID;
    void* missShaderID;        // Primary miss: returns environment color
    void* shadowMissShaderID;  // Shadow miss: returns "not occluded"
    void* opaqueHitGroupID;
    void* alphaTestedHitGroupID;
    void* shadowHitGroupID;

    D3D12_GPU_VIRTUAL_ADDRESS cameraCBVAddress; // Optional: bind to RayGen record

    std::vector<DRE_SBTMaterial> materials;
};

struct DRE_SBT
{
    ID3D12Resource*  buffer        = nullptr;
    UINT             recordSize    = 0; // Stride between HitGroup records
    UINT64           rayGenOffset  = 0;
    UINT64           missOffset    = 0;
    UINT64           hitGroupOffset = 0;
    UINT             numMaterials  = 0;
    D3D12_DISPATCH_RAYS_DESC dispatchDesc = {};
};

// ─────────────────────────────────────────────────────────────────────────────
// BUILD SBT (§ 13.4)
// ─────────────────────────────────────────────────────────────────────────────

static ID3D12Resource* CreateUploadBuffer(ID3D12Device* device, UINT64 size)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_UPLOAD;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension  = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width      = size;
    desc.Height     = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels  = 1;
    desc.Format     = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout     = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags      = D3D12_RESOURCE_FLAG_NONE;

    ID3D12Resource* buf = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_GENERIC_READ,
        nullptr, IID_PPV_ARGS(&buf));
    return buf;
}

DRE_SBT DRE_BuildSBT(ID3D12Device* device, const DRE_SBTDesc& desc)
{
    static const UINT NUM_RAY_TYPES = 2; // Primary + shadow (must match TLAS build)

    const UINT numMaterials = (UINT)desc.materials.size();

    // Record size: shader identifier (32) + local root args (8 = GPU VA) + padding to 64.
    const UINT localRootArgSize = sizeof(D3D12_GPU_VIRTUAL_ADDRESS); // 8 bytes
    const UINT recordSize = Align(SHADER_ID_SIZE + localRootArgSize, SBT_ALIGNMENT); // 64
    assert(recordSize % SBT_ALIGNMENT == 0);

    // Layout sizes.
    const UINT rayGenSize    = Align(SHADER_ID_SIZE + localRootArgSize, SBT_ALIGNMENT);
    const UINT missSize      = recordSize * NUM_RAY_TYPES;
    const UINT hitGroupSize  = recordSize * numMaterials * NUM_RAY_TYPES;
    const UINT totalSize     = rayGenSize + missSize + hitGroupSize;

    ID3D12Resource* sbtBuffer = CreateUploadBuffer(device, totalSize);
    uint8_t* mapped = nullptr;
    sbtBuffer->Map(0, nullptr, (void**)&mapped);

    // ── RayGen record ────────────────────────────────────────────────────────
    uint8_t* pRayGen = mapped;
    memcpy(pRayGen, desc.rayGenShaderID, SHADER_ID_SIZE);
    *reinterpret_cast<D3D12_GPU_VIRTUAL_ADDRESS*>(pRayGen + SHADER_ID_SIZE) =
        desc.cameraCBVAddress;

    // ── Miss records ─────────────────────────────────────────────────────────
    uint8_t* pMiss = mapped + rayGenSize;
    // Record 0: primary miss (environment map, returns sky color)
    memcpy(pMiss, desc.missShaderID, SHADER_ID_SIZE);
    // Record 1: shadow miss (returns "not occluded" — no payload write needed)
    memcpy(pMiss + recordSize, desc.shadowMissShaderID, SHADER_ID_SIZE);

    // ── HitGroup records ─────────────────────────────────────────────────────
    // Formula: index = InstanceContributionToHitGroupIndex + GeometryIndex * R + RayType
    // For material M: InstanceContributionToHitGroupIndex = M * NUM_RAY_TYPES (set in TLAS)
    // So: material 0 → records [0, 1], material 1 → records [2, 3], etc.
    uint8_t* pHitGroup = pMiss + missSize;

    for (UINT mat = 0; mat < numMaterials; ++mat)
    {
        const DRE_SBTMaterial& material = desc.materials[mat];

        for (UINT ray = 0; ray < NUM_RAY_TYPES; ++ray)
        {
            uint8_t* record = pHitGroup + (mat * NUM_RAY_TYPES + ray) * recordSize;

            if (ray == 0) // Primary ray
            {
                void* hitGroupID = material.isAlphaTested
                                 ? desc.alphaTestedHitGroupID
                                 : desc.opaqueHitGroupID;
                memcpy(record, hitGroupID, SHADER_ID_SIZE);
                // Local root argument: material constant buffer GPU address.
                *reinterpret_cast<D3D12_GPU_VIRTUAL_ADDRESS*>(record + SHADER_ID_SIZE) =
                    material.materialCBVAddress;
            }
            else // Shadow ray (ray type 1)
            {
                memcpy(record, desc.shadowHitGroupID, SHADER_ID_SIZE);
                // Shadow hit groups: no local root arguments needed.
                // Padding is already zero from the upload buffer clear.
            }
        }
    }

    sbtBuffer->Unmap(0, nullptr);

    // ── Build DRE_SBT ────────────────────────────────────────────────────────
    DRE_SBT sbt;
    sbt.buffer         = sbtBuffer;
    sbt.recordSize     = recordSize;
    sbt.numMaterials   = numMaterials;

    D3D12_GPU_VIRTUAL_ADDRESS sbtGPU = sbtBuffer->GetGPUVirtualAddress();

    D3D12_DISPATCH_RAYS_DESC& dr = sbt.dispatchDesc;

    dr.RayGenerationShaderRecord.StartAddress = sbtGPU;
    dr.RayGenerationShaderRecord.SizeInBytes  = rayGenSize;

    dr.MissShaderTable.StartAddress  = sbtGPU + rayGenSize;
    dr.MissShaderTable.SizeInBytes   = missSize;
    dr.MissShaderTable.StrideInBytes = recordSize;

    dr.HitGroupTable.StartAddress  = sbtGPU + rayGenSize + missSize;
    dr.HitGroupTable.SizeInBytes   = hitGroupSize;
    dr.HitGroupTable.StrideInBytes = recordSize;

    // Width/Height/Depth filled by caller at dispatch time.

    return sbt;
}

// ─────────────────────────────────────────────────────────────────────────────
// DISPATCH RAYS (§ 13.4)
// ─────────────────────────────────────────────────────────────────────────────

void DRE_DispatchRays(
    ID3D12GraphicsCommandList4* cmdList,
    ID3D12StateObject* rtpso,
    DRE_SBT& sbt,
    UINT renderWidth, UINT renderHeight)
{
    sbt.dispatchDesc.Width  = renderWidth;
    sbt.dispatchDesc.Height = renderHeight;
    sbt.dispatchDesc.Depth  = 1;

    cmdList->SetPipelineState1(rtpso);
    cmdList->DispatchRays(&sbt.dispatchDesc);
}

// ─────────────────────────────────────────────────────────────────────────────
// CANONICAL SBT BUG REFERENCE (§ 13.4)
//
// BUG: InstanceContributionToHitGroupIndex set to M instead of M * NUM_RAY_TYPES.
// EFFECT: Material M primary ray resolves to material (M-1)'s shadow record.
//         Objects render as black silhouettes. Looks like a lighting bug.
//         No crash. No validation error.
// FIX:    Always set InstanceContributionToHitGroupIndex = materialIndex * NUM_RAY_TYPES.
//         Verify by rendering InstanceID() as a heatmap.
//
// BUG: HitGroupTable.StrideInBytes = 32 (sizeof shader identifier) when record is 64.
// EFFECT: Hardware reads second half of record 0 as the identifier for record 1.
//         Every material maps to the wrong shader. Abstract painting output.
// FIX:    StrideInBytes = Align(SHADER_ID_SIZE + localRootArgSize, SBT_ALIGNMENT).
// ─────────────────────────────────────────────────────────────────────────────
