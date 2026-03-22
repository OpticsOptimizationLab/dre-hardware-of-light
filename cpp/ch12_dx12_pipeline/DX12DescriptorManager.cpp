// Root signature for DRE PathTrace shader.
// Slots:
//   b0: Camera CBV (inline, 64-byte limit, but camera data is small)
//   b1: Frame constants CBV (inline)
//   t0: TLAS SRV (inline descriptor, AS requires special binding)
//   u0: Output UAV (inline)
//   Descriptor table: G-Buffer SRVs (t1-t4), material buffer (t5),
//                     bindless texture array (t6, unbounded)

D3D12_ROOT_PARAMETER1 params[5] = {};

// [0] Camera CBV, root CBV descriptor (2 DWORDs — a GPU virtual address).
// For inline constants, use D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS instead.
params[0].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_CBV;
params[0].Descriptor.ShaderRegister = 0; // b0
params[0].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

// [1] Frame constants CBV
params[1].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_CBV;
params[1].Descriptor.ShaderRegister = 1; // b1
params[1].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

// [2] TLAS SRV, inline descriptor (AS requires this)
params[2].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_SRV;
params[2].Descriptor.ShaderRegister = 0; // t0
params[2].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

// [3] Output UAV, inline descriptor
params[3].ParameterType             = D3D12_ROOT_PARAMETER_TYPE_UAV;
params[3].Descriptor.ShaderRegister = 0; // u0
params[3].ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;

// [4] Descriptor table: G-Buffer + materials + bindless textures
D3D12_DESCRIPTOR_RANGE1 ranges[3] = {};

// G-Buffer SRVs: t1–t4
ranges[0].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
ranges[0].NumDescriptors                    = 4;
ranges[0].BaseShaderRegister                = 1; // t1
ranges[0].RegisterSpace                     = 0;
ranges[0].OffsetInDescriptorsFromTableStart = 0;

// Material StructuredBuffer: t5
ranges[1].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
ranges[1].NumDescriptors                    = 1;
ranges[1].BaseShaderRegister                = 5; // t5
ranges[1].OffsetInDescriptorsFromTableStart = 4;

// Bindless texture array: t6, unbounded
ranges[2].RangeType                         = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
ranges[2].NumDescriptors                    = UINT_MAX; // Unbounded, bindless
ranges[2].BaseShaderRegister                = 6;        // t6
ranges[2].RegisterSpace                     = 0;
ranges[2].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_DESCRIPTORS_VOLATILE
                | D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;
ranges[2].OffsetInDescriptorsFromTableStart = 5;

params[4].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
params[4].DescriptorTable.NumDescriptorRanges = 3;
params[4].DescriptorTable.pDescriptorRanges   = ranges;
params[4].ShaderVisibility                    = D3D12_SHADER_VISIBILITY_ALL;