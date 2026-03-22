// Compile all RT shaders into one library.
// dxc -T lib_6_6 -Fo DRE_Vol2_RT.cso DRE_Vol2_RT.hlsl

D3D12_DXIL_LIBRARY_DESC dxilLib = {};
dxilLib.DXILLibrary.pShaderBytecode = compiledBlob->GetBufferPointer();
dxilLib.DXILLibrary.BytecodeLength  = compiledBlob->GetBufferSize();
// Export all entry points (nullptr = export everything in the library).
dxilLib.NumExports = 0;
dxilLib.pExports   = nullptr;