// Committed resource, driver manages the heap.
D3D12_HEAP_PROPERTIES heapProps = {};
heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;

D3D12_RESOURCE_DESC desc = {};
desc.Dimension          = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
desc.Width              = 2560;
desc.Height             = 1440;
desc.DepthOrArraySize   = 1;
desc.MipLevels          = 1;
desc.Format             = DXGI_FORMAT_R16G16B16A16_FLOAT;
desc.SampleDesc.Count   = 1;
desc.Layout             = D3D12_TEXTURE_LAYOUT_UNKNOWN;
desc.Flags              = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

device->CreateCommittedResource(
    &heapProps, D3D12_HEAP_FLAG_NONE,
    &desc, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
    nullptr, IID_PPV_ARGS(&m_RadianceUAV));