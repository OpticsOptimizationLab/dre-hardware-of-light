/**
 * DX12DescriptorManager.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 12.3 — Descriptor Heaps and Bindless
 *
 * One large shader-visible heap for all SRV/UAV/CBV descriptors.
 * Root signature setup for SM 6.6 bindless RT.
 */

#include <d3d12.h>
#include <vector>
#include <cassert>

// Slot layout (must match GBuffer.hlsl SLOT_* constants)
static const UINT SLOT_GBUFFER_A     = 0;
static const UINT SLOT_GBUFFER_B     = 1;
static const UINT SLOT_GBUFFER_C     = 2;
static const UINT SLOT_GBUFFER_VEL   = 3;
static const UINT SLOT_MATERIAL_BUF  = 4;
static const UINT SLOT_OUTPUT_UAV    = 5;
static const UINT SLOT_DENOISED_UAV  = 6;
static const UINT SLOT_HISTORY_SRV   = 7;
static const UINT SLOT_RESERVOIR_A   = 8;
static const UINT SLOT_RESERVOIR_B   = 9;
static const UINT SLOT_SURFACE_HITS  = 10;
static const UINT SLOT_TEXTURES_BASE = 11; // Unbounded material textures start here

static const UINT HEAP_SIZE = 65536; // Large enough for all textures + RT resources

// ─────────────────────────────────────────────────────────────────────────────
// DESCRIPTOR HEAP CREATION (§ 12.3)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_DescriptorHeap
{
    ID3D12DescriptorHeap* heap         = nullptr;
    ID3D12DescriptorHeap* samplerHeap  = nullptr; // Separate heap for samplers
    UINT                  descriptorSize = 0;
    UINT                  nextSlot      = SLOT_TEXTURES_BASE;
};

DRE_DescriptorHeap DRE_CreateDescriptorHeap(ID3D12Device* device)
{
    DRE_DescriptorHeap h;

    // Main CBV/SRV/UAV heap — SHADER_VISIBLE is REQUIRED for bindless.
    D3D12_DESCRIPTOR_HEAP_DESC heapDesc = {};
    heapDesc.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heapDesc.NumDescriptors = HEAP_SIZE;
    heapDesc.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    heapDesc.NodeMask       = 0;
    device->CreateDescriptorHeap(&heapDesc, IID_PPV_ARGS(&h.heap));

    // Sampler heap — separate from CBV/SRV/UAV, DX12 requirement.
    D3D12_DESCRIPTOR_HEAP_DESC samplerDesc = {};
    samplerDesc.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
    samplerDesc.NumDescriptors = 16; // Small: handful of sampler types
    samplerDesc.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    device->CreateDescriptorHeap(&samplerDesc, IID_PPV_ARGS(&h.samplerHeap));

    h.descriptorSize = device->GetDescriptorHandleIncrementSize(
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

    return h;
}

// ─────────────────────────────────────────────────────────────────────────────
// WRITE SRV INTO HEAP AT SPECIFIC SLOT (§ 12.3)
// ─────────────────────────────────────────────────────────────────────────────

void DRE_WriteSRV(DRE_DescriptorHeap& h, ID3D12Device* device,
                  ID3D12Resource* resource, const D3D12_SHADER_RESOURCE_VIEW_DESC& srvDesc,
                  UINT slot)
{
    assert(slot < HEAP_SIZE);
    D3D12_CPU_DESCRIPTOR_HANDLE handle = h.heap->GetCPUDescriptorHandleForHeapStart();
    handle.ptr += (SIZE_T)slot * h.descriptorSize;
    device->CreateShaderResourceView(resource, &srvDesc, handle);
}

void DRE_WriteUAV(DRE_DescriptorHeap& h, ID3D12Device* device,
                  ID3D12Resource* resource, const D3D12_UNORDERED_ACCESS_VIEW_DESC& uavDesc,
                  UINT slot)
{
    assert(slot < HEAP_SIZE);
    D3D12_CPU_DESCRIPTOR_HANDLE handle = h.heap->GetCPUDescriptorHandleForHeapStart();
    handle.ptr += (SIZE_T)slot * h.descriptorSize;
    device->CreateUnorderedAccessView(resource, nullptr, &uavDesc, handle);
}

// Register a texture into the bindless array. Returns its heap slot index.
UINT DRE_RegisterTexture(DRE_DescriptorHeap& h, ID3D12Device* device,
                          ID3D12Resource* texture)
{
    UINT slot = h.nextSlot++;
    assert(slot < HEAP_SIZE);

    D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
    srvDesc.Format                  = texture->GetDesc().Format;
    srvDesc.ViewDimension           = D3D12_SRV_DIMENSION_TEXTURE2D;
    srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srvDesc.Texture2D.MipLevels     = texture->GetDesc().MipLevels;

    DRE_WriteSRV(h, device, texture, srvDesc, slot);
    return slot; // Store in Material.albedoIndex / normalIndex / etc.
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT SIGNATURE FOR BINDLESS RT (§ 12.3)
// Params: [0]=CameraCBV [1]=FrameCBV [2]=TLAS_SRV [3]=OutputUAV [4]=DescriptorTable
// ─────────────────────────────────────────────────────────────────────────────

ID3D12RootSignature* DRE_CreateBindlessRootSignature(ID3D12Device* device)
{
    D3D12_ROOT_PARAMETER1 params[5] = {};

    // [0] Camera CBV (inline root descriptor)
    params[0].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[0].Descriptor.ShaderRegister = 0; // b0
    params[0].Descriptor.RegisterSpace  = 0;
    params[0].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

    // [1] Frame constants CBV (inline)
    params[1].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[1].Descriptor.ShaderRegister = 1; // b1
    params[1].Descriptor.RegisterSpace  = 0;
    params[1].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

    // [2] TLAS SRV (inline — AS requires this form, not descriptor table)
    params[2].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_SRV;
    params[2].Descriptor.ShaderRegister = 0; // t0
    params[2].Descriptor.RegisterSpace  = 0;
    params[2].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

    // [3] Output UAV (inline)
    params[3].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_UAV;
    params[3].Descriptor.ShaderRegister = 0; // u0
    params[3].Descriptor.RegisterSpace  = 0;
    params[3].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

    // [4] Descriptor table: G-Buffer SRVs + material buffer + bindless textures
    D3D12_DESCRIPTOR_RANGE1 ranges[3] = {};

    // G-Buffer SRVs: t1–t4
    ranges[0].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[0].NumDescriptors                    = 4;
    ranges[0].BaseShaderRegister                = 1;
    ranges[0].RegisterSpace                     = 0;
    ranges[0].OffsetInDescriptorsFromTableStart = 0;
    ranges[0].Flags                             = D3D12_DESCRIPTOR_RANGE_FLAG_NONE;

    // Material StructuredBuffer: t5
    ranges[1].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[1].NumDescriptors                    = 1;
    ranges[1].BaseShaderRegister                = 5;
    ranges[1].RegisterSpace                     = 0;
    ranges[1].OffsetInDescriptorsFromTableStart = 4;
    ranges[1].Flags                             = D3D12_DESCRIPTOR_RANGE_FLAG_NONE;

    // Bindless texture array: t6, unbounded
    ranges[2].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    ranges[2].NumDescriptors                    = UINT_MAX; // Unbounded
    ranges[2].BaseShaderRegister                = 6;        // t6
    ranges[2].RegisterSpace                     = 0;
    ranges[2].OffsetInDescriptorsFromTableStart = 5;
    // VOLATILE flags: descriptors and data may change at runtime (streaming).
    ranges[2].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_DESCRIPTORS_VOLATILE
                    | D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;

    params[4].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[4].DescriptorTable.NumDescriptorRanges = 3;
    params[4].DescriptorTable.pDescriptorRanges   = ranges;
    params[4].ShaderVisibility                    = D3D12_SHADER_VISIBILITY_ALL;

    // Static samplers: linear wrap (s0) and point clamp (s1).
    D3D12_STATIC_SAMPLER_DESC staticSamplers[2] = {};

    staticSamplers[0].Filter   = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    staticSamplers[0].AddressU = staticSamplers[0].AddressV = staticSamplers[0].AddressW
                               = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
    staticSamplers[0].MaxLOD         = D3D12_FLOAT32_MAX;
    staticSamplers[0].ShaderRegister = 0; // s0
    staticSamplers[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    staticSamplers[1].Filter   = D3D12_FILTER_MIN_MAG_MIP_POINT;
    staticSamplers[1].AddressU = staticSamplers[1].AddressV = staticSamplers[1].AddressW
                               = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    staticSamplers[1].MaxLOD         = D3D12_FLOAT32_MAX;
    staticSamplers[1].ShaderRegister = 1; // s1
    staticSamplers[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    D3D12_VERSIONED_ROOT_SIGNATURE_DESC rsDesc = {};
    rsDesc.Version                     = D3D_ROOT_SIGNATURE_VERSION_1_1;
    rsDesc.Desc_1_1.NumParameters      = 5;
    rsDesc.Desc_1_1.pParameters        = params;
    rsDesc.Desc_1_1.NumStaticSamplers  = 2;
    rsDesc.Desc_1_1.pStaticSamplers    = staticSamplers;
    rsDesc.Desc_1_1.Flags              = D3D12_ROOT_SIGNATURE_FLAG_NONE;

    ID3DBlob* blob  = nullptr;
    ID3DBlob* error = nullptr;
    D3D12SerializeVersionedRootSignature(&rsDesc, &blob, &error);

    ID3D12RootSignature* rs = nullptr;
    device->CreateRootSignature(0, blob->GetBufferPointer(),
                                blob->GetBufferSize(), IID_PPV_ARGS(&rs));
    blob->Release();
    return rs;
}
