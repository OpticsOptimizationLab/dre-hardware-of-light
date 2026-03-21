/**
 * OccupancyEstimator.hlsl
 * DRE Vol. 2 — Chapter 11.2: Register Pressure and Occupancy
 *
 * Compile-time occupancy estimation constants for Ampere (RTX 30/40xx).
 * Cross-reference: Section 11.2 register budget table.
 */

// Ampere SM physical limits
static const uint AMPERE_REGS_PER_SM        = 65536;
static const uint AMPERE_MAX_THREADS_PER_SM = 1536;   // 48 warps x 32 threads
static const uint AMPERE_WARP_SIZE          = 32;

// RDNA 3 CU physical limits
static const uint RDNA3_REGS_PER_CU         = 65536;
static const uint RDNA3_MAX_THREADS_PER_CU  = 2048;   // 32 wavefronts x 64 threads
static const uint RDNA3_WAVE_SIZE           = 64;

/**
 * EstimateOccupancy
 * Returns theoretical occupancy [0.0, 1.0] for a given kernel on Ampere.
 *
 * @param regsPerThread  Registers consumed per thread (read from NSight)
 * @param threadsPerGroup Threadgroup size (e.g. 64 for 8x8)
 */
float EstimateOccupancy_Ampere(uint regsPerThread, uint threadsPerGroup)
{
    if (regsPerThread == 0 || threadsPerGroup == 0) return 0.0f;

    // Warps per threadgroup
    uint warpsPerGroup = (threadsPerGroup + AMPERE_WARP_SIZE - 1) / AMPERE_WARP_SIZE;

    // Limit 1: thread count
    uint maxGroupsByThreads = AMPERE_MAX_THREADS_PER_SM / threadsPerGroup;

    // Limit 2: register file
    uint regsPerGroup       = regsPerThread * threadsPerGroup;
    uint maxGroupsByRegs    = (regsPerGroup > 0) ? (AMPERE_REGS_PER_SM / regsPerGroup) : maxGroupsByThreads;

    uint activeGroups       = min(maxGroupsByThreads, maxGroupsByRegs);
    uint maxGroups          = AMPERE_MAX_THREADS_PER_SM / threadsPerGroup;

    return saturate((float)activeGroups / (float)maxGroups);
}

/**
 * DRE Function Register Budget (estimated, Ampere)
 * Validated against NSight — see Ch. 11.2 table.
 *
 * D_GGX                  ~8  regs  → 100% occupancy (8x8 group)
 * F_Schlick               ~8  regs  → 100% occupancy
 * V_SmithGGX_Correlated   ~10 regs  → 100% occupancy
 * EvaluateCookTorrance     ~16 regs  → 100% occupancy
 * SampleVNDF               ~18 regs  → 100% occupancy
 * PathTrace() full kernel  ~38-44 regs → 65-80% occupancy
 *
 * Occupancy cliff: > 42 regs/thread drops below 100% for 8x8 threadgroups.
 */
