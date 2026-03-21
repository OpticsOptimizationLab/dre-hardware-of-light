/**
 * NRC_Query.hlsl
 * Digital Rendering Engineering, Vol. 2 — The Hardware of Light
 * Chapter 15.2 — Neural Radiance Cache: Inference
 *
 * NRC inference shader: multiresolution hash grid encoding + MLP forward pass.
 * Called from ClosestHit shader at bounce 2+ (same role as WRC QueryWRC()).
 * ~0.8ms/frame inference cost (RTX 4090, 1440p, 3M primary rays).
 *
 * Training code: NRC_Train.hlsl (in book §15.2) + NRC_Training.py (Python offline)
 * Compile: dxc -T cs_6_6 -E CS_NRC_Infer -Fo NRC_Query.dxil NRC_Query.hlsl
 */

#ifndef DRE_NRC_QUERY_HLSL
#define DRE_NRC_QUERY_HLSL

// ─────────────────────────────────────────────────────────────────────────────
// NRC ARCHITECTURE PARAMETERS (§ 15.2)
//
// Stage 1: Multiresolution hash grid encoding
//   16 resolution levels, each doubling from 16³ to 524,288³ (virtual).
//   512K entries × 4 features × float16 = 4 MB hash table.
//
// Stage 2: Small MLP
//   Input:   64 (hash features) + 7 (surface: normal, viewDir, roughness) = 71
//   Hidden:  3 layers × 64 neurons (ReLU)
//   Output:  3 neurons (linear) = RGB radiance
//   Weights: ~12,500 parameters (trivial, fits in SM L1 cache)
// ─────────────────────────────────────────────────────────────────────────────

static const uint HASH_LEVELS         = 16;
static const uint FEATURES_PER_LEVEL  = 4;
static const uint HASH_TABLE_SIZE     = 1 << 19;           // 512K entries
static const uint HASH_FEATURE_DIM    = HASH_LEVELS * FEATURES_PER_LEVEL; // 64

static const uint LAYER0_OFFSET = 0;
static const uint LAYER1_OFFSET = (71 * 64 + 64) * 4;     // 18432 bytes
static const uint LAYER2_OFFSET = LAYER1_OFFSET + (64 * 64 + 64) * 4;
static const uint LAYER3_OFFSET = LAYER2_OFFSET + (64 * 64 + 64) * 4;

// ─────────────────────────────────────────────────────────────────────────────
// RESOURCES
// ─────────────────────────────────────────────────────────────────────────────

// Hash table (trained features, float16). Updated each frame by NRC_Train.hlsl.
ByteAddressBuffer g_NRCHashTable  : register(t30);

// MLP weights (float32). Updated each frame by NRC_Train.hlsl.
ByteAddressBuffer g_MLPWeights    : register(t31);

cbuffer NRCConstants : register(b3)
{
    float3 g_SceneBoundsMin;    // Scene AABB minimum
    float  _pad0;
    float3 g_SceneBoundsExtent; // Scene AABB extent (max - min)
    float  _pad1;
};

// ─────────────────────────────────────────────────────────────────────────────
// HASH GRID ENCODING: TRILINEAR LOOKUP AT ONE RESOLUTION LEVEL (§ 15.2)
// Maps world position → 4-dimensional feature vector for that level.
// ─────────────────────────────────────────────────────────────────────────────

float4 LookupHashLevel(float3 normalizedPos, uint level, uint hashTableSize)
{
    float scale    = pow(2.0f, (float)level) * 16.0f;
    float3 scaled  = normalizedPos * scale;
    int3   cell    = int3(floor(scaled));
    float3 frac    = scaled - float3(cell);

    float4 result = float4(0, 0, 0, 0);

    // Trilinear interpolation over 8 corners.
    for (uint i = 0; i < 8; ++i)
    {
        int3  corner = cell + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);

        // Hash corner coordinates to table index.
        uint h = ((uint)corner.x * 2654435761u)
               ^ ((uint)corner.y * 805459861u)
               ^ ((uint)corner.z * 3674653429u);
        uint idx = h % hashTableSize;

        // Load 4 float16 features (2 × uint32 = 4 × float16).
        uint byteOffset = (idx * FEATURES_PER_LEVEL + level * hashTableSize * FEATURES_PER_LEVEL) * 2;
        uint2 raw = g_NRCHashTable.Load2(byteOffset);

        float4 feat = float4(
            f16tof32(raw.x & 0xFFFF), f16tof32(raw.x >> 16),
            f16tof32(raw.y & 0xFFFF), f16tof32(raw.y >> 16));

        // Trilinear weight.
        float wx = (i & 1)       ? frac.x : (1.0f - frac.x);
        float wy = ((i >> 1) & 1) ? frac.y : (1.0f - frac.y);
        float wz = ((i >> 2) & 1) ? frac.z : (1.0f - frac.z);

        result += wx * wy * wz * feat;
    }

    return result;
}

// Full hash grid encoding: 16 levels → 64-dimensional feature vector.
void NRC_Encode(float3 worldPos, out float hashFeatures[HASH_FEATURE_DIM])
{
    float3 normalizedPos = (worldPos - g_SceneBoundsMin) / g_SceneBoundsExtent;
    normalizedPos = saturate(normalizedPos); // Clamp to [0, 1]

    for (uint level = 0; level < HASH_LEVELS; ++level)
    {
        float4 feat = LookupHashLevel(normalizedPos, level, HASH_TABLE_SIZE);
        hashFeatures[level * FEATURES_PER_LEVEL + 0] = feat.x;
        hashFeatures[level * FEATURES_PER_LEVEL + 1] = feat.y;
        hashFeatures[level * FEATURES_PER_LEVEL + 2] = feat.z;
        hashFeatures[level * FEATURES_PER_LEVEL + 3] = feat.w;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MLP FORWARD PASS: ONE LAYER (§ 15.2 Workbench 15.2.B)
// output[j] = ReLU(Σ_i input[i] × W[i,j] + bias[j])
// Linear (no activation) when isOutputLayer=true.
// ─────────────────────────────────────────────────────────────────────────────

void MLPLayer(float input[], out float output[], uint inDim, uint outDim,
              uint weightByteOffset, bool isOutputLayer)
{
    for (uint j = 0; j < outDim; ++j)
    {
        // Bias: stored after the weight matrix.
        uint biasOffset = weightByteOffset + inDim * outDim * 4 + j * 4;
        float acc = asfloat(g_MLPWeights.Load(biasOffset));

        for (uint i = 0; i < inDim; ++i)
        {
            uint wOffset = weightByteOffset + (i * outDim + j) * 4;
            acc += input[i] * asfloat(g_MLPWeights.Load(wOffset));
        }

        output[j] = isOutputLayer ? acc : max(0.0f, acc); // Linear or ReLU
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NRC INFERENCE: FULL FORWARD PASS (§ 15.2)
// Input: surface position + normal + viewDir + roughness.
// Output: estimated incoming radiance (RGB).
// ─────────────────────────────────────────────────────────────────────────────

float3 NRC_Infer(float3 worldPos, float3 normal, float3 viewDir, float roughness)
{
    // Stage 1: Hash grid encoding → 64 features.
    float hashFeatures[HASH_FEATURE_DIM];
    NRC_Encode(worldPos, hashFeatures);

    // Concatenate with surface inputs: 64 + 7 = 71-dimensional input.
    float input[71];
    for (uint i = 0; i < 64; ++i) input[i] = hashFeatures[i];
    input[64] = normal.x;  input[65] = normal.y;  input[66] = normal.z;
    input[67] = viewDir.x; input[68] = viewDir.y; input[69] = viewDir.z;
    input[70] = roughness;

    // Stage 2: MLP forward pass (3 hidden layers + output).
    float h0[64], h1[64], h2[64], output[3];

    MLPLayer(input, h0, 71, 64, LAYER0_OFFSET, false); // 71 → 64, ReLU
    MLPLayer(h0,   h1, 64, 64, LAYER1_OFFSET, false); // 64 → 64, ReLU
    MLPLayer(h1,   h2, 64, 64, LAYER2_OFFSET, false); // 64 → 64, ReLU
    MLPLayer(h2, output, 64, 3, LAYER3_OFFSET, true);  // 64 → 3,  Linear

    return max(float3(output[0], output[1], output[2]), float3(0, 0, 0));
}

// ─────────────────────────────────────────────────────────────────────────────
// INTEGRATION: CALL FROM CLOSEST HIT (§ 15.2)
// Use at bounce 2+, replacing multi-bounce ray tracing.
// Same interface as QueryWRC() for drop-in substitution.
// ─────────────────────────────────────────────────────────────────────────────

// float3 indirectRadiance = NRC_Infer(hit.worldPos, hit.normal, viewDir, hit.roughness);
// Same usage as: QueryWRC(hit.worldPos, hit.normal)
//
// NRC vs WRC selection (§ 15.2.A decision tree):
//   VRAM-constrained (< 8GB):       WRC (8 MB)
//   Rapid lighting changes:         ReSTIR GI
//   Large outdoor, slow lighting:   WRC (large cell_size)
//   Indoor, slow lighting, quality: NRC (smoother, ~33 MB)

// ─────────────────────────────────────────────────────────────────────────────
// DEPLOYMENT RULE (§ 15.2)
//
// NRC convergence: ~30 frames for static lighting.
// Dynamic lighting (lights switching on/off in 1 frame): use ReSTIR GI instead.
// NRC for: indirect illumination changes over tens of seconds (sun position, etc.).
//
// COMMON BUG: coordinate system mismatch.
// g_SceneBoundsMin/Extent must use the same convention as the rendering pipeline.
// Y-up vs Z-up mismatch: all world positions hash to wrong cells.
// Symptom: NRC never converges (output spatially uniform), doubling training batches
// has no effect. Fix: recompute bounds in the correct coordinate system.

#endif // DRE_NRC_QUERY_HLSL
