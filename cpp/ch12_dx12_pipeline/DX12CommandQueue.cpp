/**
 * DX12CommandQueue.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 12.1 — Command Queue Architecture
 *
 * Three-queue setup (Direct, Compute, Copy) with N=3 frames-in-flight fence pattern.
 * Requires: d3d12.h, dxgi.h, D3D12 Agility SDK 1.600+
 */

#include <d3d12.h>
#include <dxgi1_6.h>
#include <cassert>
#include <vector>
#include <windows.h>

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS (§ 12.1)
// ─────────────────────────────────────────────────────────────────────────────

static const UINT FRAMES_IN_FLIGHT = 3;
// N=3: CPU runs 2 frames ahead of GPU. GPU never starved. Input latency: 2 frames.
// N=1: CPU waits every frame → CPU-bound. N>3: extra latency, no GPU gain.

// ─────────────────────────────────────────────────────────────────────────────
// QUEUE CREATION (§ 12.1)
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_CommandQueues
{
    ID3D12CommandQueue* graphics = nullptr; // Direct: all ops
    ID3D12CommandQueue* compute  = nullptr; // Compute: async BLAS, ReSTIR
    ID3D12CommandQueue* copy     = nullptr; // Copy: DMA engine, texture streaming
};

DRE_CommandQueues DRE_CreateQueues(ID3D12Device* device)
{
    DRE_CommandQueues q;
    D3D12_COMMAND_QUEUE_DESC desc = {};

    // Graphics queue: PRIORITY_HIGH to reduce frame time jitter on systems
    // with background processes (game launchers, antivirus, Discord).
    desc.Type     = D3D12_COMMAND_LIST_TYPE_DIRECT;
    desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_HIGH;
    desc.Flags    = D3D12_COMMAND_QUEUE_FLAG_NONE;
    desc.NodeMask = 0;
    device->CreateCommandQueue(&desc, IID_PPV_ARGS(&q.graphics));

    desc.Type     = D3D12_COMMAND_LIST_TYPE_COMPUTE;
    desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
    device->CreateCommandQueue(&desc, IID_PPV_ARGS(&q.compute));

    desc.Type     = D3D12_COMMAND_LIST_TYPE_COPY;
    desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
    device->CreateCommandQueue(&desc, IID_PPV_ARGS(&q.copy));

    return q;
}

// ─────────────────────────────────────────────────────────────────────────────
// PER-FRAME RESOURCES (§ 12.1)
// One allocator per queue per frame. Never share allocators across queues —
// Direct queue and Compute queue have independent execution timelines.
// ─────────────────────────────────────────────────────────────────────────────

struct FrameResources
{
    ID3D12CommandAllocator* directAllocator  = nullptr;
    ID3D12CommandAllocator* computeAllocator = nullptr;
    UINT64                  fenceValue       = 0;
};

struct DRE_FrameManager
{
    FrameResources frames[FRAMES_IN_FLIGHT];
    ID3D12Fence*   fence        = nullptr;
    UINT64         fenceCounter = 0;
    HANDLE         fenceEvent   = nullptr;
    UINT           currentFrame = 0;
};

DRE_FrameManager DRE_CreateFrameManager(ID3D12Device* device)
{
    DRE_FrameManager fm;

    device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fm.fence));
    fm.fenceEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    assert(fm.fenceEvent != nullptr);

    for (UINT i = 0; i < FRAMES_IN_FLIGHT; ++i)
    {
        device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&fm.frames[i].directAllocator));
        device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_COMPUTE,
            IID_PPV_ARGS(&fm.frames[i].computeAllocator));
        fm.frames[i].fenceValue = 0;
    }

    return fm;
}

// ─────────────────────────────────────────────────────────────────────────────
// FRAME START: WAIT FOR OLDEST IN-FLIGHT FRAME (§ 12.1)
// ─────────────────────────────────────────────────────────────────────────────

FrameResources& DRE_BeginFrame(DRE_FrameManager& fm)
{
    fm.currentFrame = (fm.currentFrame + 1) % FRAMES_IN_FLIGHT;
    FrameResources& frame = fm.frames[fm.currentFrame];

    // Wait only if GPU hasn't completed this frame's fence yet.
    if (fm.fence->GetCompletedValue() < frame.fenceValue)
    {
        fm.fence->SetEventOnCompletion(frame.fenceValue, fm.fenceEvent);
        WaitForSingleObject(fm.fenceEvent, INFINITE);
        // CPU was suspended here. OS scheduled other threads. No spin-wait.
    }

    // Safe to reset: GPU is done with all commands recorded with these allocators.
    frame.directAllocator->Reset();
    frame.computeAllocator->Reset();

    return frame;
}

// ─────────────────────────────────────────────────────────────────────────────
// FRAME END: SIGNAL FENCE (§ 12.1)
// ─────────────────────────────────────────────────────────────────────────────

void DRE_EndFrame(DRE_FrameManager& fm, ID3D12CommandQueue* graphicsQueue)
{
    FrameResources& frame = fm.frames[fm.currentFrame];

    graphicsQueue->Signal(fm.fence, ++fm.fenceCounter);
    frame.fenceValue = fm.fenceCounter;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIPLE-BUFFERED CONSTANT BUFFER (§ 12.1)
// CPU writes per-frame data. GPU reads on the same frame. One buffer per frame.
// ─────────────────────────────────────────────────────────────────────────────

struct PerFrameCBV
{
    ID3D12Resource*           resource   = nullptr;
    D3D12_GPU_VIRTUAL_ADDRESS gpuAddress = 0;
    void*                     mappedData = nullptr; // Persistently mapped (upload heap)
};

PerFrameCBV DRE_CreatePerFrameCBV(ID3D12Device* device, SIZE_T dataSize)
{
    PerFrameCBV cbv;

    D3D12_HEAP_PROPERTIES heapProps = {};
    heapProps.Type = D3D12_HEAP_TYPE_UPLOAD; // CPU-writable, GPU-readable over PCIe

    // Constant buffer size must be aligned to 256 bytes.
    SIZE_T alignedSize = (dataSize + 255) & ~255;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension  = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width      = alignedSize;
    desc.Height     = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels  = 1;
    desc.Format     = DXGI_FORMAT_UNKNOWN;
    desc.SampleDesc.Count = 1;
    desc.Layout     = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags      = D3D12_RESOURCE_FLAG_NONE;

    device->CreateCommittedResource(
        &heapProps, D3D12_HEAP_FLAG_NONE,
        &desc, D3D12_RESOURCE_STATE_GENERIC_READ,
        nullptr, IID_PPV_ARGS(&cbv.resource));

    // Persistent mapping: valid for upload heap resources.
    // Upload heap is always CPU-coherent; no explicit flush needed.
    cbv.resource->Map(0, nullptr, &cbv.mappedData);
    cbv.gpuAddress = cbv.resource->GetGPUVirtualAddress();

    return cbv;
}

// ─────────────────────────────────────────────────────────────────────────────
// COMMAND LIST RECORDING AND SUBMISSION (§ 12.1)
// ─────────────────────────────────────────────────────────────────────────────

void DRE_SubmitCommandList(
    ID3D12GraphicsCommandList* cmdList,
    ID3D12CommandQueue*        queue)
{
    cmdList->Close();

    ID3D12CommandList* lists[] = { cmdList };
    queue->ExecuteCommandLists(1, lists);
}

// ─────────────────────────────────────────────────────────────────────────────
// CROSS-QUEUE SYNCHRONIZATION (§ 12.1, 11.4)
//
// To synchronize Compute queue → Graphics queue:
//   computeQueue->Signal(crossFence, computeValue);
//   graphicsQueue->Wait(crossFence, computeValue);
//
// The GPU graphics queue pauses at Wait until the compute queue has signaled.
// No CPU involvement. GPU-GPU synchronization only.
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_CrossQueueSync
{
    ID3D12Fence* fence    = nullptr;
    UINT64       value    = 0;
};

DRE_CrossQueueSync DRE_CreateCrossQueueSync(ID3D12Device* device)
{
    DRE_CrossQueueSync sync;
    device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&sync.fence));
    return sync;
}

void DRE_SignalFromQueue(DRE_CrossQueueSync& sync, ID3D12CommandQueue* queue)
{
    queue->Signal(sync.fence, ++sync.value);
}

void DRE_WaitOnQueue(const DRE_CrossQueueSync& sync, ID3D12CommandQueue* waitingQueue)
{
    // GPU-side wait. The waiting queue stalls at this point until the fence is signaled.
    waitingQueue->Wait(sync.fence, sync.value);
}
