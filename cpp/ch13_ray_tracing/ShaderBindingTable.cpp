// SBT builder for M materials, R ray types.

const UINT shaderIDSize = D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES; // 32
const UINT localRootArgSize = sizeof(D3D12_GPU_VIRTUAL_ADDRESS);  // 8
const UINT recordSize = Align(shaderIDSize + localRootArgSize,
                              D3D12_RAYTRACING_SHADER_RECORD_BYTE_ALIGNMENT); // 64

// Total SBT size.
const UINT rayGenSize   = Align(shaderIDSize + localRootArgSize, 64);
const UINT missSize     = recordSize * NUM_RAY_TYPES;
const UINT hitGroupSize = recordSize * numMaterials * NUM_RAY_TYPES;
const UINT totalSBTSize = rayGenSize + missSize + hitGroupSize;

// Allocate upload buffer.
ID3D12Resource* sbtBuffer = CreateUploadBuffer(totalSBTSize);
uint8_t* mapped = nullptr;
sbtBuffer->Map(0, nullptr, (void**)&mapped);

// ---- RayGen record ----
uint8_t* pRayGen = mapped;
memcpy(pRayGen, rayGenShaderID, shaderIDSize);
// Optional: write camera CBV address after the identifier.
*(D3D12_GPU_VIRTUAL_ADDRESS*)(pRayGen + shaderIDSize) = cameraCBV;

// ---- Miss records ----
uint8_t* pMiss = mapped + rayGenSize;
// Miss 0: primary miss (environment map)
memcpy(pMiss, missShaderID, shaderIDSize);
// Miss 1: shadow miss (return "not occluded")
memcpy(pMiss + recordSize, shadowMissShaderID, shaderIDSize);

// ---- HitGroup records ----
uint8_t* pHitGroup = pMiss + missSize;
for (UINT mat = 0; mat < numMaterials; ++mat)
{
    for (UINT ray = 0; ray < NUM_RAY_TYPES; ++ray)
    {
        uint8_t* record = pHitGroup + (mat * NUM_RAY_TYPES + ray) * recordSize;

        if (ray == 0) // Primary ray
        {
            void* shaderID = materials[mat].isAlphaTested ? alphaTestedHitGroupID
                                                          : opaqueHitGroupID;
            memcpy(record, shaderID, shaderIDSize);
            // Write material CBV address as local root argument.
            *(D3D12_GPU_VIRTUAL_ADDRESS*)(record + shaderIDSize) =
                materials[mat].constantBufferGPUAddress;
        }
        else // Shadow ray
        {
            memcpy(record, shadowHitGroupID, shaderIDSize);
            // Shadow hit groups typically have no local root arguments.
        }
    }
}

sbtBuffer->Unmap(0, nullptr);