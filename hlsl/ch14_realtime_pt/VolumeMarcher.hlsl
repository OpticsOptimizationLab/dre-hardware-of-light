// Beer-Lambert ray marcher for homogeneous or heterogeneous media.
// Input: ray segment [tNear, tFar], density field, light direction.
// Output: accumulated radiance + transmittance for compositing.

struct VolumeResult
{
    float3 radiance;       // Accumulated in-scattered + emitted light
    float  transmittance;  // Remaining transmittance [0, 1]
};

VolumeResult MarchVolume(
    float3 rayOrigin, float3 rayDir,
    float tNear, float tFar,
    uint seed)
{
    VolumeResult result;
    result.radiance      = float3(0, 0, 0);
    result.transmittance = 1.0f;

    // Step size: trade-off between quality and cost.
    // 64 steps for a medium-depth volume. Adaptive stepping improves this.
    float stepSize = (tFar - tNear) / VOLUME_MARCH_STEPS; // 64 steps

    for (uint i = 0; i < VOLUME_MARCH_STEPS; ++i)
    {
        float t = tNear + (float(i) + RandomFloat(seed)) * stepSize;
        // ^ Jittered sample position to avoid banding.

        float3 worldPos = rayOrigin + rayDir * t;

        // Sample density from the volume.
        float density = SampleVolumeDensity(worldPos); // NanoVDB or 3D texture
        if (density < 0.001f) continue; // Skip empty space.

        // Extinction coefficient: density × cross-section.
        float sigmaT = density * VOLUME_EXTINCTION_SCALE;
        float sigmaS = density * VOLUME_SCATTERING_SCALE;

        // Beer-Lambert: transmittance through this step.
        float stepTransmittance = exp(-sigmaT * stepSize);

        // In-scattering: sample light at this point.
        // Simplified: one shadow ray toward the dominant light.
        float3 lightDir = normalize(g_SunDirection);
        bool occluded = TraceShadowRay(worldPos, lightDir, 1000.0f);
        float3 inScattered = occluded ? float3(0, 0, 0)
                                      : g_SunRadiance * PhaseFunction(rayDir, lightDir);

        // Emission (for fire/explosion volumes).
        float3 emission = SampleVolumeEmission(worldPos);

        // Accumulate radiance weighted by current transmittance.
        result.radiance += result.transmittance * (sigmaS * inScattered + emission) * stepSize;

        // Update transmittance.
        result.transmittance *= stepTransmittance;

        // Early termination: transmittance near zero, ray is fully absorbed.
        if (result.transmittance < 0.001f) break;
    }

    return result;
}