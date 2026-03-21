"""
white_furnace_dxr.py
Digital Rendering Engineering, Vol. 2 — The Hardware of Light
Chapter 13.7 — RT Validation Protocol

White Furnace Test: DXR pipeline validation.
Runs the furnace across roughness × NdotV parameter sweep.
All 45 configurations must pass within 1% tolerance.

Usage:
    python validation/white_furnace_dxr.py --renderer DRERenderer.exe

The renderer must support --furnace-mode flag and output a .exr file.
"""

import argparse
import subprocess
import sys
import os

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

# ─────────────────────────────────────────────────────────────────────────────
# TEST PARAMETERS (§ 13.7 Workbench 13.7.A)
# All 45 configurations (9 roughness × 5 NdotV) must pass.
# ─────────────────────────────────────────────────────────────────────────────

ROUGHNESS_SWEEP = [0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0]
NDOTV_SWEEP     = [0.1, 0.3, 0.5, 0.7, 0.9]
TOLERANCE       = 0.01   # 1% energy conservation error acceptable
SPP             = 256    # Samples per pixel for variance reduction

# Furnace test scene: white environment (radiance = 1 from all directions),
# white albedo (1.0), metallic=0 dielectric.
# Correct output: uniform image with value 1.0 across all pixels.
# Energy not conserved → value < 1.0 (absorption leak).
# Energy gain (bug) → value > 1.0.


def load_exr(path):
    """Load an EXR file as a numpy array. Requires OpenEXR or imageio[freeimage]."""
    try:
        import imageio
        img = imageio.imread(path, format="EXR-FI")
        return np.array(img, dtype=np.float32)
    except Exception:
        # Fallback: read a simple CSV output if EXR not available
        # Renderer should output mean RGB as CSV when --output-format csv is passed.
        with open(path.replace(".exr", "_mean.csv")) as f:
            vals = [float(x) for x in f.read().strip().split(",")]
        return np.array([[vals]])


def run_furnace(renderer_path, roughness, ndotv, spp, output_path):
    """Render one furnace configuration. Returns mean RGB or None on failure."""
    cmd = [
        renderer_path,
        "--scene", "furnace_quad.gltf",
        "--furnace-mode",
        f"--roughness={roughness:.4f}",
        f"--ndotv={ndotv:.4f}",
        f"--spp={spp}",
        "--output", output_path,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"  RENDER FAILED (roughness={roughness:.2f}, NdotV={ndotv:.1f}):")
        print(f"  {result.stderr.strip()}")
        return None

    if not os.path.exists(output_path):
        print(f"  OUTPUT FILE NOT FOUND: {output_path}")
        return None

    try:
        if HAS_NUMPY:
            img = load_exr(output_path)
            return np.mean(img, axis=(0, 1))
        else:
            # Without numpy: read mean from a sidecar file
            with open(output_path.replace(".exr", "_mean.csv")) as f:
                vals = [float(x) for x in f.read().strip().split(",")]
            return vals[:3]
    except Exception as e:
        print(f"  FAILED TO READ OUTPUT: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(
        description="DRE White Furnace Test — DXR Pipeline Validation"
    )
    parser.add_argument("--renderer", default="DRERenderer.exe",
                        help="Path to the DRE renderer executable")
    parser.add_argument("--spp", type=int, default=SPP)
    parser.add_argument("--tolerance", type=float, default=TOLERANCE)
    args = parser.parse_args()

    print("=" * 60)
    print("WHITE FURNACE TEST — DXR PIPELINE")
    print(f"Renderer: {args.renderer}")
    print(f"SPP: {args.spp}  |  Tolerance: {args.tolerance*100:.1f}%")
    print(f"Configurations: {len(ROUGHNESS_SWEEP)} × {len(NDOTV_SWEEP)} = "
          f"{len(ROUGHNESS_SWEEP) * len(NDOTV_SWEEP)} total")
    print("=" * 60)

    failures = 0
    total    = 0
    output_path = "furnace_output.exr"

    for roughness in ROUGHNESS_SWEEP:
        for ndotv in NDOTV_SWEEP:
            total += 1
            mean = run_furnace(args.renderer, roughness, ndotv, args.spp, output_path)

            if mean is None:
                failures += 1
                continue

            # All channels should be 1.0 for a white furnace.
            if HAS_NUMPY:
                error = float(np.max(np.abs(np.array(mean) - 1.0)))
            else:
                error = max(abs(v - 1.0) for v in mean[:3])

            status = "PASS" if error <= args.tolerance else "FAIL"
            if status == "FAIL":
                failures += 1

            print(f"  roughness={roughness:.2f}  NdotV={ndotv:.1f} "
                  f"| output=({mean[0]:.4f}, {mean[1]:.4f}, {mean[2]:.4f}) "
                  f"| error={error:.4f} | {status}")

    print("=" * 60)
    print(f"RESULTS: {total - failures}/{total} PASSED")

    if failures > 0:
        print()
        print("DIAGNOSIS GUIDE:")
        print("  All roughness values fail equally:")
        print("    → Bug in throughput accumulation or Russian Roulette weight")
        print("  Only low roughness fails (< 0.1):")
        print("    → Bug in GGX NDF normalization or VNDF sampling")
        print("  Only high roughness fails (> 0.9):")
        print("    → Multiple scattering compensation missing (see Vol. 1 § 6.3)")
        print("  All NdotV=0.1 fail:")
        print("    → Fresnel at grazing angles incorrect")
        print("  Passes on flat quad, fails on sphere/torus:")
        print("    → Normal not transformed via ObjectToWorld3x4() in ClosestHit")
        print()
        print("ACTION: Fix failing configurations before proceeding to production.")
        sys.exit(1)
    else:
        print("DXR pipeline conserves energy across all 45 configurations.")
        print("Pipeline is validated for production use.")
        sys.exit(0)


if __name__ == "__main__":
    main()
