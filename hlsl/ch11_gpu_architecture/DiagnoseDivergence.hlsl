// DiagnoseDivergence.hlsl
if (rng <= survivalProbability)
{
    // Path continues, evaluate next bounce.
    throughput /= survivalProbability;
}
else
{
    // Path terminated, Russian Roulette killed it.
    return radiance;
}