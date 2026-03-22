// Hash grid encoding.
// Input: world position in normalized scene coordinates [0, 1]^3.
// Output: 64-dimensional feature vector (16 levels × 4 features per level).

static const uint HASH_LEVELS     = 16;
static const uint FEATURES_PER_LEVEL = 4;
static const uint HASH_TABLE_SIZE  = 1 << 19; // 512K entries
static const uint HASH_FEATURE_DIM = HASH_LEVELS * FEATURES_PER_LEVEL; // 64

// Hash table: HASH_TABLE_SIZE entries × FEATURES_PER_LEVEL float16 = 4 MB
// (512K × 4 × 2 bytes = 4 MB, much smaller than the 128MB network total)

ByteAddressBuffer g_HashTable : register(t30); // Trained weights

float4 LookupHashLevel(float3 pos, uint level, uint hashTableSize)
{
    float scale = pow(2.0f, level) * 16.0f; // Resolution at this level
    float3 scaled = pos * scale;
    int3   cell   = int3(floor(scaled));

    // Trilinear interpolation over 8 corners.
    float3 frac = scaled - float3(cell);
    float4 result = float4(0, 0, 0, 0);

    for (uint i = 0; i < 8; ++i)
    {
        int3 corner = cell + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);

        // Hash cell coordinates to table index.
        uint h = (corner.x * 2654435761u) ^ (corner.y * 805459861u) ^ (corner.z * 3674653429u);
        uint idx = h % hashTableSize;

        // Load 4 feature values (2 × uint32 = 4 × float16).
        uint2 raw = g_HashTable.Load2(idx * 8);
        float4 feat = float4(f16tof32(raw.x & 0xFFFF), f16tof32(raw.x >> 16),
                             f16tof32(raw.y & 0xFFFF), f16tof32(raw.y >> 16));

        // Trilinear weight.
        float wx = (i & 1) ? frac.x : (1.0f - frac.x);
        float wy = ((i >> 1) & 1) ? frac.y : (1.0f - frac.y);
        float wz = ((i >> 2) & 1) ? frac.z : (1.0f - frac.z);

        result += wx * wy * wz * feat;
    }
    return result;
}

float NRC_Encode(float3 worldPos, float3 normal, float3 viewDir, float roughness,
                 out float hashFeatures[HASH_FEATURE_DIM])
{
    float3 normalizedPos = (worldPos - g_SceneBoundsMin) / g_SceneBoundsExtent;

    for (uint level = 0; level < HASH_LEVELS; ++level)
    {
        float4 feat = LookupHashLevel(normalizedPos, level, HASH_TABLE_SIZE);
        hashFeatures[level * 4 + 0] = feat.x;
        hashFeatures[level * 4 + 1] = feat.y;
        hashFeatures[level * 4 + 2] = feat.z;
        hashFeatures[level * 4 + 3] = feat.w;
    }
    // Return combined feature dimension index.
    return 0;
}