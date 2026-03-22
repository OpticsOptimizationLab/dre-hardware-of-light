// SVGF_Denoiser.hlsl
float3 currentRadiance = g_NoisyInput[pixel];
float2 velocity = g_Velocity[pixel];
float2 historyUV = (float2(pixel) + 0.5f) / g_Resolution - velocity;

float3 historyRadiance = g_History[historyPingPong].SampleLevel(
    g_LinearClamp, historyUV, 0);

// Disocclusion detection: new surface visible that wasn't last frame.
float depthCurrent = g_Depth[pixel];
float depthHistory = g_HistoryDepth.SampleLevel(g_LinearClamp, historyUV, 0);
float3 normalCurrent = g_GBufferB[pixel].xyz;
float3 normalHistory = g_HistoryNormal.SampleLevel(g_LinearClamp, historyUV, 0).xyz;

bool disoccluded = abs(depthCurrent - depthHistory) / max(depthCurrent, 0.001f) > 0.1f
                || dot(normalCurrent, normalHistory) < 0.9f;

// Blend factor: high alpha = trust current (noisy but correct).
// Low alpha = trust history (smooth but potentially stale).
float alpha = disoccluded ? 1.0f : 0.05f; // 5% blend = 20-frame effective average
float3 accumulated = lerp(historyRadiance, currentRadiance, alpha);

// Write to current history buffer (ping-pong from § 12.5).
g_History[currentPingPong][pixel] = float4(accumulated, 1.0f);