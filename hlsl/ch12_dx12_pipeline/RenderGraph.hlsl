// Step 1: CPU sets up the indirect argument buffer.
// Dispatch size is initially 1 ray per pixel.
D3D12_DISPATCH_RAYS_DESC initDispatch = {};
initDispatch.Width  = renderWidth;
initDispatch.Height = renderHeight;
initDispatch.Depth  = 1;

// The GPU will write to this buffer to modify the dispatch dimensions.
// This buffer lives in DEFAULT heap, GPU writes, GPU reads, no CPU involvement.
ID3D12Resource* indirectArgBuffer = CreateBuffer(
    sizeof(D3D12_DISPATCH_RAYS_DESC),
    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);

// Step 2: A compute shader (Variance Analysis Pass) classifies pixels.
// High-variance pixels get 2 rays. Low-variance get 0 (skip).
// The compute shader writes the modified dispatch desc to indirectArgBuffer.

// Step 3: DispatchRays via ExecuteIndirect.
commandList->ExecuteIndirect(
    m_DispatchRaysCommandSignature, // Command signature for DispatchRays
    1,                              // Max commands
    indirectArgBuffer,              // GPU-written argument buffer
    0,                              // Argument offset
    nullptr,                        // No count buffer (always execute 1)
    0);