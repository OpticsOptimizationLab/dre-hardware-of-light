# Digital Rendering Engineering: The Hardware of Light
## Companion Code — Validated HLSL Implementations

**github.com/OpticsOptimizationLab/dre-hardware-of-light**

Companion repository for **Digital Rendering Engineering: The Hardware of Light** (Vol. 2) by JM Sage.
All HLSL targets Shader Model 6.6. All implementations require Vol. 1 companion code as dependency.

---

## Quick Start

```hlsl
// Include Vol. 1 first (physics & BRDF functions)
#include "deps/dre-physics-of-light/DRE_Vol1_Complete.hlsl"

// Include Vol. 2 (GPU execution layer)
#include "DRE_Vol2_Complete.hlsl"

// Wave divergence diagnosis (Ch. 11)
float divergence = GetWaveDivergenceFactor();

// ReSTIR reservoir (Ch. 14)
DRE_Reservoir r = DRE_CreateReservoir();
DRE_UpdateReservoir(r, lightIndex, weight, seed);
DRE_FinalizeReservoir(r, p_hat);

// SVGF edge weight (Ch. 14)
float w = SVGF_EdgeWeight(lumC, lumS, variance, nDot, depthRatio, 10.0f, 128.0f, 1.0f);
```

---

## Repository Structure

```
DRE_Vol2_Complete.hlsl              <- Single assembly file (Ch. 11–15 utilities)
                                       Requires: DRE_Vol1_Complete.hlsl

hlsl/
├── ch11_gpu_architecture/
│   ├── DiagnoseDivergence.hlsl     <- Wave divergence measurement (WaveActiveBallot)
│   ├── OccupancyEstimator.hlsl     <- Ampere/RDNA 3 occupancy formula + register budget
│   └── CoalescingTest.hlsl         <- 128-byte cache line contract + shared memory demo
│
├── ch12_dx12_pipeline/
│   ├── RenderGraph.hlsl            <- Frame resource declarations, fullscreen VS
│   ├── BindlessRT.hlsl             <- SM 6.6 bindless ClosestHit (ResourceDescriptorHeap)
│   └── GBuffer.hlsl                <- G-Buffer layout constants + SurfaceHit unpack
│
├── ch13_ray_tracing/
│   ├── DRE_RayGen.hlsl             <- Ray generation shader — dispatches PathTrace()
│   ├── DRE_ClosestHit.hlsl         <- Closest-hit material shader
│   ├── DRE_Miss.hlsl               <- Miss shader — environment + shadow
│   └── InlineRayTracing.hlsl       <- RayQuery shadow + AO compute (no RTPSO needed)
│
├── ch14_realtime_pt/
│   ├── ReSTIR_DI.hlsl              <- ReSTIR DI: 3-pass (initial + temporal + spatial)
│   ├── ReSTIR_GI.hlsl              <- ReSTIR GI: 1-bounce indirect + temporal reuse
│   ├── SVGF_Denoiser.hlsl          <- SVGF: temporal accumulation + à-trous filter
│   ├── WRC.hlsl                    <- World Radiance Cache: hash grid update + query
│   ├── VolumeMarcher.hlsl          <- Beer-Lambert marcher + adaptive step + NanoVDB
│   ├── Transparency.hlsl           <- Alpha test, glass/refraction, stochastic alpha
│   └── DLSS_RR_Integration.cpp     <- NGX init + DLSS RR feature + evaluation + checklist
│
└── ch15_neural/
    ├── GaussianSplatting.hlsl      <- 3DGS projection + tile classification + rasterizer
    ├── GaussianSorting.hlsl        <- GPU radix sort for Gaussian depth ordering
    ├── NRC_Query.hlsl              <- NRC inference: hash grid encoding + MLP forward
    ├── SER.hlsl                    <- Shader Execution Reordering (Ada) + WaveMatch fallback
    └── WorkGraph_AdaptivePT.hlsl   <- Work Graph adaptive SPP + ExecuteIndirect fallback

cpp/
├── ch12_dx12_pipeline/
│   ├── DX12CommandQueue.cpp        <- 3-queue setup + N=3 frames-in-flight fence pattern
│   ├── DX12ResourceManager.cpp     <- Heap types, committed resources, VRAM budget ref
│   ├── DX12DescriptorManager.cpp   <- Bindless heap + root signature (65536-slot heap)
│   └── ShaderCompiler.cpp          <- DXC runtime compile + PSO cache + hot reload
│
└── ch13_ray_tracing/
    ├── AccelerationStructureManager.cpp  <- BLAS build/refit + TLAS build per frame
    ├── RTPipelineState.cpp               <- RTPSO: subobjects, hit groups, payload config
    └── ShaderBindingTable.cpp            <- SBT builder for N materials × R ray types

python/
└── ch15_neural/
    └── NRC_Training.py             <- PyTorch NRC prototype (offline param exploration)

validation/
└── white_furnace_dxr.py            <- DXR pipeline White Furnace Test (45 configs)
```

---

## Vol. 1 Dependency (Git Submodule)

Vol. 1 companion code is included as a git submodule at `deps/dre-physics-of-light/`.

Clone with submodule in one step:
```bash
git clone --recurse-submodules https://github.com/OpticsOptimizationLab/dre-hardware-of-light.git
```

Or initialize after cloning:
```bash
git submodule update --init --recursive
```

---

## Dependency: Vol. 1 Companion Code

This repository extends Vol. 1. The following functions are called from Vol. 2 shaders
and must be available from `DRE_Vol1_Complete.hlsl`:

| Function | Chapter (Vol. 1) | Used in Vol. 2 |
|---|---|---|
| `EvaluateCookTorrance()` | Ch. 6 | `DRE_ClosestHit.hlsl` |
| `SampleVNDF()` | Ch. 9.2 | `DRE_ClosestHit.hlsl` |
| `VNDF_PDF()` | Ch. 9.2 | `DRE_ClosestHit.hlsl` |
| `OffsetRayOrigin()` | Ch. 7 | `DRE_ClosestHit.hlsl` |
| `PathTrace()` | Ch. 7.4.1 | `DRE_RayGen.hlsl` |

```
github.com/OpticsOptimizationLab/dre-physics-of-light
```

---

## Hardware Requirements

| Target | Minimum | Tested on |
|---|---|---|
| NVIDIA | RTX 2060 (Turing) | RTX 4090 (Ada) |
| AMD | RX 6700 (RDNA 2) | RX 7900 XTX (RDNA 3) |
| API | D3D12 with DXR 1.1 | Windows 11, D3D12 Agility SDK 1.614 |
| Compiler | DXC 1.7+ | DXC 1.8 |
| Shader Model | SM 6.6 | SM 6.6 |

---

## Compilation

```bash
# Compile ray generation shader
dxc -T lib_6_6 -Fo DRE_RayGen.dxil hlsl/ch13_ray_tracing/DRE_RayGen.hlsl

# Compile compute shaders
dxc -T cs_6_6 -E CS_InitialCandidates -Fo ReSTIR_Init.dxil hlsl/ch14_realtime_pt/ReSTIR_DI.hlsl
dxc -T cs_6_6 -E CS_TemporalAccumulate -Fo SVGF_Temporal.dxil hlsl/ch14_realtime_pt/SVGF_Denoiser.hlsl
dxc -T cs_6_6 -E CS_AtrousFilter -Fo SVGF_Atrous.dxil hlsl/ch14_realtime_pt/SVGF_Denoiser.hlsl

# Or use the CMake build (Ch. 16.4)
cmake -B build -DDRE_VOL1_PATH=deps/dre-physics-of-light
cmake --build build
```

---

## Frame Budget Reference (Ch. 14.1)

| Pass | Shader | Budget |
|---|---|---|
| G-Buffer rasterization | Raster PS | ~2.0ms |
| BLAS refit (async compute) | Compute | ~0.5ms |
| Shadow rasterization | Raster PS | ~1.5ms |
| TLAS build | D3D12 API | ~0.3ms |
| ReSTIR DI candidates | CS_InitialCandidates | ~1.8ms |
| ReSTIR temporal reuse | CS_TemporalReuse | ~0.8ms |
| ReSTIR spatial reuse | CS_SpatialReuse | ~1.2ms |
| Path tracing (DXR) | DRE_RayGen | ~4.0ms |
| SVGF temporal accumulation | CS_TemporalAccumulate | ~0.5ms |
| SVGF a-trous x4 | CS_AtrousFilter | ~2.0ms |
| TAA + tone map | FullscreenVS/PS | ~0.5ms |
| **Total** | | **~15.1ms** |

---

**Series:** Digital Rendering Engineering
**Vol. 1 repo:** github.com/OpticsOptimizationLab/dre-physics-of-light
**Publisher:** Optics Optimization Laboratory
