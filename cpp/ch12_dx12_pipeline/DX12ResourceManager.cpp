/**
 * DX12ResourceManager.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 12.2 — Resource Management
 *
 * Heap types, committed resource creation, resource state tracking,
 * and VRAM budget reference for a production RT scene at 1440p.
 */

#include <d3d12.h>
#include <vector>
#include <unordered_map>
#include <cassert>

// ─────────────────────────────────────────────────────────────────────────────
// COMMITTED RESOURCE CREATION HELPERS (§ 12.2)
// Rule: DEFAULT heap for everything that doesn't need CPU access.
// ─────────────────────────────────────────────────────────────────────────────

// UAV-capable render target / compute output (DEFAULT heap).
ID3D12Resource* DRE_CreateUAVTexture(
    ID3D12Device* device,
    UINT width, UINT height,
    DXGI_FORMAT format,
    D3D12_RESOURCE_STATES initialState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension          = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width              = width;
    desc.Height             = height;
    desc.DepthOrArraySize   = 1;
    desc.MipLevels          = 1;
    desc.Format             = format;
    desc.SampleDesc.Count   = 1;
    desc.Layout             = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags              = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

    ID3D12Resource* resource = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, initialState,
        nullptr, IID_PPV_ARGS(&resource));
    return resource;
}

// Render target (G-Buffer write target). DEFAULT heap.
ID3D12Resource* DRE_CreateRenderTarget(
    ID3D12Device* device,
    UINT width, UINT height,
    DXGI_FORMAT format)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension          = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width              = width;
    desc.Height             = height;
    desc.DepthOrArraySize   = 1;
    desc.MipLevels          = 1;
    desc.Format             = format;
    desc.SampleDesc.Count   = 1;
    desc.Layout             = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags              = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET
                            | D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

    ID3D12Resource* resource = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_RENDER_TARGET,
        nullptr, IID_PPV_ARGS(&resource));
    return resource;
}

// Upload heap buffer: CPU writes every frame, GPU reads (CBVs, instance buffer, SBT).
ID3D12Resource* DRE_CreateUploadBuffer(ID3D12Device* device, UINT64 sizeInBytes)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_UPLOAD;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension  = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width      = sizeInBytes;
    desc.Height     = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels  = 1;
    desc.Format     = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout     = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags      = D3D12_RESOURCE_FLAG_NONE;

    ID3D12Resource* resource = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_GENERIC_READ,
        nullptr, IID_PPV_ARGS(&resource));
    return resource;
}

// DEFAULT heap buffer: UAV-capable. Used for AS scratch, output buffers.
ID3D12Resource* DRE_CreateDefaultBuffer(
    ID3D12Device* device,
    UINT64 sizeInBytes,
    D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
    D3D12_RESOURCE_STATES initialState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS)
{
    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension  = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width      = sizeInBytes;
    desc.Height     = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels  = 1;
    desc.Format     = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout     = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags      = flags;

    ID3D12Resource* resource = nullptr;
    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, initialState,
        nullptr, IID_PPV_ARGS(&resource));
    return resource;
}

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCE BARRIER HELPERS (§ 12.2)
// ─────────────────────────────────────────────────────────────────────────────

void DRE_TransitionBarrier(
    ID3D12GraphicsCommandList* cmdList,
    ID3D12Resource*            resource,
    D3D12_RESOURCE_STATES      before,
    D3D12_RESOURCE_STATES      after)
{
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Flags                  = D3D12_RESOURCE_BARRIER_FLAG_NONE;
    barrier.Transition.pResource   = resource;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter  = after;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    cmdList->ResourceBarrier(1, &barrier);
}

void DRE_UAVBarrier(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* resource)
{
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    barrier.UAV.pResource = resource;
    cmdList->ResourceBarrier(1, &barrier);
}

// ─────────────────────────────────────────────────────────────────────────────
// G-BUFFER MANAGER: CREATE ALL G-BUFFER TARGETS (§ 12.2, 14.2)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_GBuffer
{
    ID3D12Resource* rt0 = nullptr; // R16G16B16A16_FLOAT: worldPos + roughness
    ID3D12Resource* rt1 = nullptr; // R16G16B16A16_FLOAT: normal + metallic
    ID3D12Resource* rt2 = nullptr; // R8G8B8A8_UNORM:     albedo + AO
    ID3D12Resource* rt3 = nullptr; // R16G16_FLOAT:       velocity (pixel space)
    ID3D12Resource* ds  = nullptr; // D32_FLOAT:          depth
    UINT width  = 0;
    UINT height = 0;
};

DRE_GBuffer DRE_CreateGBuffer(ID3D12Device* device, UINT width, UINT height)
{
    DRE_GBuffer g;
    g.width  = width;
    g.height = height;

    g.rt0 = DRE_CreateRenderTarget(device, width, height, DXGI_FORMAT_R16G16B16A16_FLOAT);
    g.rt1 = DRE_CreateRenderTarget(device, width, height, DXGI_FORMAT_R16G16B16A16_FLOAT);
    g.rt2 = DRE_CreateRenderTarget(device, width, height, DXGI_FORMAT_R8G8B8A8_UNORM);
    g.rt3 = DRE_CreateRenderTarget(device, width, height, DXGI_FORMAT_R16G16_FLOAT);

    // Depth buffer: ALLOW_DEPTH_STENCIL, no ALLOW_UNORDERED_ACCESS.
    {
        D3D12_HEAP_PROPERTIES heapProps = {};
        heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

        D3D12_RESOURCE_DESC desc = {};
        desc.Dimension          = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width              = width;
        desc.Height             = height;
        desc.DepthOrArraySize   = 1;
        desc.MipLevels          = 1;
        desc.Format             = DXGI_FORMAT_D32_FLOAT;
        desc.SampleDesc.Count   = 1;
        desc.Layout             = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        desc.Flags              = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;

        D3D12_CLEAR_VALUE clearValue = {};
        clearValue.Format       = DXGI_FORMAT_D32_FLOAT;
        clearValue.DepthStencil.Depth = 1.0f;

        device->CreateCommittedResource(
            &heapProps, D3D12_HEAP_FLAG_NONE,
            &desc, D3D12_RESOURCE_STATE_DEPTH_WRITE,
            &clearValue, IID_PPV_ARGS(&g.ds));
    }

    return g;
}

// ─────────────────────────────────────────────────────────────────────────────
// VRAM BUDGET REFERENCE (§ 12.2) — 1440p native, 8GB minimum spec
// ─────────────────────────────────────────────────────────────────────────────

/*
  Resource                       | Format               | Size (1440p)
  -------------------------------|----------------------|-------------
  G-Buffer RT0 (worldPos+rough)  | R16G16B16A16_FLOAT   | 28.2 MB
  G-Buffer RT1 (normal+metallic) | R16G16B16A16_FLOAT   | 28.2 MB
  G-Buffer RT2 (albedo+AO)       | R8G8B8A8_UNORM       | 14.1 MB
  G-Buffer RT3 (velocity)        | R16G16_FLOAT         | 14.1 MB
  Depth buffer                   | D32_FLOAT            | 14.1 MB
  Radiance output UAV            | R16G16B16A16_FLOAT   | 28.2 MB
  Denoised output                | R16G16B16A16_FLOAT   | 28.2 MB
  History (temporal)             | R16G16B16A16_FLOAT   | 28.2 MB
  ReSTIR DI reservoir A          | R32G32B32A32_FLOAT   | 56.6 MB
  ReSTIR DI reservoir B (ping)   | R32G32B32A32_FLOAT   | 56.6 MB
  BLAS pool (static, compacted)  | —                    | ~150 MB
  TLAS + instance buffer         | —                    | ~10  MB
  Material textures (BC7)        | —                    | ~800 MB
  ───────────────────────────────────────────────────────────────
  RT render targets subtotal     |                      | ~240 MB
  AS total                       |                      | ~160 MB
  Textures                       |                      | ~800 MB
  TOTAL                          |                      | ~1200 MB

  On 8GB GPU: ~7.5GB available. 1.2GB = 16% of budget. Tight but viable.
  Adding ReSTIR GI + DLSS RR + NRC pushes to ~2.0GB render targets. Margin thin.
  Texture streaming is mandatory on minimum spec (8GB).
*/
