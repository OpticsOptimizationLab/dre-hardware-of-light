// Create the Gaussian buffer as a StructuredBuffer (NOT ByteAddressBuffer).
// StructuredBuffer allows indexed access by struct type in HLSL.

UINT64 bufferSize = numGaussians * sizeof(Gaussian3D_RT);

D3D12_RESOURCE_DESC bufferDesc = {};
bufferDesc.Dimension          = D3D12_RESOURCE_DIMENSION_BUFFER;
bufferDesc.Width              = bufferSize;
bufferDesc.Height             = 1;
bufferDesc.DepthOrArraySize   = 1;
bufferDesc.MipLevels          = 1;
bufferDesc.Format             = DXGI_FORMAT_UNKNOWN;
bufferDesc.SampleDesc.Count   = 1;
bufferDesc.Layout             = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
bufferDesc.Flags              = D3D12_RESOURCE_FLAG_NONE; // Read-only at render time

// Create SRV for bindless access.
D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
srvDesc.ViewDimension              = D3D12_SRV_DIMENSION_BUFFER;
srvDesc.Format                     = DXGI_FORMAT_UNKNOWN;
srvDesc.Buffer.FirstElement        = 0;
srvDesc.Buffer.NumElements         = numGaussians;
srvDesc.Buffer.StructureByteStride = sizeof(Gaussian3D_RT);
srvDesc.Buffer.Flags               = D3D12_BUFFER_SRV_FLAG_NONE;
srvDesc.Shader4ComponentMapping    = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;

device->CreateShaderResourceView(gaussianBuffer, &srvDesc,
    m_DescriptorHeap->GetCPUDescriptorHandleForHeapStart()
    + SLOT_GAUSSIANS * descriptorSize); // Use bindless slot from descriptor heap