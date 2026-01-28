# Milo832 - FPGA Rasterizing GPU

Milo832 is a tile-based rasterizing GPU implemented in VHDL, designed to run on resource-constrained FPGAs. It functions as a graphics coprocessor for the [m65832](https://github.com/your-username/m65832) retro computing project.

## Acknowledgments

The SIMT shader core in this project is a VHDL translation of the **SIMT-GPU-Core** by **Aritra Manna**. Many thanks to Aritra for creating and open-sourcing this excellent educational GPU implementation. The original SystemVerilog code was translated to VHDL for use in this project.

**Original Project:** [https://github.com/aritramanna/SIMT-GPU-Core](https://github.com/aritramanna/SIMT-GPU-Core)

---

## Overview

Milo832 is a **Unified Shader Architecture** GPU featuring:

- **Programmable SIMT Shader Cores** - Vertex and fragment shaders run on the same hardware
- **Tile-Based Rendering** - Memory-efficient rendering suitable for FPGA BRAM constraints
- **Hardware Texture Sampling** - Bilinear filtering with multiple texture formats
- **Fixed-Function Rasterization** - Triangle setup, edge walking, and fragment generation

### Target Platforms

| Platform | FPGA | Status |
|----------|------|--------|
| DE2-115 | Cyclone IV EP4CE115 | In Development |
| Kria KV260 | Zynq UltraScale+ XCK26 | Planned |

---

## Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         m65832 CPU                              │
│                    (Command Buffer Producer)                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │ System Bus
┌──────────────────────────▼──────────────────────────────────────┐
│                       Milo832 GPU                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Command   │  │  Triangle   │  │    Tile Rasterizer      │  │
│  │  Processor  │──│   Binner    │──│  (Edge Function Eval)   │  │
│  └─────────────┘  └─────────────┘  └───────────┬─────────────┘  │
│                                                │                │
│  ┌─────────────────────────────────────────────▼─────────────┐  │
│  │              Streaming Multiprocessor (SM)                │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐   │  │
│  │  │   ALU   │  │   FPU   │  │   SFU   │  │   Texture   │   │  │
│  │  │ 32-lane │  │ 32-lane │  │ 32-lane │  │    Unit     │   │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────────┘   │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                │                │
│  ┌─────────────────────────────────────────────▼─────────────┐  │
│  │                  ROP (Raster Operations)                  │  │
│  │            Blend, Depth Test, Tile Writeback              │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### SIMT Shader Core

The shader core implements a 5-stage pipeline executing 32 threads in lockstep (one warp):

| Stage | Function |
|-------|----------|
| **IF** | Instruction Fetch with round-robin warp scheduling |
| **ID** | Decode, scoreboard check, hazard detection |
| **OC** | Operand Collection from banked register file |
| **EX** | 32-lane parallel execution (ALU/FPU/SFU) |
| **WB** | Writeback with out-of-order memory completion |

**Key Features:**
- 24 warps per SM (768 threads resident)
- 16KB shared memory with 32-bank conflict detection
- Hardware divergence stack (SSY/JOIN)
- Barrier synchronization with epoch consistency
- Non-blocking memory with 64-entry MSHR per warp

### Tile-Based Rasterizer

The rasterizer processes geometry in screen-space tiles to minimize memory bandwidth:

1. **Triangle Setup** - Compute edge equations from vertex positions
2. **Binning** - Assign triangles to overlapping tiles
3. **Tile Rasterization** - Per-pixel edge function evaluation
4. **Fragment Generation** - Barycentric interpolation of attributes

Tile size is configurable (default 16x16 pixels) to balance BRAM usage vs. overdraw.

### Texture Unit

The texture sampling pipeline supports:

| Format | Description |
|--------|-------------|
| RGBA8888 | 32-bit true color |
| RGBA4444 | 16-bit with alpha |
| RGB565 | 16-bit no alpha |
| PAL8 | 8-bit paletized |
| PAL4 | 4-bit paletized |
| ETC1/ETC2 | Compressed (planned) |

**Filtering:**
- Nearest neighbor
- Bilinear with mip-level selection (no trilinear)

**Wrap Modes:**
- Repeat, Clamp, Mirror

---

## Current Status

### Implemented

- [x] SIMT shader core (VHDL translation from SystemVerilog)
- [x] 32-lane ALU, FPU, SFU execution units
- [x] Operand collector with bank conflict handling
- [x] Shared memory subsystem
- [x] Tile-based rasterizer with barycentric interpolation
- [x] Texture sampler (nearest/bilinear, wrap modes)
- [x] System bus infrastructure

### In Progress

- [ ] Texture unit SIMT integration (32 parallel samplers)
- [ ] ETC1/ETC2 texture decompression
- [ ] ROP (blend, depth test)
- [ ] Command processor

### Not Yet Implemented

- [ ] Vertex fetch / input assembly
- [ ] Primitive assembly (triangle setup from vertex shader output)
- [ ] Texture cache with request coalescing
- [ ] L1 cache for global memory
- [ ] Multi-SM scaling
- [ ] FPGA synthesis and timing closure

---

## Relationship to m65832

Milo832 is the graphics subsystem for the **m65832** retro computing project. The two components share:

- **System Bus** - Multi-master bus developed here, canonical version in m65832
- **Memory Map** - Shared DDR4/SDRAM address space
- **Command Model** - CPU submits command buffers, GPU processes asynchronously

The m65832 CPU handles:
- Application logic and game code
- Geometry transformation (optional - can also run on GPU)
- Command buffer construction
- Display timing and scanout

Milo832 handles:
- Vertex shading (programmable)
- Rasterization (fixed-function)
- Fragment shading (programmable)
- Texture sampling
- Framebuffer operations

---

## Directory Structure

```
milo832/
├── RTL/
│   ├── Core/           # SIMT shader core
│   │   ├── streaming_multiprocessor.vhd
│   │   ├── simt_pkg.vhd
│   │   └── shared_memory.vhd
│   ├── Compute/        # Execution units
│   │   ├── int_alu.vhd
│   │   ├── fpu.vhd
│   │   └── sfu.vhd
│   ├── Memory/         # Memory subsystem
│   │   ├── operand_collector.vhd
│   │   └── fifo.vhd
│   ├── graphics/       # Rasterization pipeline
│   │   ├── tile_rasterizer.vhd
│   │   ├── texture_sampler.vhd
│   │   ├── texture_unit.vhd
│   │   └── rop.vhd
│   └── bus/            # System interconnect
│       ├── system_bus.vhd
│       └── bus_arbiter.vhd
├── TB/                 # VHDL testbenches
├── docs/               # Design documentation
└── README.md
```

---

## Building and Testing

### Prerequisites

- **GHDL** - VHDL simulator (tested with ghdl-llvm)
- **Python 3** with Pillow - For image output visualization

### Running Tests

```bash
# Compile and run a testbench
cd TB
ghdl -a --std=08 ../RTL/Core/simt_pkg.vhd
ghdl -a --std=08 ../RTL/Core/streaming_multiprocessor.vhd
ghdl -a --std=08 tb_sm_basic.vhd
ghdl -e --std=08 tb_sm_basic
ghdl -r --std=08 tb_sm_basic
```

### Generating Render Output

Testbenches output PPM images that can be converted to PNG:

```bash
# Convert PPM to PNG (macOS)
sips -s format png output.ppm --out output.png

# Or with ImageMagick
convert output.ppm output.png
```

---

## Future Work

1. **Complete the graphics pipeline** - Integrate all stages from vertex fetch to framebuffer write
2. **FPGA synthesis** - Target DE2-115 first, then KV260
3. **Performance optimization** - Balance resource usage vs. throughput
4. **Driver development** - CPU-side library for m65832 integration
5. **Demo applications** - 3D rendering demos showcasing capabilities

---

## License

MIT License - See [LICENSE](LICENSE) file.

---

## References

- [SIMT-GPU-Core](https://github.com/aritramanna/SIMT-GPU-Core) - Original SystemVerilog implementation by Aritra Manna
- [Tile-Based Rendering](https://developer.arm.com/documentation/102662/latest) - ARM Mali architecture guide
- [GPU Gems](https://developer.nvidia.com/gpugems/gpugems/contributors) - NVIDIA GPU programming resources
