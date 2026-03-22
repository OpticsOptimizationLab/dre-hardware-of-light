// DRE_ClosestHit.hlsl
struct VertexAttributes
{
    float3 position;
    float3 normal;
    float2 uv;
    float4 tangent; // xyz = tangent direction, w = handedness (±1)
};

VertexAttributes InterpolateVertexAttributes(
    uint materialID, uint primitiveID, float3 bary)
{
    // Fetch vertex indices for this triangle.
    uint baseIndex = primitiveID * 3;
    uint i0 = g_IndexBuffer[materialID].Load(baseIndex + 0);
    uint i1 = g_IndexBuffer[materialID].Load(baseIndex + 1);
    uint i2 = g_IndexBuffer[materialID].Load(baseIndex + 2);

    // Fetch vertex data.
    VertexAttributes v0 = g_VertexBuffer[materialID][i0];
    VertexAttributes v1 = g_VertexBuffer[materialID][i1];
    VertexAttributes v2 = g_VertexBuffer[materialID][i2];

    // Barycentric interpolation.
    VertexAttributes result;
    result.position = bary.x * v0.position + bary.y * v1.position + bary.z * v2.position;
    result.normal   = bary.x * v0.normal   + bary.y * v1.normal   + bary.z * v2.normal;
    result.uv       = bary.x * v0.uv       + bary.y * v1.uv       + bary.z * v2.uv;
    result.tangent  = bary.x * v0.tangent  + bary.y * v1.tangent  + bary.z * v2.tangent;

    // Normalize interpolated normal and tangent.
    result.normal  = normalize(result.normal);
    result.tangent = float4(normalize(result.tangent.xyz), result.tangent.w);

    return result;
}