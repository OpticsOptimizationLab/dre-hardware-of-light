# GitHub Discussions Setup Guide — Volume 2

## Recommended Categories

### 1. **Q&A** (Questions & Answers)
Topic: DXR pipeline and integration questions

**Seed Posts:**
- "How to integrate DXR shaders into my DirectX 12 renderer?"
- "Understanding RTPSO subobjects and shader binding table layout"
- "ReSTIR DI: temporal reuse introducing fireflies at grazing angles"
- "SVGF edge weights: how to tune depth/normal thresholds?"
- "Acceleration structure refitting vs rebuild: when to use each?"

### 2. **Show and Tell**
Topic: Projects using DRE Vol. 2 code

**Seed Posts:**
- "Share your real-time path tracer screenshots"
- "NSight profiling results: where does your frame time go?"
- "ReSTIR DI/GI implementation: parameters and convergence"
- "Custom engine DXR integration: lessons learned"

### 3. **Engine Integration**
Topic: UE5, O3DE, custom engines

**Seed Posts:**
- "Integrating DRE shaders into Unreal Engine 5 Lumen"
- "O3DE Atom renderer: DXR pipeline modifications"
- "Building a custom DX12 engine: architecture decisions"
- "Comparing render graph implementations across engines"

### 4. **GPU Architecture & Profiling**
Topic: Occupancy, divergence, memory coalescing

**Seed Posts:**
- "NSight Compute occupancy analysis: register pressure optimization"
- "PIX timing captures: async compute overlap patterns"
- "Wave divergence in ReSTIR spatial reuse: measured impact"
- "NVIDIA Ada vs AMD RDNA 3: architectural differences"
- "Memory coalescing validation: structured buffer access patterns"

### 5. **ReSTIR & Denoising**
Topic: Parameter tuning and troubleshooting

**Seed Posts:**
- "ReSTIR DI: M cap and bias-variance tradeoff"
- "ReSTIR GI: 1-bounce vs multi-bounce indirect"
- "SVGF: temporal accumulation alpha tuning"
- "DLSS Ray Reconstruction: integration checklist"
- "World Radiance Cache: hash grid cell size recommendations"

### 6. **Advanced Topics**
Topic: Neural rendering, Work Graphs, SER

**Seed Posts:**
- "Gaussian Splatting: tile-based rasterization performance"
- "Neural Radiance Cache: training convergence and inference speed"
- "Shader Execution Reordering (Ada): measured coherence gains"
- "Work Graphs: adaptive SPP vs ExecuteIndirect fallback"

### 7. **Book Discussion**
Topic: Digital Rendering Engineering Vol. 2 manuscript

**Seed Posts:**
- "Errata: report errors in the book"
- "Chapter discussion: Vol. 2 Chapter 13 (Ray Tracing Architecture)"
- "Questions about frame budget calculations in Chapter 14"
- "Suggestions for Vol. 3 content"

---

## Initial Post Templates

### Welcome Post (Pin to top)

```markdown
# Welcome to DRE Vol. 2 Discussions!

This is the community space for Digital Rendering Engineering: The Hardware of Light companion code.

**What to expect:**
- DXR pipeline and integration help
- GPU profiling and optimization discussions
- Engine integration case studies (UE5, O3DE, custom)
- ReSTIR/SVGF parameter tuning advice
- Hardware architecture deep dives (NVIDIA Ada, AMD RDNA 3)

**Rules:**
1. Be respectful and professional
2. Search before posting (your question may be answered)
3. Include profiling data and hardware specs when asking for help
4. Share your integration experiences and benchmarks

**Resources:**
- [Validation Summary](VALIDATION_SUMMARY.md)
- [Vol. 1 Repository](https://github.com/OpticsOptimizationLab/dre-physics-of-light)
- [Vol. 1 White Furnace Test](https://github.com/OpticsOptimizationLab/dre-physics-of-light/tests/)

Let's build production-quality real-time path tracers!
```

---

### Q&A Seed Post

```markdown
# [Q&A] How to integrate DXR shaders into my DirectX 12 renderer?

I have a working DX12 rasterization renderer and want to add ray tracing using the DRE Vol. 2 shaders. What's the integration path?

**My current setup:**
- DirectX 12 Agility SDK 1.614
- RTX 4070 (Ada Lovelace)
- Existing G-Buffer pass (normals, albedo, depth)
- Deferred lighting with shadow maps

**Questions:**
1. Do I start with `DRE_RayGen.hlsl` or build acceleration structures first?
2. How do I connect the G-Buffer to the ray tracing pipeline?
3. What's the minimum RTPSO configuration to get shadows working?
4. Should I use ReSTIR DI immediately or start with simple direct lighting?

Has anyone done this integration? What was your approach?
```

---

### Show and Tell Seed Post

```markdown
# [Show and Tell] Real-time path tracer using DRE Vol. 2

Share your implementation screenshots, profiling results, and integration experience!

**Template:**

**Project:** [Name/link]
**Engine:** [UE5 / O3DE / Custom DX12]
**GPU:** [e.g., RTX 4090 Ada]
**Resolution:** [e.g., 1440p]
**Frame Budget:** [ms breakdown by pass]
**Techniques:** [e.g., ReSTIR DI, SVGF, 1spp]

**NSight profiling highlights:**
- G-Buffer: X ms
- ReSTIR DI: X ms
- DXR path trace: X ms
- SVGF denoise: X ms
- Total: X ms

**What worked well:**
- ...

**Challenges:**
- ...

**Questions:**
- ...
```

---

### Engine Integration Seed Post

```markdown
# [Engine Integration] Integrating DRE shaders into Unreal Engine 5

UE5 has native Lumen, but I want to replace it with DRE's ReSTIR + SVGF pipeline. Looking for integration advice.

**Approach:**
1. Disable Lumen GI
2. Add custom RDG passes for ReSTIR DI/GI
3. Replace TAA with SVGF temporal accumulation
4. Use UE5's G-Buffer as input

**Questions:**
- Has anyone done this? Is it feasible?
- How to handle UE5's existing acceleration structure management?
- Performance comparison: Lumen vs DRE ReSTIR?
- Shader hot reload: can I use DRE's `ShaderCompiler.cpp`?

Share your UE5 integration stories!
```

---

### GPU Profiling Seed Post

```markdown
# [GPU Profiling] NSight Compute occupancy analysis

Share your occupancy analysis results and register pressure optimization tips!

**Please include:**
- GPU model (e.g., RTX 4090 Ada - 128 SMs, 65,536 registers/SM)
- Shader being profiled (e.g., ReSTIR DI spatial reuse compute shader)
- NSight Compute metrics:
  - Theoretical occupancy
  - Achieved occupancy
  - Limiting factor (registers, shared memory, warps)
  - Register count per thread

**How to profile:**
```bash
ncu --set full --target-processes all -o profile.ncu-rep MyApp.exe
# Open in NSight Compute GUI, analyze Occupancy section
```

**My results (RTX 4090):**
- ReSTIR spatial reuse: 50% occupancy (register limited, 64 registers/thread)
- SVGF a-trous: 75% occupancy (minimal registers)
- PathTrace RayGen: 40% occupancy (payload size limit)

Let's share optimization strategies!
```

---

### ReSTIR Tuning Seed Post

```markdown
# [ReSTIR & Denoising] ReSTIR DI parameter tuning guide

ReSTIR DI has many parameters. Let's crowdsource tuning recommendations!

**Key parameters:**
- M cap (reservoir history length)
- Spatial radius
- Spatial sample count
- Temporal confidence threshold
- MIS weight calculation

**Scene-specific tuning:**

**Static indoor (Cornell box):**
- M cap: 20
- Spatial radius: 32px
- Spatial samples: 4
- Result: Converges in 10 frames, no visible bias

**Dynamic outdoor (moving camera):**
- M cap: 8 (shorter history for disocclusion)
- Spatial radius: 16px
- Spatial samples: 2
- Result: Responsive, some fireflies at sunset

**Your recommendations?**
Share your ReSTIR parameter sets and scene types!
```

---

### Book Errata Post

```markdown
# [Book Errata] Report errors here

Found a typo, code error, or incorrect equation in the manuscript? Report it here!

**Format:**
- **Location:** Volume 2, Chapter X, Section Y, Page/Line
- **Error:** [describe what's wrong]
- **Correction:** [suggest fix if known]

**Example:**
- **Location:** Vol. 2, Chapter 13.3, RTPSO code listing
- **Error:** Missing D3D12_RAYTRACING_SHADER_CONFIG for payload size
- **Correction:** Add shader config subobject before pipeline config

Confirmed errata will be compiled and published in a separate document.
```

---

## Moderation Guidelines

**Maintainer responses:**
- Aim for < 48h response time on Q&A
- Pin important discussions (welcome, errata, profiling guides)
- Mark solved questions with checkmark
- Lock off-topic or resolved threads

**Encourage:**
- Sharing profiling data (NSight, PIX captures)
- Hardware-specific benchmarks (NVIDIA vs AMD)
- Engine integration case studies
- Parameter tuning recommendations

**Discourage:**
- Asking for help with unrelated rendering engines
- Feature requests outside book scope
- Generic "how do I start raytracing" questions (direct to tutorials)
- Self-promotion without contribution

---

## Post ideas (ongoing)

**Weekly/Monthly:**
- "Hardware of the month" (e.g., RTX 5080 benchmarks when released)
- "Profiling challenge" (e.g., reduce ReSTIR DI pass by 20%)
- Highlight interesting Show & Tell posts

**When new content drops:**
- New engine integration guides
- Updated profiling methodologies
- Hardware architecture deep dives

**Community-driven:**
- Guest posts from engine developers
- Profiling tutorials from NSight experts
- Production case studies (games, films)
