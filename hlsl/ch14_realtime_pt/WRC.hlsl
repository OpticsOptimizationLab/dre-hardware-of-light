// WRC grid parameters.
static const float  WRC_CELL_SIZE   = 0.5f;   // World units per cell (scene-dependent)
static const uint   WRC_GRID_SIZE   = 1 << 18; // 262,144 cells (hash table size)
static const float  WRC_DECAY_RATE  = 0.02f;   // Temporal decay per frame
static const float  WRC_BLEND_ALPHA = 0.05f;   // Blend factor for new samples

struct WRCCell
{
    float3 irradiance;     // Accumulated indirect radiance from all bounces
    float3 dominantDir;    // Weighted average light direction (for directional filtering)
    float  sampleCount;    // Number of samples accumulated (for confidence weighting)
    float  lastUpdateFrame; // Frame index of last update (for decay)
};

RWStructuredBuffer<WRCCell> g_WRCGrid : register(u5);

// Spatial hash function, maps world position to grid cell index.
uint WRCHash(float3 worldPos)
{
    int3 cell = int3(floor(worldPos / WRC_CELL_SIZE));
    // Spatial hash primes (Teschner et al. 2003) — minimizes collision clustering.
    uint h = cell.x * 73856093u ^ cell.y * 19349663u ^ cell.z * 83492791u;
    return h % WRC_GRID_SIZE;
}