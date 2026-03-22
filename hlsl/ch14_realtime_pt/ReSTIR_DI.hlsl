// Reservoir structure, 28 bytes per pixel.
struct Reservoir
{
    uint   lightIndex;  // 4 bytes — index of the currently selected light
    float  weightSum;   // 4 bytes — running sum of candidate weights (W in WRS algorithm)
    float  W;           // 4 bytes — unbiased contribution weight: W = (1/p̂(y)) * (w_sum / M)
    uint   M;           // 4 bytes — total number of candidates seen so far
    float3 cachedPos;   // 12 bytes — selected light position for Jacobian
};                      // Total: 28 bytes per pixel

// Streaming update: potentially replace the current sample with a new candidate.
bool ReservoirUpdate(inout Reservoir r, uint candidateLightIdx,
                     float candidateWeight, float rng)
{
    r.weightSum += candidateWeight;
    r.M++;

    // Accept candidate with probability proportional to its weight.
    if (rng < candidateWeight / r.weightSum)
    {
        r.lightIndex = candidateLightIdx;
        return true; // New candidate accepted.
    }
    return false; // Previous candidate retained.
}