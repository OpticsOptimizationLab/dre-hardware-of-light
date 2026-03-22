#!/usr/bin/env python3
"""
build_shaders.py
Compile all HLSL shaders for DRE Vol. 2 using DXC.
Validates syntax and generates .dxil binaries.
"""
import subprocess
import sys
from pathlib import Path

DXC = r"C:\Users\jean1\AppData\Local\Microsoft\WinGet\Packages\Microsoft.DirectX.ShaderCompiler_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\x64\dxc.exe"
ROOT = Path(__file__).parent
HLSL_DIR = ROOT / "hlsl"
OUTPUT_DIR = ROOT / "build" / "shaders"
VOL1_PATH = ROOT / "deps" / "dre-physics-of-light"

# Shader compilation configurations
SHADERS = [
    # Ray tracing library shaders (lib_6_6)
    {"file": "ch13_ray_tracing/DRE_RayGen.hlsl", "profile": "lib_6_6", "entry": None},
    {"file": "ch13_ray_tracing/DRE_ClosestHit.hlsl", "profile": "lib_6_6", "entry": None},
    {"file": "ch13_ray_tracing/DRE_Miss.hlsl", "profile": "lib_6_6", "entry": None},

    # Compute shaders (cs_6_6)
    {"file": "ch11_gpu_architecture/DiagnoseDivergence.hlsl", "profile": "cs_6_6", "entry": "CS_MeasureDivergence"},
    {"file": "ch11_gpu_architecture/CoalescingTest.hlsl", "profile": "cs_6_6", "entry": "CS_CoalescingTest"},

    {"file": "ch13_ray_tracing/InlineRayTracing.hlsl", "profile": "cs_6_6", "entry": "CS_ShadowTrace"},

    {"file": "ch14_realtime_pt/ReSTIR_DI.hlsl", "profile": "cs_6_6", "entry": "CS_InitialCandidates"},
    {"file": "ch14_realtime_pt/ReSTIR_GI.hlsl", "profile": "cs_6_6", "entry": "CS_GenerateGIReservoirs"},
    {"file": "ch14_realtime_pt/SVGF_Denoiser.hlsl", "profile": "cs_6_6", "entry": "CS_TemporalAccumulate"},
    {"file": "ch14_realtime_pt/WRC.hlsl", "profile": "cs_6_6", "entry": "CS_UpdateRadianceCache"},
    {"file": "ch14_realtime_pt/VolumeMarcher.hlsl", "profile": "cs_6_6", "entry": "CS_MarchVolume"},

    {"file": "ch15_neural/GaussianSplatting.hlsl", "profile": "cs_6_6", "entry": "CS_ProjectGaussians"},
    {"file": "ch15_neural/GaussianSorting.hlsl", "profile": "cs_6_6", "entry": "CS_RadixSort"},
    {"file": "ch15_neural/NRC_Query.hlsl", "profile": "cs_6_6", "entry": "CS_QueryNRC"},
]

def compile_shader(shader_config):
    """Compile a single shader with DXC."""
    hlsl_file = HLSL_DIR / shader_config["file"]
    profile = shader_config["profile"]
    entry = shader_config["entry"]

    if not hlsl_file.exists():
        print(f"  WARNING: File not found: {hlsl_file}")
        return False

    # Output path
    stem = hlsl_file.stem
    if entry:
        output_name = f"{stem}_{entry}.dxil"
    else:
        output_name = f"{stem}.dxil"

    output_file = OUTPUT_DIR / output_name
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Build DXC command
    cmd = [DXC, "-T", profile]

    if entry:
        cmd.extend(["-E", entry])

    # Include paths
    cmd.extend(["-I", str(HLSL_DIR)])
    cmd.extend(["-I", str(VOL1_PATH / "hlsl")])

    # Output
    cmd.extend(["-Fo", str(output_file)])

    # Validation and optimization
    cmd.extend(["-Zi", "-Qembed_debug"])  # Debug info
    cmd.extend(["-O3"])  # Optimization

    # Input file
    cmd.append(str(hlsl_file))

    # Execute
    print(f"  Compiling: {shader_config['file']}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"    FAILED!")
        print(f"    {result.stderr}")
        return False

    print(f"    OK -> {output_name}")
    return True

def main():
    print("=" * 70)
    print("  DRE Vol. 2 Shader Build — DXC Validation")
    print("=" * 70)
    print(f"  DXC: {DXC}")
    print(f"  Output: {OUTPUT_DIR}")
    print("-" * 70)

    if not Path(DXC).exists():
        print(f"ERROR: DXC not found at {DXC}")
        return 1

    if not VOL1_PATH.exists():
        print(f"ERROR: Vol. 1 dependency not found at {VOL1_PATH}")
        print("Run: git submodule update --init --recursive")
        return 1

    success_count = 0
    fail_count = 0

    for shader in SHADERS:
        if compile_shader(shader):
            success_count += 1
        else:
            fail_count += 1

    print("-" * 70)
    print(f"  Results: {success_count} passed, {fail_count} failed")
    print("=" * 70)

    return 0 if fail_count == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
