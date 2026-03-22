// Check Work Graph support.
D3D12_FEATURE_DATA_D3D12_OPTIONS21 options21 = {};
device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS21,
                             &options21, sizeof(options21));

if (options21.WorkGraphsTier < D3D12_WORK_GRAPHS_TIER_1_0)
{
    // Hardware does not support Work Graphs.
    // Fall back to fixed-dispatch adaptive sampling.
    return;
}