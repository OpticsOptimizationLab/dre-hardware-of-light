/**
 * DiagnoseDivergence.hlsl
 * DRE Vol. 2 — Chapter 11.1: The SIMD Contract
 *
 * Reports wave divergence factor for a compute dispatch.
 * divergenceFactor > 0.2 = real problem in this wave.
 *
 * Usage: bind g_DiagnosticOutput as UAV, dispatch 8x8 threadgroup.
 */

RWBuffer<float> g_DiagnosticOutput : register(u0);

[numthreads(8, 8, 1)]
void CS_DiagnoseDivergence(uint3 tid : SV_DispatchThreadID, uint3 gtid : SV_GroupThreadID)
{
    // Measure active lanes in this wave
    uint4 ballot       = WaveActiveBallot(true);
    uint  activeLanes  = countbits(ballot.x) + countbits(ballot.y)
                       + countbits(ballot.z) + countbits(ballot.w);
    uint  totalLanes   = WaveGetLaneCount();  // 32 on Ampere, 64 on RDNA 3

    float divergenceFactor = 1.0f - (float)activeLanes / (float)totalLanes;

    // Only first lane in wave writes the result
    if (WaveIsFirstLane())
    {
        uint waveIndex = tid.x / totalLanes + tid.y * (8 / totalLanes);
        g_DiagnosticOutput[waveIndex] = divergenceFactor;
    }
}

/**
 * WaveRussianRoulette — correct wave-aware implementation.
 * From DRE Vol. 1, Ch. 7.4.1 — now explained by Ch. 11.
 *
 * Uses WaveActiveAnyTrue to keep the wave alive as long as
 * any lane survives, preventing premature wave termination.
 */
bool WaveRussianRoulette(float survivalProbability, float rng, inout float3 throughput)
{
    if (survivalProbability <= 0.0f) return false;

    bool survive = (rng < survivalProbability);

    // Keep wave alive if ANY lane survives — avoids wave divergence at termination
    if (!WaveActiveAnyTrue(survive)) return false;

    if (survive)
        throughput /= survivalProbability;

    return survive;
}
