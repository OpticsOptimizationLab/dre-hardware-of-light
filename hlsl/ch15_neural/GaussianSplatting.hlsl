/**
 * GaussianSplatting.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 15.1 — 3D Gaussian Splatting
 *
 * Gaussian projection, tile range classification, and tile-based alpha compositing.
 * Uses GaussianSorting.hlsl (GPU radix sort) for back-to-front ordering.
 * Compile: dxc -T cs_6_6 -E ProjectGaussians -Fo GaussianSplatting.dxil GaussianSplatting.hlsl
 */

#ifndef DRE_GAUSSIAN_SPLATTING_HLSL
#define DRE_GAUSSIAN_SPLATTING_HLSL

static const float PI = 3.14159265f;

// ─────────────────────────────────────────────────────────────────────────────
// GAUSSIAN STRUCTS (§ 15.1)
// ─────────────────────────────────────────────────────────────────────────────

// Production runtime format: 58 bytes (order-1 SH) or 40 bytes (order-0, no view-dep).
// At 3M Gaussians: 174 MB (order-1) or 120 MB (order-0).
struct Gaussian3D_RT
{
    float16_t3 position;    // 6 bytes — world-space center
    float16_t4 rotation;    // 8 bytes — unit quaternion (R in Σ = RSS^T R^T)
    float16_t3 scale;       // 6 bytes — log-scale diagonal S
    float16_t  opacity;     // 2 bytes — α ∈ [0, 1]
    uint       shCoeffs[9]; // 36 bytes — 18 × float16 SH order-1 (9 coefficients)
};

// Projected 2D ellipse for the rasterizer.
struct ProjectedGaussian
{
    float2   screenPos;     // Center in pixels
    float2x2 cov2D;         // 2×2 screen-space covariance (for Mahalanobis distance)
    float    depth;         // View-space depth (for sorting key)
    float    alpha;         // Gaussian opacity
    uint     gaussianIdx;   // Source Gaussian index (for SH evaluation)
};

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

StructuredBuffer<Gaussian3D_RT>      g_Gaussians          : register(t0);
RWStructuredBuffer<ProjectedGaussian> g_ProjectedGaussians : register(u0);
RWStructuredBuffer<uint>             g_SortKeys           : register(u1); // For GaussianSorting
RWStructuredBuffer<uint>             g_SortValues         : register(u2); // Gaussian indices (sorted)
RWStructuredBuffer<uint2>            g_TileRanges         : register(u3); // [start, end] per tile
RWTexture2D<float4>                  g_Output             : register(u4);

cbuffer GaussianConstants : register(b0)
{
    float4x4 g_ViewProj;
    float4x4 g_View;
    float2   g_Resolution;
    float    g_FocalLength;    // Pixels: typically width / (2 * tan(fovX/2))
    uint     g_NumGaussians;
    uint     g_TileCountX;
    uint3    _pad;
};

static const uint  TILE_SIZE   = 16;       // 16×16 pixel tiles
static const float MAX_RENDER_DEPTH = 1000.0f;

// ─────────────────────────────────────────────────────────────────────────────
// QUATERNION TO ROTATION MATRIX
// ─────────────────────────────────────────────────────────────────────────────

float3x3 QuatToMatrix(float4 q)
{
    float x = q.x, y = q.y, z = q.z, w = q.w;
    return float3x3(
        1-2*(y*y+z*z),   2*(x*y-w*z),   2*(x*z+w*y),
          2*(x*y+w*z), 1-2*(x*x+z*z),   2*(y*z-w*x),
          2*(x*z-w*y),   2*(y*z+w*x), 1-2*(x*x+y*y)
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 1: PROJECT GAUSSIANS TO SCREEN SPACE (§ 15.1)
// Σ_2D = JW × Σ_3D × (JW)^T
// ─────────────────────────────────────────────────────────────────────────────

[numthreads(256, 1, 1)]
void ProjectGaussians(uint gaussianID : SV_DispatchThreadID)
{
    if (gaussianID >= g_NumGaussians) return;

    Gaussian3D_RT g = g_Gaussians[gaussianID];

    float3 pos = float3(g.position);

    // Transform center to clip/view space.
    float4 clipPos = mul(float4(pos, 1.0f), g_ViewProj);
    float4 viewPos4 = mul(float4(pos, 1.0f), g_View);
    float3 t = viewPos4.xyz;

    // Cull behind camera.
    if (t.z <= 0.0f) return;

    // Perspective projection Jacobian at this point.
    float2x3 J = float2x3(
        g_FocalLength / t.z,  0,                -(g_FocalLength * t.x) / (t.z * t.z),
        0,                  g_FocalLength / t.z, -(g_FocalLength * t.y) / (t.z * t.z)
    );

    // Camera rotation (3×3 upper-left of view matrix).
    float3x3 W = (float3x3)g_View;

    // Reconstruct 3D covariance from quaternion + scale.
    // Σ_3D = R × S × S^T × R^T
    float3x3 R = QuatToMatrix(float4(g.rotation));
    float3 s = exp(float3(g.scale)); // log-scale → scale
    float3x3 S = float3x3(
        s.x, 0,   0,
        0,   s.y, 0,
        0,   0,   s.z
    );
    float3x3 cov3D = mul(R, mul(mul(S, S), transpose(R)));

    // JW = J × W (combined transform).
    float2x3 JW = mul(J, W);

    // Σ_2D = JW × Σ_3D × (JW)^T
    float2x2 cov2D = (float2x2)mul(JW, mul(cov3D, transpose(JW)));

    // Low-pass filter: prevent degenerate (infinitely sharp) Gaussians.
    cov2D[0][0] += 0.3f;
    cov2D[1][1] += 0.3f;

    ProjectedGaussian pg;
    pg.screenPos   = (clipPos.xy / clipPos.w * 0.5f + 0.5f) * g_Resolution;
    pg.cov2D       = cov2D;
    pg.depth       = t.z;
    pg.alpha       = (float)g.opacity;
    pg.gaussianIdx = gaussianID;

    g_ProjectedGaussians[gaussianID] = pg;

    // Compute sort key: [tile (8 bits)] [depth (24 bits, inverted for back-to-front)].
    uint tileX = (uint)(pg.screenPos.x / TILE_SIZE);
    uint tileY = (uint)(pg.screenPos.y / TILE_SIZE);
    uint tileIdx = tileY * g_TileCountX + tileX;

    float normalizedDepth = saturate(t.z / MAX_RENDER_DEPTH);
    uint  depthKey        = (uint)(normalizedDepth * 0xFFFFFF);

    g_SortKeys[gaussianID]  = (tileIdx << 24) | (0xFFFFFF - depthKey); // Invert for back-to-front
    g_SortValues[gaussianID] = gaussianID;
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 2: CLASSIFY TILE RANGES (after GPU radix sort)
// Finds [start, end] index in the sorted array for each tile.
// ─────────────────────────────────────────────────────────────────────────────

[numthreads(256, 1, 1)]
void ClassifyTileRanges(uint sortedIdx : SV_DispatchThreadID)
{
    if (sortedIdx >= g_NumGaussians) return;

    uint key     = g_SortKeys[sortedIdx];
    uint tileIdx = key >> 24;

    // Mark the start of each tile (where the tile index changes).
    if (sortedIdx == 0 || (g_SortKeys[sortedIdx - 1] >> 24) != tileIdx)
        g_TileRanges[tileIdx].x = sortedIdx;

    if (sortedIdx == g_NumGaussians - 1 || (g_SortKeys[sortedIdx + 1] >> 24) != tileIdx)
        g_TileRanges[tileIdx].y = sortedIdx + 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// PASS 3: TILE-BASED GAUSSIAN RASTERIZER (§ 15.1)
// Each 16×16 tile processes its sorted Gaussians in back-to-front order.
// Alpha compositing: accumColor += (1 - accumColor.a) × gaussianAlpha × color.
// ─────────────────────────────────────────────────────────────────────────────

// Spherical harmonics evaluation (order-1, view-dependent color).
// Coefficients stored as 3 RGB × 3 basis functions = 9 floats.
float3 EvaluateSH(uint shPacked[9], float3 viewDir)
{
    // SH basis (order-0 + order-1): 4 coefficients per channel.
    // Y_0 = 0.282095, Y_1 = 0.488603 * {x, y, z}
    static const float SH_C0 = 0.28209479f;
    static const float SH_C1 = 0.48860251f;

    float3 color = float3(0, 0, 0);

    for (uint i = 0; i < 9; ++i)
    {
        uint   packed = shPacked[i];
        float2 xy     = float2(f16tof32(packed & 0xFFFF), f16tof32(packed >> 16));

        // Simplified: use DC component only for brevity.
        // Full SH evaluation: weight each coefficient by its basis function.
        if (i == 0) color += float3(xy.x, xy.y, f16tof32(shPacked[1] & 0xFFFF)) * SH_C0;
    }

    return max(color + 0.5f, 0.0f); // DC offset + clamp
}

[numthreads(16, 16, 1)]
void RasterizeGaussians(
    uint2 threadID : SV_DispatchThreadID,
    uint2 groupID  : SV_GroupID)
{
    uint2 pixel = threadID;
    if (any(pixel >= (uint2)g_Resolution)) return;

    float4 accumColor = float4(0, 0, 0, 0);

    // Tile range in the sorted Gaussian list.
    uint tileIdx    = groupID.y * g_TileCountX + groupID.x;
    uint rangeStart = g_TileRanges[tileIdx].x;
    uint rangeEnd   = g_TileRanges[tileIdx].y;

    for (uint i = rangeStart; i < rangeEnd; ++i)
    {
        uint             gaussianIdx = g_SortValues[i];
        ProjectedGaussian pg         = g_ProjectedGaussians[gaussianIdx];
        Gaussian3D_RT     g          = g_Gaussians[gaussianIdx];

        // Mahalanobis distance in screen space.
        float2 delta = float2(pixel) - pg.screenPos;

        float det = pg.cov2D[0][0] * pg.cov2D[1][1] - pg.cov2D[0][1] * pg.cov2D[1][0];
        if (abs(det) < 1e-7f) continue;

        float2x2 Sigma_inv = float2x2(
             pg.cov2D[1][1] / det, -pg.cov2D[0][1] / det,
            -pg.cov2D[1][0] / det,  pg.cov2D[0][0] / det);

        float exponent = -0.5f * dot(delta, mul(Sigma_inv, delta));
        if (exponent < -4.0f) continue; // Contribution < exp(-4) ≈ 0.018

        float gaussianAlpha = pg.alpha * exp(exponent);
        if (gaussianAlpha < 1.0f / 255.0f) continue;

        // View-dependent color via SH.
        float3 viewDir = normalize(float3(pixel, 1.0f) - float3(g.position));
        float3 color   = EvaluateSH(g.shCoeffs, viewDir);

        // Front-to-back alpha compositing (we iterate back-to-front, so use:)
        // accumColor += (1 - accumColor.a) × gaussianAlpha × color
        float remaining = 1.0f - accumColor.a;
        accumColor.rgb += remaining * gaussianAlpha * color;
        accumColor.a   += remaining * gaussianAlpha;

        if (accumColor.a > 0.99f) break; // Pixel fully opaque.
    }

    g_Output[pixel] = float4(accumColor.rgb, accumColor.a);
}

// ─────────────────────────────────────────────────────────────────────────────
// PRODUCTION SCOPE (§ 15.1)
//
// WHERE 3DGS SHIPS TODAY:
//   ✓ Cinematic environment backgrounds (pre-captured, never changes during gameplay)
//   ✓ Digital twin visualization
//   ✓ Photorealistic facial capture (multi-camera studio)
//
// WHERE 3DGS DOES NOT SHIP:
//   ✗ Dynamic characters (each pose requires retraining: 30min–2hrs)
//   ✗ Interactive destruction (topology changes invalidate the representation)
//   ✗ Large open-world (3M Gaussians × many captures = VRAM-prohibitive)
//   ✗ Hard shadow casting (volumetric splats, no binary shadow map)
//
// VRAM: 58 bytes × 3M Gaussians = 174 MB (order-1 SH)
// Sort cost: GPU radix sort, ~2–3ms for 3M Gaussians

#endif // DRE_GAUSSIAN_SPLATTING_HLSL
