"""
NRC_Training.py
Digital Rendering Engineering, Vol. 2 — The Hardware of Light
Chapter 15.2 — Neural Radiance Cache: Offline Training Experimentation

Offline PyTorch prototype for NRC training.
Use for parameter tuning and architecture validation before GPU implementation.
The production implementation runs fully on GPU (NRC_Train.hlsl in the book § 15.2).

Architecture:
    Stage 1: Multiresolution hash grid encoding (16 levels × 4 features = 64 dims)
    Stage 2: MLP (71 → 64 → 64 → 64 → 3), ReLU hidden, linear output
    Training: Adam, lr=0.001, online batches of 4096 samples per frame

Usage:
    pip install torch numpy
    python NRC_Training.py --scene my_scene.json --frames 60
"""

import argparse
import json
import math
import sys
import time

try:
    import torch
    import torch.nn as nn
    import numpy as np
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False
    print("ERROR: PyTorch not available. Install with: pip install torch numpy")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# NRC PARAMETERS (must match NRC_Query.hlsl and NRC_Train.hlsl)
# ─────────────────────────────────────────────────────────────────────────────

HASH_LEVELS        = 16
FEATURES_PER_LEVEL = 4
HASH_TABLE_SIZE    = 2 ** 19   # 512K entries
HASH_FEATURE_DIM   = HASH_LEVELS * FEATURES_PER_LEVEL  # 64

MLP_INPUT_DIM  = HASH_FEATURE_DIM + 7  # 64 + 7 (normal, viewDir, roughness)
MLP_HIDDEN_DIM = 64
MLP_OUTPUT_DIM = 3  # RGB

TRAINING_LR           = 0.001
TRAINING_BATCHES      = 4      # Batches per simulated frame
BATCH_SIZE            = 4096   # Samples per batch
CONVERGENCE_FRAMES    = 30     # Frames to stable output


# ─────────────────────────────────────────────────────────────────────────────
# MULTIRESOLUTION HASH GRID (§ 15.2, PyTorch version)
# Maps world position → 64-dimensional feature vector.
# Production equivalent: LookupHashLevel() in NRC_Query.hlsl
# ─────────────────────────────────────────────────────────────────────────────

class MultiresHashGrid(nn.Module):
    def __init__(self, hash_table_size=HASH_TABLE_SIZE,
                 num_levels=HASH_LEVELS, features_per_level=FEATURES_PER_LEVEL):
        super().__init__()
        self.hash_table_size    = hash_table_size
        self.num_levels         = num_levels
        self.features_per_level = features_per_level

        # Learnable hash table: one table shared across all levels (with level offset).
        # Production: separate table per level for better cache locality.
        self.hash_table = nn.Embedding(
            hash_table_size * num_levels,
            features_per_level)
        nn.init.uniform_(self.hash_table.weight, -1e-4, 1e-4)

    def hash_cell(self, cell_coords, level):
        """Map 3D cell coordinates to hash table indices."""
        x, y, z = cell_coords[..., 0], cell_coords[..., 1], cell_coords[..., 2]
        h = (x * 2654435761) ^ (y * 805459861) ^ (z * 3674653429)
        return (h % self.hash_table_size + level * self.hash_table_size).long()

    def forward(self, world_pos, scene_bounds_min, scene_bounds_extent):
        """
        world_pos: (B, 3) world-space positions
        Returns: (B, HASH_FEATURE_DIM) concatenated features
        """
        normalized = (world_pos - scene_bounds_min) / scene_bounds_extent
        normalized = torch.clamp(normalized, 0.0, 1.0)

        all_features = []

        for level in range(self.num_levels):
            scale = (2 ** level) * 16.0
            scaled = normalized * scale

            cell = scaled.floor().long()
            frac = scaled - scaled.floor()

            # Trilinear interpolation over 8 corners.
            level_features = torch.zeros(world_pos.shape[0], self.features_per_level,
                                          device=world_pos.device)

            for i in range(8):
                corner = cell + torch.tensor(
                    [i & 1, (i >> 1) & 1, (i >> 2) & 1],
                    device=world_pos.device).long()

                idx   = self.hash_cell(corner, level)
                feat  = self.hash_table(idx)

                wx = frac[:, 0:1] if (i & 1) else (1 - frac[:, 0:1])
                wy = frac[:, 1:2] if ((i >> 1) & 1) else (1 - frac[:, 1:2])
                wz = frac[:, 2:3] if ((i >> 2) & 1) else (1 - frac[:, 2:3])

                level_features = level_features + wx * wy * wz * feat

            all_features.append(level_features)

        return torch.cat(all_features, dim=-1)  # (B, 64)


# ─────────────────────────────────────────────────────────────────────────────
# NRC MODEL: HASH GRID + MLP (§ 15.2)
# ─────────────────────────────────────────────────────────────────────────────

class NRCModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.hash_grid = MultiresHashGrid()

        # MLP: 71 → 64 → 64 → 64 → 3
        # ~12,500 parameters total (trivial, fits in SM L1 cache)
        self.mlp = nn.Sequential(
            nn.Linear(MLP_INPUT_DIM,  MLP_HIDDEN_DIM), nn.ReLU(),
            nn.Linear(MLP_HIDDEN_DIM, MLP_HIDDEN_DIM), nn.ReLU(),
            nn.Linear(MLP_HIDDEN_DIM, MLP_HIDDEN_DIM), nn.ReLU(),
            nn.Linear(MLP_HIDDEN_DIM, MLP_OUTPUT_DIM),  # Linear output
        )

    def forward(self, world_pos, normal, view_dir, roughness,
                scene_bounds_min, scene_bounds_extent):
        """
        world_pos:  (B, 3) float
        normal:     (B, 3) float
        view_dir:   (B, 3) float
        roughness:  (B, 1) float
        Returns:    (B, 3) predicted radiance (non-negative)
        """
        hash_feats  = self.hash_grid(world_pos, scene_bounds_min, scene_bounds_extent)
        surface_in  = torch.cat([normal, view_dir, roughness], dim=-1)  # (B, 7)
        full_input  = torch.cat([hash_feats, surface_in], dim=-1)       # (B, 71)

        output = self.mlp(full_input)
        return torch.clamp(output, min=0.0)  # Radiance is non-negative


# ─────────────────────────────────────────────────────────────────────────────
# SYNTHETIC TRAINING DATA GENERATOR
# Replace with actual G-Buffer samples + path traced ground truth.
# ─────────────────────────────────────────────────────────────────────────────

def generate_synthetic_batch(batch_size, device, scene_extent=10.0):
    """
    Generate synthetic training samples for testing convergence.
    Production: sample G-Buffer + trace 1-2 indirect bounces (NRC_Train.hlsl).
    """
    world_pos  = (torch.rand(batch_size, 3, device=device) - 0.5) * scene_extent
    normal     = torch.randn(batch_size, 3, device=device)
    normal     = nn.functional.normalize(normal, dim=-1)
    view_dir   = torch.randn(batch_size, 3, device=device)
    view_dir   = nn.functional.normalize(view_dir, dim=-1)
    roughness  = torch.rand(batch_size, 1, device=device)

    # Synthetic ground truth: simple directional lighting for testing.
    sun_dir = torch.tensor([0.577, 0.577, 0.577], device=device)
    cos_theta = torch.clamp((normal * sun_dir).sum(-1, keepdim=True), 0, 1)
    radiance  = cos_theta * torch.tensor([1.0, 0.95, 0.8], device=device).unsqueeze(0)

    return world_pos, normal, view_dir, roughness, radiance


# ─────────────────────────────────────────────────────────────────────────────
# TRAINING LOOP (§ 15.2)
# Simulates online per-frame training: TRAINING_BATCHES × BATCH_SIZE per frame.
# Convergence target: < 5% MSE in ~30 frames.
# ─────────────────────────────────────────────────────────────────────────────

def train(args):
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}")

    model     = NRCModel().to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=TRAINING_LR,
                                  betas=(0.9, 0.999), eps=1e-8)
    criterion = nn.MSELoss()

    # Scene bounds (normalize world positions to [0, 1]).
    scene_bounds_min    = torch.tensor([-5.0, -5.0, -5.0], device=device)
    scene_bounds_extent = torch.tensor([10.0,  10.0, 10.0], device=device)

    total_params = sum(p.numel() for p in model.parameters())
    print(f"NRC parameters: {total_params:,} (hash grid: {HASH_TABLE_SIZE * HASH_LEVELS * FEATURES_PER_LEVEL:,}, "
          f"MLP: ~{total_params - HASH_TABLE_SIZE * HASH_LEVELS * FEATURES_PER_LEVEL:,})")

    print(f"\nTraining: {args.frames} simulated frames × {TRAINING_BATCHES} batches × {BATCH_SIZE} samples")
    print(f"Convergence target: MSE < 0.05 (5%) by frame {CONVERGENCE_FRAMES}")
    print("-" * 60)

    converged_frame = None
    start_time = time.time()

    for frame in range(args.frames):
        frame_loss = 0.0

        for batch in range(TRAINING_BATCHES):
            world_pos, normal, view_dir, roughness, radiance_gt = generate_synthetic_batch(
                BATCH_SIZE, device)

            # Forward pass.
            radiance_pred = model(world_pos, normal, view_dir, roughness,
                                   scene_bounds_min, scene_bounds_extent)

            # L2 loss.
            loss = criterion(radiance_pred, radiance_gt)
            frame_loss += loss.item()

            # Backpropagate.
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

        avg_loss = frame_loss / TRAINING_BATCHES

        if frame % 5 == 0 or frame < 5:
            elapsed = time.time() - start_time
            print(f"  Frame {frame:3d}/{args.frames} | MSE: {avg_loss:.6f} | "
                  f"Elapsed: {elapsed:.1f}s")

        if converged_frame is None and avg_loss < 0.05:
            converged_frame = frame
            print(f"  CONVERGED at frame {frame} (MSE {avg_loss:.4f} < 5%)")

    print("-" * 60)
    if converged_frame is not None:
        print(f"NRC converged in {converged_frame} frames. Production target: ~{CONVERGENCE_FRAMES} frames.")
    else:
        print(f"NRC did not converge in {args.frames} frames. "
              f"Check scene bounds, learning rate, or architecture.")

    # Export model weights for GPU implementation.
    if args.export:
        torch.save(model.state_dict(), args.export)
        print(f"Weights saved to: {args.export}")


def main():
    parser = argparse.ArgumentParser(description="NRC Offline Training Prototype")
    parser.add_argument("--frames", type=int, default=60,
                        help="Number of simulated frames to train")
    parser.add_argument("--export", type=str, default=None,
                        help="Export trained weights to .pt file")
    args = parser.parse_args()
    train(args)


if __name__ == "__main__":
    main()
