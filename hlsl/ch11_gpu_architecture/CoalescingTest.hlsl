// CoalescingTest.hlsl
[numthreads(8, 8, 1)]
void CS_PathTraceSecondary(uint2 pixel : SV_DispatchThreadID)
{
    float4 gbufferA = g_GBufferA[pixel]; // Each thread reads adjacent pixel.
}