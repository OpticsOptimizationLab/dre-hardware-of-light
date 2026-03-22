// BLAS build for a static mesh.
// Input: vertex buffer + index buffer already on GPU (DEFAULT heap).
// Output: BLAS resource in RAYTRACING_ACCELERATION_STRUCTURE state.

D3D12_RAYTRACING_GEOMETRY_DESC geometryDesc = {};
geometryDesc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
geometryDesc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE; // skip AnyHit
geometryDesc.Triangles.VertexBuffer.StartAddress  = vertexBufferGPU;
geometryDesc.Triangles.VertexBuffer.StrideInBytes  = sizeof(Vertex);
geometryDesc.Triangles.VertexFormat                = DXGI_FORMAT_R32G32B32_FLOAT;
geometryDesc.Triangles.VertexCount                 = vertexCount;
geometryDesc.Triangles.IndexBuffer                 = indexBufferGPU;
geometryDesc.Triangles.IndexFormat                 = DXGI_FORMAT_R32_UINT;
geometryDesc.Triangles.IndexCount                  = indexCount;

D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
inputs.Type          = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
inputs.Flags         = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
inputs.NumDescs      = 1;
inputs.DescsLayout   = D3D12_ELEMENTS_LAYOUT_ARRAY;
inputs.pGeometryDescs = &geometryDesc;

// Query required buffer sizes.
D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo = {};
device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &prebuildInfo);

// Allocate scratch (temporary) and result (permanent).
// Scratch is only needed during build. Result persists for the lifetime of the BLAS.
ID3D12Resource* scratchBuffer = CreateBuffer(
    prebuildInfo.ScratchDataSizeInBytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
ID3D12Resource* blasBuffer = CreateBuffer(
    prebuildInfo.ResultDataMaxSizeInBytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC buildDesc = {};
buildDesc.Inputs                           = inputs;
buildDesc.ScratchAccelerationStructureData = scratchBuffer->GetGPUVirtualAddress();
buildDesc.DestAccelerationStructureData    = blasBuffer->GetGPUVirtualAddress();

commandList->BuildRaytracingAccelerationStructure(&buildDesc, 0, nullptr);

// Barrier: BLAS must complete before TLAS can reference it.
D3D12_RESOURCE_BARRIER uavBarrier = {};
uavBarrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
uavBarrier.UAV.pResource = blasBuffer;
commandList->ResourceBarrier(1, &uavBarrier);