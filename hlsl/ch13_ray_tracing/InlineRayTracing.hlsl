// Shadow ray via inline ray tracing.
// No RTPSO. No SBT. Just a compute shader with access to the TLAS.

[numthreads(8, 8, 1)]
void CS_ShadowValidation(uint2 pixel : SV_DispatchThreadID)
{
    float3 worldPos = g_GBufferWorldPos[pixel].xyz;
    float3 lightDir = normalize(g_LightPosition - worldPos);
    float  lightDist = length(g_LightPosition - worldPos);

    RayDesc ray;
    ray.Origin    = worldPos + g_GBufferNormal[pixel].xyz * 0.001f;
    ray.Direction = lightDir;
    ray.TMin      = 0.0f;
    ray.TMax      = lightDist;

    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES
           | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;

    query.TraceRayInline(
        g_TLAS,          // Acceleration structure SRV.
        RAY_FLAG_NONE,   // Additional flags (combined with template flags).
        0xFF,            // Instance mask.
        ray
    );

    // Manual traversal loop.
    // For opaque geometry with ACCEPT_FIRST_HIT, this loop
    // executes zero iterations, the hardware resolves immediately.
    while (query.Proceed())
    {
        // This block only executes for non-opaque candidates.
        if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE)
        {
            // Alpha test inline, no AnyHit shader available.
            float2 bary = query.CandidateTriangleBarycentrics();
            uint instanceID = query.CandidateInstanceID();
            uint primID = query.CandidatePrimitiveIndex();

            float alpha = SampleAlphaInline(instanceID, primID, bary);
            if (alpha >= 0.5f)
                query.CommitNonOpaqueTriangleHit();
            // else: transparent, continue traversal.
        }
    }

    // Result.
    bool occluded = (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT);
    g_ShadowMask[pixel] = occluded ? 0.0f : 1.0f;
}