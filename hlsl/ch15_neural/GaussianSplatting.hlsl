// TRAINING FORMAT, used during Gaussian optimization (offline).
// Full precision: 232 bytes per Gaussian.
struct Gaussian3D_Training
{
    float3   position;    // World-space center μ                   , 12 bytes
    float3x3 cov3D;       // Full 3×3 covariance (9 floats, 6 unique), 36 bytes
    float    opacity;     // α ∈ [0, 1]                             ,  4 bytes
    float    shCoeffs[48];// 48 × float32 SH (order 3, 3 channels)  ,192 bytes
};                        // Total: 232 bytes

// PRODUCTION FORMAT, read by the runtime rasterizer (DX12 StructuredBuffer).
// Compact: uses quaternion+scale decomposition + FP16. 40 bytes.
struct Gaussian3D_RT
{
    float16_t3 position;   // float16 position (6 bytes), sufficient for world-space
    float16_t4 rotation;   // Unit quaternion (8 bytes) , replaces full 3×3 cov
    float16_t3 scale;      // Log-scale (6 bytes)       , diagonal S in Σ = RSS^T R^T
    float16_t  opacity;    // α (2 bytes)
    uint       shCoeffs[9];// 18 × float16 SH (order 1 = 9 coefs), 36 bytes
};                         // Total: 58 bytes (or 40 bytes for order-0 SH = no view-dependence)
// At 3M Gaussians: 58 × 3,000,000 = 174 MB (production RT format, order 1 SH)