/**
 * RenderGraph.hlsl
 * DRE Vol. 2 — Chapter 12.5: Render Graph Architecture
 *
 * HLSL side of the render graph — shader resources declared
 * to match the D3D12 resource barrier transitions managed
 * by the render graph on the CPU side.
 *
 * Frame sequence (16.6ms budget):
 *   Pass 1: G-Buffer rasterization      ~2.0ms
 *   Pass 2: BLAS refit (async compute)  ~0.5ms  [overlaps with shadow pass]
 *   Pass 3: Shadow rasterization        ~1.5ms
 *   Pass 4: TLAS build                  ~0.3ms
 *   Pass 5: ReSTIR DI candidates        ~1.8ms
 *   Pass 6: ReSTIR temporal reuse       ~0.8ms
 *   Pass 7: ReSTIR spatial reuse        ~1.2ms
 *   Pass 8: Path tracing (primary rays) ~4.0ms
 *   Pass 9: SVGF temporal accum         ~0.5ms
 *   Pass 10: SVGF à-trous x4           ~2.0ms
 *   Pass 11: TAA + tone map             ~0.5ms
 *   ────────────────────────────────────────────
 *   Total                               ~15.1ms  (1.5ms headroom)
 */

// G-Buffer outputs (Pass 1 writes, Pass 5+ reads)
Texture2D<float4>   g_GBuffer_Albedo    : register(t0);   // UAV→SRV barrier before Pass 5
Texture2D<float4>   g_GBuffer_Normal    : register(t1);
Texture2D<float2>   g_GBuffer_Material  : register(t2);   // x=roughness, y=metalness
Texture2D<float>    g_GBuffer_Depth     : register(t3);
Texture2D<float2>   g_GBuffer_Motion    : register(t4);

// Ray tracing acceleration structures (Pass 4 writes TLAS)
RaytracingAccelerationStructure g_TLAS  : register(t5);   // UAV→SRV (AS) barrier after TLAS build

// ReSTIR reservoirs (Passes 5-7)
// Declared as structured buffers — ping-pong between frames
StructuredBuffer<float4>        g_ReservoirsRead   : register(t6);
RWStructuredBuffer<float4>      g_ReservoirsWrite  : register(u0);

// Path tracing output (Pass 8)
RWTexture2D<float4>             g_RawRadiance      : register(u1);   // written by ray gen shader

// SVGF buffers (Passes 9-10)
Texture2D<float4>               g_AccumulatedColor : register(t7);
RWTexture2D<float4>             g_FilteredColor    : register(u2);

// Final output (Pass 11)
RWTexture2D<float4>             g_DisplayOutput    : register(u3);

/**
 * FullscreenVS — fullscreen triangle vertex shader.
 * Used for all screen-space passes (SVGF, TAA, tone map).
 * No vertex buffer needed — generates triangle from vertex ID.
 */
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VSOut FullscreenVS(uint vid : SV_VertexID)
{
    VSOut o;
    float2 uv  = float2((vid << 1) & 2, vid & 2);
    o.pos      = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
    o.pos.y    = -o.pos.y;
    o.uv       = uv;
    return o;
}
