// ReSTIR_GI.hlsl
struct GIReservoir
{
    float3 secondaryHitPos;     // Where the indirect ray hit
    float3 secondaryHitNormal;  // Normal at the indirect hit point
    float3 secondaryRadiance;   // Outgoing radiance at that hit (direct + cached indirect)
    float  weightSum;
    float  W;
    uint   M;
};