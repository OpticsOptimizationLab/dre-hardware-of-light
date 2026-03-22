// Create the three queues.
D3D12_COMMAND_QUEUE_DESC desc = {};

desc.Type     = D3D12_COMMAND_LIST_TYPE_DIRECT;
desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_HIGH;
desc.Flags    = D3D12_COMMAND_QUEUE_FLAG_NONE;
device->CreateCommandQueue(&desc, IID_PPV_ARGS(&m_GraphicsQueue));

desc.Type     = D3D12_COMMAND_LIST_TYPE_COMPUTE;
desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
device->CreateCommandQueue(&desc, IID_PPV_ARGS(&m_ComputeQueue));

desc.Type     = D3D12_COMMAND_LIST_TYPE_COPY;
desc.Priority = D3D12_COMMAND_QUEUE_PRIORITY_NORMAL;
device->CreateCommandQueue(&desc, IID_PPV_ARGS(&m_CopyQueue));