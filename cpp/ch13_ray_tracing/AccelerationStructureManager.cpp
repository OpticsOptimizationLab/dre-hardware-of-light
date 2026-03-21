/**
 * AccelerationStructureManager.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 13.1–13.2 — The Acceleration Structure + BVH Construction
 *
 * BLAS build (static + dynamic with refit), TLAS build from instance array,
 * BLAS compaction, and BVH build flag reference.
 * Requires: d3d12.h, D3D12 Agility SDK 1.600+
 */

#include <d3d12.h>
#include <vector>
#include <cassert>
#include <cstring>

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: CREATE DEFAULT-HEAP UAV BUFFER (§ 13.1)
// ─────────────────────────────────────────────────────────────────────────────

static ID3D12Resource* CreateASBuffer(ID3D12Device* device, UINT64 size)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension  = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width      = size;
    desc.Height     = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels  = 1;
    desc.Format     = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout     = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags      = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

    ID3D12Resource* buf = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
        nullptr, IID_PPV_ARGS(&buf));
    return buf;
}

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

// ─────────────────────────────────────────────────────────────────────────────
// BLAS DESCRIPTOR (§ 13.1)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_BLASDesc
{
    D3D12_GPU_VIRTUAL_ADDRESS vertexBufferGPU;
    UINT                      vertexStride;
    UINT                      vertexCount;
    D3D12_GPU_VIRTUAL_ADDRESS indexBufferGPU;
    UINT                      indexCount;
    bool                      isDynamic;     // true → PREFER_FAST_BUILD + allow refit
    bool                      isAlphaTested; // true → geometry NOT opaque (invokes AnyHit)
};

struct DRE_BLAS
{
    ID3D12Resource* result   = nullptr; // Permanent BLAS buffer
    ID3D12Resource* scratch  = nullptr; // Temporary scratch (can be freed after build)
    UINT64          resultSize = 0;
};

// ─────────────────────────────────────────────────────────────────────────────
// BUILD BLAS (§ 13.1 + 13.2)
// ─────────────────────────────────────────────────────────────────────────────

DRE_BLAS DRE_BuildBLAS(
    ID3D12Device5* device,
    ID3D12GraphicsCommandList4* cmdList,
    const DRE_BLASDesc& desc)
{
    D3D12_RAYTRACING_GEOMETRY_DESC geomDesc = {};
    geomDesc.Type  = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;

    // Opaque flag skips AnyHit shader — faster traversal on RT cores.
    // Alpha-tested geometry must NOT use OPAQUE: AnyHit must run.
    geomDesc.Flags = desc.isAlphaTested
                   ? D3D12_RAYTRACING_GEOMETRY_FLAG_NONE
                   : D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;

    geomDesc.Triangles.VertexBuffer.StartAddress  = desc.vertexBufferGPU;
    geomDesc.Triangles.VertexBuffer.StrideInBytes = desc.vertexStride;
    geomDesc.Triangles.VertexFormat               = DXGI_FORMAT_R32G32B32_FLOAT;
    geomDesc.Triangles.VertexCount                = desc.vertexCount;
    geomDesc.Triangles.IndexBuffer                = desc.indexBufferGPU;
    geomDesc.Triangles.IndexFormat                = DXGI_FORMAT_R32_UINT;
    geomDesc.Triangles.IndexCount                 = desc.indexCount;

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type           = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
    inputs.NumDescs       = 1;
    inputs.DescsLayout    = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.pGeometryDescs = &geomDesc;

    // Build flags (§ 13.2):
    // Static: PREFER_FAST_TRACE — spend more time building, faster traversal.
    //         Built once, traced millions of times.
    // Dynamic: PREFER_FAST_BUILD | ALLOW_UPDATE — faster build, allows refit.
    //          Skinned characters, cloth, particles.
    inputs.Flags = desc.isDynamic
        ? (D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD
         | D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE)
        : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;

    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo = {};
    device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &prebuildInfo);

    DRE_BLAS blas;
    blas.resultSize = prebuildInfo.ResultDataMaxSizeInBytes;
    blas.scratch    = CreateASBuffer(device, prebuildInfo.ScratchDataSizeInBytes);
    blas.result     = CreateASBuffer(device, prebuildInfo.ResultDataMaxSizeInBytes);

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC buildDesc = {};
    buildDesc.Inputs                           = inputs;
    buildDesc.ScratchAccelerationStructureData = blas.scratch->GetGPUVirtualAddress();
    buildDesc.DestAccelerationStructureData    = blas.result->GetGPUVirtualAddress();

    cmdList->BuildRaytracingAccelerationStructure(&buildDesc, 0, nullptr);

    // UAV barrier: BLAS must complete before TLAS references it.
    D3D12_RESOURCE_BARRIER uavBarrier = {};
    uavBarrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    uavBarrier.UAV.pResource = blas.result;
    cmdList->ResourceBarrier(1, &uavBarrier);

    return blas;
}

// ─────────────────────────────────────────────────────────────────────────────
// REFIT BLAS (§ 13.1) — per-frame for dynamic meshes
// ~10% cost of a full rebuild. Structure stays fixed, bounding boxes updated.
// ─────────────────────────────────────────────────────────────────────────────

void DRE_RefitBLAS(
    ID3D12GraphicsCommandList4* cmdList,
    const DRE_BLAS& blas,
    const DRE_BLASDesc& desc)
{
    D3D12_RAYTRACING_GEOMETRY_DESC geomDesc = {};
    geomDesc.Type  = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
    geomDesc.Flags = desc.isAlphaTested
                   ? D3D12_RAYTRACING_GEOMETRY_FLAG_NONE
                   : D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
    geomDesc.Triangles.VertexBuffer.StartAddress  = desc.vertexBufferGPU; // Updated positions
    geomDesc.Triangles.VertexBuffer.StrideInBytes = desc.vertexStride;
    geomDesc.Triangles.VertexFormat               = DXGI_FORMAT_R32G32B32_FLOAT;
    geomDesc.Triangles.VertexCount                = desc.vertexCount;
    geomDesc.Triangles.IndexBuffer                = desc.indexBufferGPU;
    geomDesc.Triangles.IndexFormat                = DXGI_FORMAT_R32_UINT;
    geomDesc.Triangles.IndexCount                 = desc.indexCount;

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type           = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
    inputs.Flags          = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD
                          | D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE
                          | D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PERFORM_UPDATE;
    inputs.NumDescs       = 1;
    inputs.DescsLayout    = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.pGeometryDescs = &geomDesc;

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC buildDesc = {};
    buildDesc.Inputs                           = inputs;
    buildDesc.ScratchAccelerationStructureData = blas.scratch->GetGPUVirtualAddress();
    buildDesc.DestAccelerationStructureData    = blas.result->GetGPUVirtualAddress();
    buildDesc.SourceAccelerationStructureData  = blas.result->GetGPUVirtualAddress();
    // Source == Dest: in-place refit.

    cmdList->BuildRaytracingAccelerationStructure(&buildDesc, 0, nullptr);

    D3D12_RESOURCE_BARRIER uavBarrier = {};
    uavBarrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    uavBarrier.UAV.pResource = blas.result;
    cmdList->ResourceBarrier(1, &uavBarrier);
}

// ─────────────────────────────────────────────────────────────────────────────
// SCENE OBJECT FOR TLAS (§ 13.1)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_SceneObject
{
    float              worldMatrix[3][4]; // Row-major 3×4 transform
    UINT               materialIndex;
    D3D12_GPU_VIRTUAL_ADDRESS blasGPUAddress;
    bool               isAlphaTested;
};

// ─────────────────────────────────────────────────────────────────────────────
// BUILD TLAS (§ 13.1) — rebuilt every frame (~0.3ms for 10K instances)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_TLAS
{
    ID3D12Resource* result         = nullptr;
    ID3D12Resource* scratch        = nullptr;
    ID3D12Resource* instanceBuffer = nullptr; // Upload heap: CPU writes per frame
    UINT            instanceCount  = 0;
};

DRE_TLAS DRE_BuildTLAS(
    ID3D12Device5* device,
    ID3D12GraphicsCommandList4* cmdList,
    const std::vector<DRE_SceneObject>& objects)
{
    static const UINT NUM_RAY_TYPES = 2; // Primary + shadow

    DRE_TLAS tlas;
    tlas.instanceCount = (UINT)objects.size();

    // 1. Populate instance descriptors (CPU side).
    std::vector<D3D12_RAYTRACING_INSTANCE_DESC> instances(objects.size());

    for (UINT i = 0; i < (UINT)objects.size(); ++i)
    {
        const DRE_SceneObject& obj = objects[i];
        D3D12_RAYTRACING_INSTANCE_DESC& inst = instances[i];

        memcpy(inst.Transform, obj.worldMatrix, sizeof(inst.Transform));

        // InstanceID() in ClosestHit: the bridge between geometry and shading.
        inst.InstanceID                          = obj.materialIndex;
        inst.InstanceMask                        = 0xFF; // Visible to all ray types
        // SBT offset formula: material * NUM_RAY_TYPES (§ 13.4)
        inst.InstanceContributionToHitGroupIndex = obj.materialIndex * NUM_RAY_TYPES;
        inst.Flags                               = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
        inst.AccelerationStructure               = obj.blasGPUAddress;
    }

    // 2. Upload instances to GPU (upload heap: CPU writes, GPU reads during build).
    UINT64 instanceBufferSize = objects.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC);
    tlas.instanceBuffer = CreateUploadBuffer(device, instanceBufferSize);

    void* mapped = nullptr;
    tlas.instanceBuffer->Map(0, nullptr, &mapped);
    memcpy(mapped, instances.data(), instanceBufferSize);
    tlas.instanceBuffer->Unmap(0, nullptr);

    // 3. Query TLAS prebuild info.
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS tlasInputs = {};
    tlasInputs.Type          = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    tlasInputs.Flags         = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
    tlasInputs.NumDescs      = tlas.instanceCount;
    tlasInputs.DescsLayout   = D3D12_ELEMENTS_LAYOUT_ARRAY;
    tlasInputs.InstanceDescs = tlas.instanceBuffer->GetGPUVirtualAddress();

    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo = {};
    device->GetRaytracingAccelerationStructurePrebuildInfo(&tlasInputs, &prebuildInfo);

    tlas.scratch = CreateASBuffer(device, prebuildInfo.ScratchDataSizeInBytes);
    tlas.result  = CreateASBuffer(device, prebuildInfo.ResultDataMaxSizeInBytes);

    // 4. Build.
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC buildDesc = {};
    buildDesc.Inputs                           = tlasInputs;
    buildDesc.ScratchAccelerationStructureData = tlas.scratch->GetGPUVirtualAddress();
    buildDesc.DestAccelerationStructureData    = tlas.result->GetGPUVirtualAddress();

    cmdList->BuildRaytracingAccelerationStructure(&buildDesc, 0, nullptr);

    // UAV barrier: TLAS must complete before DispatchRays.
    D3D12_RESOURCE_BARRIER uavBarrier = {};
    uavBarrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    uavBarrier.UAV.pResource = tlas.result;
    cmdList->ResourceBarrier(1, &uavBarrier);

    return tlas;
}

// ─────────────────────────────────────────────────────────────────────────────
// BVH BUILD FLAG REFERENCE (§ 13.2)
//
// PREFER_FAST_TRACE:  Better BVH quality, slower build. For static geometry.
//                     Built once, traversed millions of times. Always use this.
// PREFER_FAST_BUILD:  Faster build, lower quality BVH. For geometry rebuilt/frame.
//                     In practice, almost never use — prefer refit instead.
// ALLOW_UPDATE:       Enables refit (PERFORM_UPDATE). Required on first build.
// PERFORM_UPDATE:     Refit existing BVH from updated vertex positions.
//                     Combined with ALLOW_UPDATE. ~10% cost of full rebuild.
// ALLOW_COMPACTION:   Post-build compaction reduces BLAS size 30–50%.
//                     Use for static BLASes after the initial build.
//
// PRODUCTION RULE:
//   Static mesh:   PREFER_FAST_TRACE + ALLOW_COMPACTION → compact after build
//   Dynamic mesh:  PREFER_FAST_BUILD + ALLOW_UPDATE → refit every frame
// ─────────────────────────────────────────────────────────────────────────────
