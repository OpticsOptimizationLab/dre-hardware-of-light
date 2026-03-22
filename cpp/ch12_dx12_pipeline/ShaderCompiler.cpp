// Initialize DXC once at startup.
IDxcUtils*     dxcUtils    = nullptr;
IDxcCompiler3* dxcCompiler = nullptr;

DxcCreateInstance(CLSID_DxcUtils,     IID_PPV_ARGS(&dxcUtils));
DxcCreateInstance(CLSID_DxcCompiler3, IID_PPV_ARGS(&dxcCompiler));

// Compile a shader at runtime.
IDxcBlob* CompileShader(
    const wchar_t* sourcePath,
    const wchar_t* entryPoint, // L"" for library shaders (lib_6_6)
    const wchar_t* target)     // L"lib_6_6", L"cs_6_6", etc.
{
    // Load source file.
    IDxcBlobEncoding* sourceBlob = nullptr;
    dxcUtils->LoadFile(sourcePath, nullptr, &sourceBlob);

    DxcBuffer sourceBuffer = {};
    sourceBuffer.Ptr      = sourceBlob->GetBufferPointer();
    sourceBuffer.Size     = sourceBlob->GetBufferSize();
    sourceBuffer.Encoding = DXC_CP_UTF8;

    // Compiler arguments.
    std::vector<LPCWSTR> args;
    args.push_back(sourcePath);
    args.push_back(L"-T"); args.push_back(target);          // Target profile
    args.push_back(L"-HV"); args.push_back(L"2021");        // HLSL 2021 (bindless)
    args.push_back(L"-I"); args.push_back(L"../shaders/");  // Include path
    args.push_back(L"-I"); args.push_back(DRE_VOL1_PATH);   // Vol.1 includes

#ifdef _DEBUG
    args.push_back(L"-Od");  // Disable optimization (faster compile, debuggable)
    args.push_back(L"-Zi");  // Embed debug info (for PIX/NSight shader debugging)
    args.push_back(L"-Qembed_debug"); // Embed PDB in shader
#else
    args.push_back(L"-O3");  // Full optimization
    args.push_back(L"-Qstrip_reflect"); // Strip reflection data (smaller binary)
    args.push_back(L"-Qstrip_debug");   // Strip debug info
#endif

    IDxcResult* result = nullptr;
    dxcCompiler->Compile(
        &sourceBuffer,
        args.data(), (UINT32)args.size(),
        nullptr, // No include handler (resolved via -I paths)
        IID_PPV_ARGS(&result));

    // Check for errors.
    IDxcBlobUtf8* errors = nullptr;
    result->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(&errors), nullptr);
    if (errors && errors->GetStringLength() > 0)
    {
        OutputDebugStringA(errors->GetString());
        // Return nullptr, caller checks for null and falls back.
        return nullptr;
    }

    IDxcBlob* shaderBinary = nullptr;
    result->GetOutput(DXC_OUT_OBJECT, IID_PPV_ARGS(&shaderBinary), nullptr);
    return shaderBinary;
}