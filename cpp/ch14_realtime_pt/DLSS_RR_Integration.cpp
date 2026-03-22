/**
 * DLSS_RR_Integration.cpp
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 14.6 — The Denoising Pipeline
 *
 * DLSS Ray Reconstruction (DLSS RR) integration with DX12.
 * DLSS RR denoises + upscales 1-spp path traced output using neural reconstruction.
 * Requires: NVIDIA NGX SDK + RTX hardware.
 * Fallback: SVGF (open-source, SVGF_Denoiser.hlsl) for non-RTX hardware.
 *
 * Key difference from DLSS Super Resolution:
 *   DLSS SR: upscales a rasterized image.
 *   DLSS RR: denoises + upscales 1-spp path traced radiance with separate
 *            diffuse/specular inputs for higher quality reconstruction.
 *
 * Requires: NVIDIA NGX SDK headers + runtime DLLs.
 * Download: developer.nvidia.com/rtx/ngx → SDK download.
 * Required files: nvsdk_ngx.h, nvsdk_ngx_helpers.h, nvngx_dlss.dll (runtime)
 */

#include <d3d12.h>
#include <wrl/client.h>
#include <vector>
#include <cassert>
#include <stdexcept>

// NGX SDK headers (download from developer.nvidia.com/rtx/ngx)
// #include <nvsdk_ngx.h>
// #include <nvsdk_ngx_helpers.h>

using Microsoft::WRL::ComPtr;

// ─────────────────────────────────────────────────────────────────────────────
// DLSS RR CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────────

struct DLSSRRConfig
{
    UINT renderWidth;       // Input resolution (1-spp path traced output)
    UINT renderHeight;
    UINT outputWidth;       // Display resolution (after upscale)
    UINT outputHeight;
    bool enableMotionVectors; // true for temporal stability
    bool resetAccumulation;   // true on scene cut or major camera change
};

// DLSS quality modes (input resolution as fraction of output):
//   Ultra Performance: 0.33× (render at 1/3, display at 4K)
//   Performance:       0.50×
//   Balanced:          0.58×
//   Quality:           0.67×
//   Native AA:         1.00× (no upscaling, denoising only)
//
// For real-time path tracing at 1440p: Quality mode (960×540 → 2560×1440)
// reduces ray count to 25% of native, DLSS RR reconstructs to full resolution.

// ─────────────────────────────────────────────────────────────────────────────
// DLSS RR MANAGER
// ─────────────────────────────────────────────────────────────────────────────

class DLSSRRManager
{
public:
    // ── Lifecycle ────────────────────────────────────────────────────────────

    bool Initialize(ID3D12Device* device,
                    ID3D12CommandQueue* graphicsQueue,
                    const wchar_t* logDirectory = L"./ngx_logs/")
    {
        m_device = device;

        // NGX initialization.
        // App GUID: generate a unique GUID per application. This identifies your
        // app to NVIDIA telemetry and enables driver-side optimizations.
        // Use guidgen.exe or https://www.guidgenerator.com/.
        // For DRE prototype: use the placeholder below and replace before shipping.
        static const GUID appGUID = {
            0xDRE0DRE0, 0xDRE0, 0xDRE0,
            { 0xDR, 0xE0, 0xDR, 0xE0, 0xDR, 0xE0, 0xDR, 0xE0 }
        };

        // In production, replace with:
        // NVSDK_NGX_Result result = NVSDK_NGX_D3D12_Init(appGUID, logDirectory, device);
        // if (NVSDK_NGX_FAILED(result)) return false;

        // Check DLSS RR support.
        // NVSDK_NGX_Parameter* params = nullptr;
        // NVSDK_NGX_D3D12_GetCapabilityParameters(&params);
        // int rr_supported = 0;
        // params->Get(NVSDK_NGX_Parameter_RayReconstruction_Available, &rr_supported);
        // if (!rr_supported) { FallbackToSVGF(); return false; }

        m_initialized = true;
        return true;
    }

    // ── Feature Creation ─────────────────────────────────────────────────────
    // Call once at startup (or when resolution changes).
    // Command list must be in a recording state.

    bool CreateFeature(ID3D12GraphicsCommandList* cmdList,
                       const DLSSRRConfig& config)
    {
        if (!m_initialized) return false;

        // Release previous feature if exists (resolution change).
        if (m_feature)
        {
            // NVSDK_NGX_D3D12_ReleaseFeature(m_feature);
            m_feature = nullptr;
        }

        m_config = config;

        // DLSS RR feature creation parameters.
        // In production:
        //
        // NVSDK_NGX_Parameter* createParams = nullptr;
        // NVSDK_NGX_D3D12_AllocateParameters(&createParams);
        //
        // createParams->Set(NVSDK_NGX_Parameter_Width,  config.renderWidth);
        // createParams->Set(NVSDK_NGX_Parameter_Height, config.renderHeight);
        // createParams->Set(NVSDK_NGX_Parameter_OutWidth,  config.outputWidth);
        // createParams->Set(NVSDK_NGX_Parameter_OutHeight, config.outputHeight);
        //
        // Enable diffuse/specular separation — CRITICAL for DLSS RR.
        // Without separate inputs, DLSS RR falls back to combined mode
        // with lower quality. Specular reconstruction benefits most.
        // createParams->Set(NVSDK_NGX_Parameter_RayReconstruction_Diffuse_Input,  1);
        // createParams->Set(NVSDK_NGX_Parameter_RayReconstruction_Specular_Input, 1);
        //
        // Motion vectors in pixel space (NOT NDC — a common integration failure).
        // createParams->Set(NVSDK_NGX_Parameter_MV_Scale_X, 1.0f);  // 1.0 = pixel space
        // createParams->Set(NVSDK_NGX_Parameter_MV_Scale_Y, 1.0f);
        //
        // Depth: use reversed-Z (1 = near, 0 = far) for better precision at distance.
        // createParams->Set(NVSDK_NGX_Parameter_Depth_Inverted, 1);
        //
        // NVSDK_NGX_D3D12_CreateFeature(cmdList,
        //     NVSDK_NGX_Feature_RayReconstruction, createParams, &m_feature);
        // NVSDK_NGX_D3D12_DestroyParameters(createParams);

        return true;
    }

    // ── Per-Frame Evaluation ─────────────────────────────────────────────────
    // Call once per frame after path tracing, before post-processing.

    bool Evaluate(
        ID3D12GraphicsCommandList* cmdList,
        // --- Path traced inputs (render resolution) ---
        ID3D12Resource* diffuseRadiance,    // RGB: diffuse component only (1-spp, noisy)
        ID3D12Resource* specularRadiance,   // RGB: specular component only (1-spp, noisy)
        // --- G-Buffer inputs (render resolution) ---
        ID3D12Resource* motionVectors,      // RG: pixel-space motion vectors
        ID3D12Resource* depth,              // R32: linear depth (NOT projected D32_FLOAT)
        ID3D12Resource* normals,            // RGB: world-space normals
        ID3D12Resource* roughness,          // R: perceptual roughness
        // --- Output (display resolution) ---
        ID3D12Resource* denoisedOutput,     // RGBA: denoised + upscaled combined output
        bool resetAccumulation = false)
    {
        if (!m_initialized || !m_feature) return false;

        // RESOURCE STATE REQUIREMENTS (must be transitioned before Evaluate):
        //   diffuseRadiance:  D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   specularRadiance: D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   motionVectors:    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   depth:            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   normals:          D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   roughness:        D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        //   denoisedOutput:   D3D12_RESOURCE_STATE_UNORDERED_ACCESS
        //
        // Failing to transition any of these produces undefined output.
        // The NGX runtime does not validate state at evaluation time — it will
        // silently read garbage if the resource is in the wrong state.
        // Symptom: black output, temporal flickering, or driver crash on exit.

        // In production:
        //
        // NVSDK_NGX_Parameter* evalParams = nullptr;
        // NVSDK_NGX_D3D12_AllocateParameters(&evalParams);
        //
        // evalParams->Set(NVSDK_NGX_Parameter_Color,         diffuseRadiance);
        // evalParams->Set(NVSDK_NGX_Parameter_Specular,      specularRadiance);
        // evalParams->Set(NVSDK_NGX_Parameter_MotionVectors, motionVectors);
        // evalParams->Set(NVSDK_NGX_Parameter_Depth,         depth);
        // evalParams->Set(NVSDK_NGX_Parameter_Normal,        normals);
        // evalParams->Set(NVSDK_NGX_Parameter_Roughness,     roughness);
        // evalParams->Set(NVSDK_NGX_Parameter_Output,        denoisedOutput);
        // evalParams->Set(NVSDK_NGX_Parameter_Reset,         resetAccumulation ? 1 : 0);
        //
        // NVSDK_NGX_D3D12_EvaluateFeature(cmdList, m_feature, evalParams);
        // NVSDK_NGX_D3D12_DestroyParameters(evalParams);

        return true;
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────

    void Shutdown()
    {
        if (m_feature)
        {
            // NVSDK_NGX_D3D12_ReleaseFeature(m_feature);
            m_feature = nullptr;
        }
        if (m_initialized)
        {
            // NVSDK_NGX_D3D12_Shutdown();
            m_initialized = false;
        }
    }

    ~DLSSRRManager() { Shutdown(); }

private:
    ID3D12Device*  m_device      = nullptr;
    void*          m_feature     = nullptr; // NVSDK_NGX_Handle*
    DLSSRRConfig   m_config      = {};
    bool           m_initialized = false;
};

// ─────────────────────────────────────────────────────────────────────────────
// DENOISER FALLBACK HIERARCHY
// Production: select denoiser at runtime based on hardware support.
// ─────────────────────────────────────────────────────────────────────────────

enum class DenoisingMode
{
    DLSS_RR,    // RTX GPU + NGX runtime: neural denoising + upscaling
    NRD,        // NVIDIA Realtime Denoisers (closed source, RTX 20xx+)
    SVGF,       // Open: spatiotemporal variance-guided filtering
};

DenoisingMode SelectDenoiser(ID3D12Device* device)
{
    // Check DLSS RR availability.
    // Requires: RTX 20xx or newer + NGX runtime installed.
    //
    // In production:
    // NVSDK_NGX_Parameter* caps = nullptr;
    // NVSDK_NGX_D3D12_GetCapabilityParameters(&caps);
    // int rr_available = 0;
    // caps->Get(NVSDK_NGX_Parameter_RayReconstruction_Available, &rr_available);
    // if (rr_available) return DenoisingMode::DLSS_RR;
    //
    // Check NRD availability.
    // NRD works on any DX12 GPU with SM 6.0+.
    // For simplicity: use SVGF as universal fallback.
    // In a shipped title: integrate NRD SDK as intermediate quality tier.

    return DenoisingMode::SVGF; // Conservative default until NGX is linked.
}

// ─────────────────────────────────────────────────────────────────────────────
// INTEGRATION CHECKLIST (§ 14.6 — The Denoising Pipeline)
//
// Before calling Evaluate(), verify:
//
//  [ ] NVSDK_NGX_D3D12_Init() called at startup.
//  [ ] CreateFeature() called after swapchain/resolution is known.
//  [ ] diffuseRadiance and specularRadiance are SEPARATE RT outputs.
//      Path tracer must split contributions — not sum them — before passing to RR.
//      DLSS RR reconstructs specular differently (glossy surfaces benefit most).
//  [ ] motionVectors in PIXEL SPACE (not NDC).
//      NDC motion vectors cause temporal flickering. Scale by (render_width, render_height).
//  [ ] depth is LINEAR (not projected D32_FLOAT).
//      Projected depth causes incorrect disocclusion detection.
//  [ ] resetAccumulation = true on scene cut, teleport, or lighting change > threshold.
//      Missing reset causes one-frame "ghost scene" artifact visible for ~10 frames.
//  [ ] Release feature BEFORE destroying command queue (common exit-path crash).
//  [ ] NVSDK_NGX_D3D12_Shutdown() called before ID3D12Device Release().
//
// Each unmet condition produces a distinct artifact (§ 14.6 NGX Mandate table).
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// DIFFUSE / SPECULAR SEPARATION IN PATHTRACE (§ 14.6)
// The path tracer must route contributions to separate output UAVs.
// Without separation, DLSS RR operates in combined mode (lower quality).
// ─────────────────────────────────────────────────────────────────────────────

// HLSL: split output (add to DRE_Vol2_RT.hlsl PathTrace dispatch):
//
// RWTexture2D<float4> g_DiffuseOutput  : register(u1);
// RWTexture2D<float4> g_SpecularOutput : register(u2);
//
// In ClosestHit, after BRDF evaluation:
//   float3 diffuse  = albedo * EvaluateDiffuseBRDF(wo, wi, hit.normal);
//   float3 specular = EvaluateSpecularBRDF(wo, wi, hit.normal, roughness, metallic);
//
//   g_DiffuseOutput[pixel]  = float4(throughput * diffuse,  1.0f);
//   g_SpecularOutput[pixel] = float4(throughput * specular, 1.0f);
//
// Combined output (for SVGF fallback):
//   g_Radiance[pixel] = float4(throughput * (diffuse + specular), 1.0f);
