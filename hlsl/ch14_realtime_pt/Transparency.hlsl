// Transparency.hlsl
[shader("anyhit")]
void AnyHitAlphaTest(inout PathPayload payload,
                     in BuiltInTriangleIntersectionAttributes attrib)
{
    uint materialID = InstanceID();
    Material mat = g_Materials[materialID];

    if (!mat.isAlphaTested) return; // Opaque, accept implicitly.

    float2 uv = InterpolateUV(PrimitiveIndex(), attrib.barycentrics);

    // Sample alpha from the albedo texture's alpha channel.
    Texture2D<float4> albedoTex = ResourceDescriptorHeap[mat.albedoIndex];
    float alpha = albedoTex.SampleLevel(g_LinearSampler, uv, 0).a;

    if (alpha < mat.alphaThreshold) // Typically 0.5
        IgnoreHit(); // Continue traversal, this triangle is transparent.
}