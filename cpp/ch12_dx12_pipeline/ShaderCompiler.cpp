/**
 * ShaderCompiler.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 12.4 — PSO Compilation and Shader Hot Reload
 *
 * Runtime DXC shader compilation, PSO pipeline library cache,
 * and the deferred release pattern for hot reload.
 * Requires: dxcapi.h, D3D12 Agility SDK 1.600+
 */

#include <d3d12.h>
#include <dxcapi.h>
#include <wrl/client.h>
#include <vector>
#include <string>
#include <fstream>
#include <filesystem>
#include <cassert>

using Microsoft::WRL::ComPtr;

// ─────────────────────────────────────────────────────────────────────────────
// DXC FLAG REFERENCE (§ 12.4 Workbench 12.4.A)
//
// Core flags (always required):
//   -T lib_6_6        RT library target (RTPSO shaders)
//   -T cs_6_6         Compute shader target
//   -HV 2021          HLSL 2021: required for ResourceDescriptorHeap bindless
//   -WX               Warnings as errors: zero-warning shipping standard
//
// Debug build: -Od -Zi -Qembed_debug
// Release build: -O3 -Qstrip_reflect -Qstrip_debug
// ─────────────────────────────────────────────────────────────────────────────

struct DRE_ShaderCompiler
{
    ComPtr<IDxcUtils>     utils;
    ComPtr<IDxcCompiler3> compiler;
    ComPtr<IDxcIncludeHandler> includeHandler;
};

DRE_ShaderCompiler DRE_CreateShaderCompiler()
{
    DRE_ShaderCompiler sc;
    DxcCreateInstance(CLSID_DxcUtils,     IID_PPV_ARGS(&sc.utils));
    DxcCreateInstance(CLSID_DxcCompiler3, IID_PPV_ARGS(&sc.compiler));
    sc.utils->CreateDefaultIncludeHandler(&sc.includeHandler);
    return sc;
}

// Compile an HLSL source file to a DXIL blob.
// Returns nullptr on failure (check errorBlob for details).
ComPtr<IDxcBlob> DRE_CompileShader(
    DRE_ShaderCompiler& sc,
    const std::wstring& filePath,
    const std::wstring& target,      // e.g. L"lib_6_6" or L"cs_6_6"
    const std::wstring& entryPoint,  // L"" for library targets
    const std::vector<std::wstring>& includeDirs,
    bool debug = false)
{
    // Load source file.
    ComPtr<IDxcBlobEncoding> sourceBlob;
    HRESULT hr = sc.utils->LoadFile(filePath.c_str(), nullptr, &sourceBlob);
    if (FAILED(hr)) return nullptr;

    DxcBuffer sourceBuffer = {};
    sourceBuffer.Ptr      = sourceBlob->GetBufferPointer();
    sourceBuffer.Size     = sourceBlob->GetBufferSize();
    sourceBuffer.Encoding = DXC_CP_ACP;

    // Build argument list.
    std::vector<LPCWSTR> args;

    args.push_back(filePath.c_str());
    args.push_back(L"-T");  args.push_back(target.c_str());
    args.push_back(L"-HV"); args.push_back(L"2021");
    args.push_back(L"-WX"); // Warnings as errors

    if (!entryPoint.empty())
    {
        args.push_back(L"-E");
        args.push_back(entryPoint.c_str());
    }

    for (const auto& dir : includeDirs)
    {
        args.push_back(L"-I");
        args.push_back(dir.c_str());
    }

    if (debug)
    {
        args.push_back(L"-Od");           // Disable optimization
        args.push_back(L"-Zi");           // Debug info
        args.push_back(L"-Qembed_debug"); // Embed PDB in binary
    }
    else
    {
        args.push_back(L"-O3");            // Full optimization
        args.push_back(L"-Qstrip_reflect");// Strip reflection (~20% size saving)
        args.push_back(L"-Qstrip_debug");  // Strip debug info
    }

    ComPtr<IDxcResult> result;
    sc.compiler->Compile(&sourceBuffer,
                          args.data(), (UINT32)args.size(),
                          sc.includeHandler.Get(),
                          IID_PPV_ARGS(&result));

    // Check for errors.
    ComPtr<IDxcBlobUtf8> errors;
    result->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(&errors), nullptr);
    if (errors && errors->GetStringLength() > 0)
    {
        // Log: errors->GetStringPointer()
        // Return nullptr for any error (including warnings-as-errors).
        HRESULT status;
        result->GetStatus(&status);
        if (FAILED(status)) return nullptr;
    }

    ComPtr<IDxcBlob> shaderBlob;
    result->GetOutput(DXC_OUT_OBJECT, IID_PPV_ARGS(&shaderBlob), nullptr);
    return shaderBlob;
}

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE LIBRARY CACHE (§ 12.4 Workbench 12.4.B)
// Cold compile: 200–500ms. Cache hit: < 10ms. Invalidated on driver update.
// ─────────────────────────────────────────────────────────────────────────────

static const wchar_t* PIPELINE_CACHE_PATH = L"shader_cache/dre_pipeline_library.bin";

// Write compiled RTPSO to pipeline library cache.
void DRE_CachePSO(ID3D12Device* device, ID3D12StateObject* rtpso,
                   const wchar_t* psoName)
{
    ComPtr<ID3D12PipelineLibrary1> lib;
    device->CreatePipelineLibrary(nullptr, 0, IID_PPV_ARGS(&lib));
    lib->StorePipeline(psoName, rtpso);

    SIZE_T size = lib->GetSerializedSize();
    std::vector<uint8_t> blob(size);
    lib->Serialize(blob.data(), size);

    std::filesystem::create_directories(
        std::filesystem::path(PIPELINE_CACHE_PATH).parent_path());

    std::ofstream f(PIPELINE_CACHE_PATH, std::ios::binary);
    f.write(reinterpret_cast<char*>(blob.data()), (std::streamsize)size);
}

// Load RTPSO from pipeline library cache. Returns nullptr on cache miss.
ID3D12StateObject* DRE_LoadCachedPSO(
    ID3D12Device* device,
    const D3D12_STATE_OBJECT_DESC& stateObjectDesc,
    const wchar_t* psoName)
{
    std::ifstream f(PIPELINE_CACHE_PATH, std::ios::binary | std::ios::ate);
    if (!f.is_open()) return nullptr; // No cache yet.

    SIZE_T size = (SIZE_T)f.tellg();
    f.seekg(0);
    std::vector<uint8_t> blob(size);
    f.read(reinterpret_cast<char*>(blob.data()), (std::streamsize)size);

    ComPtr<ID3D12PipelineLibrary1> lib;
    HRESULT hr = device->CreatePipelineLibrary(blob.data(), size, IID_PPV_ARGS(&lib));
    if (FAILED(hr))
    {
        // Cache corrupt or from an older format.
        std::filesystem::remove(PIPELINE_CACHE_PATH);
        return nullptr;
    }

    ID3D12StateObject* rtpso = nullptr;
    hr = lib->LoadRaytracingPipeline(psoName, &stateObjectDesc, IID_PPV_ARGS(&rtpso));

    if (hr == E_INVALIDARG)
    {
        // Cache incompatible: new GPU driver invalidated it. Delete and recompile.
        std::filesystem::remove(PIPELINE_CACHE_PATH);
        return nullptr;
    }

    return SUCCEEDED(hr) ? rtpso : nullptr;
}

// ─────────────────────────────────────────────────────────────────────────────
// HOT RELOAD PATTERN: DEFERRED RELEASE (§ 12.4)
// Never destroy a PSO while the GPU is still using it.
// Queue for deferred release after FRAMES_IN_FLIGHT frames.
// ─────────────────────────────────────────────────────────────────────────────

static const UINT DEFERRED_RELEASE_FRAMES = 3; // = FRAMES_IN_FLIGHT

struct DeferredRelease
{
    ID3D12StateObject* rtpso      = nullptr;
    UINT64             frameToFree = 0;
};

static std::vector<DeferredRelease> g_DeferredReleases;
static UINT64                        g_CurrentFrame = 0;

void DRE_QueueDeferredRelease(ID3D12StateObject* oldPSO)
{
    g_DeferredReleases.push_back({ oldPSO, g_CurrentFrame + DEFERRED_RELEASE_FRAMES });
}

// Call once per frame with the completed fence value.
void DRE_ProcessDeferredReleases(UINT64 completedFenceValue)
{
    for (auto it = g_DeferredReleases.begin(); it != g_DeferredReleases.end(); )
    {
        if (completedFenceValue >= it->frameToFree)
        {
            it->rtpso->Release();
            it = g_DeferredReleases.erase(it);
        }
        else
        {
            ++it;
        }
    }
    ++g_CurrentFrame;
}
