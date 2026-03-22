// 1. Download NVAPI SDK from developer.nvidia.com/nvapi
//    Required headers: nvHLSLExtns.h, nvShaderExtnEnums.h

// 2. Root signature: reserve one UAV slot for NvAPI.
//    The extension mechanism uses a UAV at a well-known slot.
//    Any slot from u0–u63 can be used. DRE uses u63 (least likely to conflict).
D3D12_ROOT_PARAMETER1 nvSlotParam = {};
nvSlotParam.ParameterType             = D3D12_ROOT_PARAMETER_TYPE_UAV;
nvSlotParam.Descriptor.ShaderRegister = 63;  // u63, must match NvShaderExtnSlot in HLSL
nvSlotParam.Descriptor.RegisterSpace  = 0;
nvSlotParam.ShaderVisibility          = D3D12_SHADER_VISIBILITY_ALL;
// Add this parameter to the root signature alongside the existing DRE parameters.

// 3. DXC compile flags for SER shaders:
// dxc -T lib_6_6 -HV 2021 -I [nvapi_sdk_path] -Fo DRE_Vol2_RT_SER.cso DRE_Vol2_RT_SER.hlsl
// The -I path must resolve nvHLSLExtns.h.