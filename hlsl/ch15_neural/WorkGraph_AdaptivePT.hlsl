/**
 * WorkGraph_AdaptivePT.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 15.4 — Work Graphs
 *
 * GPU-driven adaptive path tracing: high-variance pixels receive extra rays,
 * low-variance pixels skip the secondary ray pass. Zero CPU round-trip.
 *
 * Requires: D3D12 Work Graphs (Agility SDK 1.711+, SM 6.8+)
 * Hardware: RTX 4000+ (Ada) or RX 7000+ (RDNA 3) with updated drivers.
 *
 * CPU-side fallback (1-frame latency, no CPU readback): WorkGraph_FallbackCPP.cpp
 * Compile: dxc -T lib_6_8 -HV 2021 -Fo WorkGraph_AdaptivePT.cso WorkGraph_AdaptivePT.hlsl
 */

#ifndef DRE_WORKGRAPH_ADAPTIVE_PT_HLSL
#define DRE_WORKGRAPH_ADAPTIVE_PT_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// WORK GRAPH NODE TYPES REFERENCE (§ 15.4 Workbench 15.4.A)
// ─────────────────────────────────────────────────────────────────────────────

// Broadcasting: one input record → dispatches a fixed thread grid
//   Use: entry nodes, deterministic-size work
//
// Coalescing: variable input records → one thread group processes all
//   Use: accumulating per-pixel records into one pass
//
// Thread: one input record → one thread (no threadgroup overhead)
//   Use: fine-grained per-record work

// Backing memory sizing:
// ALWAYS allocate MaxSizeInBytes (not MinSizeInBytes).
// The Work Graph scheduler uses backing memory as scratchpad for pending records.
static const uint WG_BACKING_MEMORY_RESERVE = 64 * 1024 * 1024; // 64 MB safe upper bound

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

Texture2D<float4>   g_Radiance         : register(t0); // Current 1-spp output
Texture2D<float4>   g_HistoryRadiance  : register(t1); // Previous frame (denoised)
RWTexture2D<float4> g_AdaptiveOutput   : register(u0); // Final output
RWTexture2D<float>  g_VarianceMap      : register(u1); // Per-pixel variance

cbuffer AdaptivePTConstants : register(b0)
{
    uint   g_FrameIndex;
    uint2  g_Resolution;
    uint   _pad;
    float  g_VarianceThreshold;   // Pixels above this get extra rays (default: 0.05)
    uint   g_MaxExtraRays;         // Max extra SPP per pixel (default: 3)
    uint2  _pad2;
};

// ─────────────────────────────────────────────────────────────────────────────
// RECORD TYPES
// ─────────────────────────────────────────────────────────────────────────────

struct ClassifyRecord
{
    uint2 pixel;
    uint  extraRays; // Number of additional rays to trace (0 = skip)
};

struct RayRecord
{
    uint2 pixel;
    uint  seed;
};

// ─────────────────────────────────────────────────────────────────────────────
// NODE 0: ENTRY — CLASSIFY PIXELS BY VARIANCE
// Broadcasting: dispatches 8×8 threadgroups over the render resolution.
// For each pixel: compute variance, emit a record if extra rays are needed.
// ─────────────────────────────────────────────────────────────────────────────

[NodeLaunch("broadcasting")]
[NodeMaxDispatchGrid(320, 180, 1)]  // Max groups: ceil(2560/8) × ceil(1440/8)
[numthreads(8, 8, 1)]
void ClassifyPixels(
    uint2 threadID : SV_DispatchThreadID,
    [MaxRecords(64)] NodeOutput<RayRecord> ExtraRayOutput)
{
    uint2 pixel = threadID;
    if (any(pixel >= g_Resolution)) return;

    // Compute temporal variance: |current - history|² luminance.
    float3 current  = g_Radiance[pixel].rgb;
    float3 history  = g_HistoryRadiance[pixel].rgb;
    float  lumCurr  = dot(current, float3(0.2126f, 0.7152f, 0.0722f));
    float  lumHist  = dot(history, float3(0.2126f, 0.7152f, 0.0722f));
    float  variance = (lumCurr - lumHist) * (lumCurr - lumHist);

    g_VarianceMap[pixel] = variance;

    // Emit extra ray records for high-variance pixels.
    if (variance > g_VarianceThreshold)
    {
        uint extraRays = min(g_MaxExtraRays, (uint)(variance / g_VarianceThreshold));

        // Emit one record per extra ray for this pixel.
        for (uint r = 0; r < extraRays; ++r)
        {
            ThreadNodeOutputRecords<RayRecord> rec = ExtraRayOutput.GetThreadNodeOutputRecords(1);
            rec.Get().pixel = pixel;
            rec.Get().seed  = (pixel.x * 1973u + pixel.y * 9277u + g_FrameIndex * 26699u + r) | 1u;
            rec.OutputComplete();
        }
    }
    else
    {
        // Low-variance pixel: copy primary output directly.
        g_AdaptiveOutput[pixel] = g_Radiance[pixel];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NODE 1: EXTRA RAY DISPATCH
// Thread launch: one thread per extra ray record.
// Traces an additional path and accumulates with primary output.
// ─────────────────────────────────────────────────────────────────────────────

RaytracingAccelerationStructure g_TLAS : register(t2);

[NodeLaunch("thread")]
void TraceExtraRay([MaxRecords(1)] NodeInput<RayRecord> input)
{
    RayRecord rec = input.Get();
    uint2 pixel   = rec.pixel;
    uint  seed    = rec.seed;

    // Reconstruct world-space ray (simplified: use primary ray direction + jitter).
    // Full implementation: read G-Buffer primary hit, sample new VNDF direction.
    // For brevity: trace a secondary bounce from the primary surface.

    // This node executes only for high-variance pixels.
    // The GPU determined which pixels need extra work — no CPU involvement.
    // Zero latency vs 1–3 frame CPU readback latency (§ 15.4 motivation).

    // Accumulate extra sample into adaptive output.
    // Full path trace implementation omitted: see DRE_Vol2_RT.hlsl PathTrace().
    // The extra ray result is averaged with the primary 1-spp output:
    //   g_AdaptiveOutput[pixel] = (primary + extra) / 2.0f;
    (void)seed; // placeholder until full PathTrace integration
}

// ─────────────────────────────────────────────────────────────────────────────
// CPU FALLBACK: EXECUTIVEINDIRECT-BASED ADAPTIVE DISPATCH (§ 15.4 WB 15.4.B)
// For hardware without Work Graphs. Uses atomic counter + ExecuteIndirect.
// 1-frame latency (vs 0 for Work Graphs, 3 for CPU readback).
// ─────────────────────────────────────────────────────────────────────────────

RWStructuredBuffer<uint>  g_HighVarianceCount : register(u2);
RWStructuredBuffer<uint2> g_HighVarianceList  : register(u3);
RWStructuredBuffer<uint>  g_IndirectArgs      : register(u4);

static const uint MAX_HIGH_VARIANCE_PIXELS = 1024 * 1024;

// Pass 1: classify pixels, append high-variance pixels to a list.
[numthreads(8, 8, 1)]
void CS_ClassifyPixelsFallback(uint2 pixel : SV_DispatchThreadID)
{
    if (any(pixel >= g_Resolution)) return;

    float3 curr    = g_Radiance[pixel].rgb;
    float3 hist    = g_HistoryRadiance[pixel].rgb;
    float  lumC    = dot(curr, float3(0.2126f, 0.7152f, 0.0722f));
    float  lumH    = dot(hist, float3(0.2126f, 0.7152f, 0.0722f));
    float  variance = (lumC - lumH) * (lumC - lumH);

    if (variance > g_VarianceThreshold)
    {
        uint insertIdx;
        InterlockedAdd(g_HighVarianceCount[0], 1, insertIdx);
        if (insertIdx < MAX_HIGH_VARIANCE_PIXELS)
            g_HighVarianceList[insertIdx] = pixel;
    }
}

// Pass 2: build indirect dispatch argument from GPU-computed count.
// CPU never reads the count — no PCIe round-trip.
[numthreads(1, 1, 1)]
void CS_BuildIndirectArgs()
{
    uint count = min(g_HighVarianceCount[0], MAX_HIGH_VARIANCE_PIXELS);
    g_IndirectArgs[0] = (count + 63) / 64; // Dispatch X: ceil(count / 64) groups
    g_IndirectArgs[1] = 1;
    g_IndirectArgs[2] = 1;
    g_HighVarianceCount[0] = 0; // Reset for next frame
}

// Pass 3 (C++ side): cmdList->ExecuteIndirect(m_ComputeCommandSig, 1, g_IndirectArgs, 0, nullptr, 0)
// Then trace extra rays using g_HighVarianceList[].

// ─────────────────────────────────────────────────────────────────────────────
// LATENCY COMPARISON (§ 15.4)
//
//  CPU readback:          3 frames × 16.6ms = 50ms delay
//                         Variance map from 3 frames ago → wrong pixels get extra rays
//                         Fast camera movement → adaptive sampling WORSE than uniform
//
//  ExecuteIndirect:       1 frame latency
//                         No CPU roundtrip. Count is GPU-written, args GPU-built.
//
//  Work Graphs:           0 frame latency
//                         GPU decides how much work to generate on the current frame.
//                         Requires Agility SDK 1.711+ and SM 6.8.
//
// STRUCTURAL BANKRUPTCY: never use CPU readback for adaptive sampling.
// The variance map from 3 frames ago does not represent the current frame.
// Use Work Graphs (0 latency) or ExecuteIndirect (1-frame latency).

#endif // DRE_WORKGRAPH_ADAPTIVE_PT_HLSL
