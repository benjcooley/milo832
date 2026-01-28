# Milo832 GPU Architecture

## Overview

Milo832 is a programmable shader GPU designed as a coprocessor for the m65832 CPU. It implements a SIMT (Single Instruction, Multiple Threads) architecture with programmable vertex and fragment shaders, hardware rasterization, and texture sampling.

This design is based on the SIMT-GPU-Core by Aritra Manna, translated to VHDL and extended with graphics pipeline stages.

## Target FPGA Platforms

### AMD Xilinx Kria KV260 (Primary Target)
| Resource | Available | Estimated Usage |
|----------|-----------|-----------------|
| LUTs | ~256K | ~120K (47%) |
| Block RAM | 144 blocks (26.6 Mb) | ~80 blocks |
| UltraRAM | 64 blocks | ~32 blocks |
| DSP Slices | 1,248 | ~400 |
| DDR4 Memory | 4GB | Framebuffer, Textures |

**Recommended Configuration:**
- 2 Streaming Multiprocessors (SMs)
- 8 warps per SM (256 threads per SM)
- 16KB shared memory per SM
- 64KB texture cache
- 128KB tile buffer
- 1920x1080 framebuffer support

### Intel/Altera DE2-115 (Secondary Target)
| Resource | Available | Estimated Usage |
|----------|-----------|-----------------|
| Logic Elements | 114,480 | ~80K (70%) |
| Embedded Memory | 3,888 Kb | ~3,000 Kb |
| Multipliers | 266 | ~200 |
| SDRAM | 128MB | Framebuffer, Textures |

**Recommended Configuration:**
- 1 Streaming Multiprocessor (SM)
- 4 warps per SM (128 threads)
- 8KB shared memory
- 16KB texture cache
- 32KB tile buffer
- 640x480 framebuffer support

## Architecture Block Diagram

```
                    +------------------+
                    |   m65832 CPU     |
                    |   (Host)         |
                    +--------+---------+
                             |
                    Command Interface
                             |
                    +--------v---------+
                    |  Command         |
                    |  Processor       |
                    +--------+---------+
                             |
         +-------------------+-------------------+
         |                   |                   |
+--------v-------+  +--------v-------+  +--------v-------+
|   Vertex       |  |   Rasterizer   |  |   Fragment     |
|   Shader (SM)  |  |                |  |   Shader (SM)  |
+--------+-------+  +--------+-------+  +--------+-------+
         |                   |                   |
         +-------------------+-------------------+
                             |
                    +--------v---------+
                    |  Texture         |
                    |  Sampler         |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  ROP (Raster     |
                    |  Operations)     |
                    +--------+---------+
                             |
                    +--------v---------+
                    |  Framebuffer     |
                    |  (DDR/SDRAM)     |
                    +------------------+
```

## Streaming Multiprocessor (SM) Architecture

Each SM implements a 5-stage pipeline:

### Pipeline Stages

1. **IF (Instruction Fetch)**
   - Round-robin warp scheduler
   - Dual-issue capability (2 instructions/cycle)
   - Branch prediction

2. **ID (Instruction Decode)**
   - 64-bit instruction decode
   - Scoreboard dependency checking
   - Predicate evaluation

3. **OC (Operand Collection)**
   - 4-bank register file
   - Bank conflict resolution
   - Writeback forwarding

4. **EX (Execute)**
   - Integer ALU (32-lane SIMD)
   - FPU (IEEE-754 single precision)
   - SFU (Special Function Unit)
   - Load/Store Unit

5. **WB (Writeback)**
   - Dual writeback ports
   - Scoreboard clear
   - Predicate writeback

### Execution Units

| Unit | Operations | Latency |
|------|------------|---------|
| ALU | ADD, SUB, MUL, AND, OR, XOR, SHL, SHR | 1 cycle |
| FPU | FADD, FSUB, FMUL, FDIV, FFMA | 4 cycles |
| SFU | SIN, COS, RCP, RSQ, SQRT, EXP2, LOG2 | 8 cycles |
| LSU | LDR, STR, LDS, STS | Variable |

### Memory Hierarchy

```
+------------------+
|  Register File   |  64 regs x 32 threads x 32 bits = 8KB per warp
+------------------+
         |
+------------------+
|  Shared Memory   |  16KB per SM (32 banks)
+------------------+
         |
+------------------+
|  L1 Cache        |  16KB per SM
+------------------+
         |
+------------------+
|  L2 Cache        |  256KB shared (KV260 only)
+------------------+
         |
+------------------+
|  Global Memory   |  DDR4/SDRAM
+------------------+
```

## Graphics Pipeline Extensions

### Rasterizer Module

The rasterizer converts triangles to fragments using a tile-based approach:

**Features:**
- Edge function evaluation
- Perspective-correct interpolation
- Tile-based rendering (16x16 or 32x32 tiles)
- Early depth test
- Scissor/viewport clipping

**Algorithm:**
1. Receive triangle vertices from vertex shader
2. Compute bounding box
3. For each tile in bounding box:
   - For each pixel in tile:
     - Evaluate edge functions
     - If inside triangle, generate fragment
4. Output fragments to fragment shader queue

### Texture Sampler Module

**Features:**
- Bilinear filtering
- Mipmapping support
- Multiple texture formats (RGBA8888, RGB565, etc.)
- Texture coordinate wrapping modes
- Texture cache (16KB)

**Supported Formats:**
| Format | Bits/Pixel | Description |
|--------|------------|-------------|
| RGBA8888 | 32 | Full color + alpha |
| RGB565 | 16 | Reduced color, no alpha |
| RGBA4444 | 16 | Reduced color + alpha |
| L8 | 8 | Luminance only |
| A8 | 8 | Alpha only |

### ROP (Raster Operations Pipeline)

**Features:**
- Alpha blending
- Depth test (Z-buffer)
- Stencil operations
- Color write masks

## Instruction Set Architecture

### Instruction Encoding (64-bit)

```
63      56 55      48 47      40 39      32 31    28 27            20 19                   0
+----------+----------+----------+----------+--------+----------------+---------------------+
|  OPCODE  |    RD    |   RS1    |   RS2    |  PRED  |  RS3 / EXTRA   |      IMMEDIATE      |
+----------+----------+----------+----------+--------+----------------+---------------------+
|  8-bits  |  8-bits  |  8-bits  |  8-bits  | 4-bits |     8-bits     |       20-bits       |
```

### Opcode Categories

| Category | Opcodes |
|----------|---------|
| Integer Arithmetic | ADD, SUB, MUL, IMAD, IDIV, IREM, NEG |
| Integer Comparison | SLT, SLE, SEQ |
| Logic | AND, OR, XOR, NOT, SHL, SHR, SHA |
| Floating Point | FADD, FSUB, FMUL, FDIV, FFMA, FTOI, ITOF |
| Special Functions | SIN, COS, RCP, RSQ, SQRT, EXP2, LOG2, TANH |
| Memory | LDR, STR, LDS, STS |
| Control Flow | BRA, BEQ, BNE, SSY, JOIN, BAR, CALL, RET |
| Texture | TEX, TXL, TXB (new) |

## Host Interface

### Command Buffer Format

```
+------------------+
| Command Header   | 4 bytes: command type, flags
+------------------+
| Vertex Count     | 4 bytes
+------------------+
| Vertex Data Ptr  | 4 bytes: address in GPU memory
+------------------+
| Index Data Ptr   | 4 bytes: address in GPU memory
+------------------+
| Shader Program   | 4 bytes: address of shader code
+------------------+
| Uniforms Ptr     | 4 bytes: address of uniform data
+------------------+
```

### Register Interface

| Address | Register | Description |
|---------|----------|-------------|
| 0x00 | CTRL | Control register |
| 0x04 | STATUS | Status register |
| 0x08 | CMD_PTR | Command buffer pointer |
| 0x0C | FB_BASE | Framebuffer base address |
| 0x10 | FB_WIDTH | Framebuffer width |
| 0x14 | FB_HEIGHT | Framebuffer height |
| 0x18 | TEX0_BASE | Texture 0 base address |
| 0x1C | TEX0_SIZE | Texture 0 dimensions |

## Performance Targets

### KV260 Configuration
- **Vertex throughput**: ~50M vertices/second
- **Fill rate**: ~500M pixels/second
- **Texture rate**: ~250M texels/second
- **Target frame rate**: 60 FPS @ 1080p (simple scenes)

### DE2-115 Configuration
- **Vertex throughput**: ~10M vertices/second
- **Fill rate**: ~100M pixels/second
- **Texture rate**: ~50M texels/second
- **Target frame rate**: 30 FPS @ 480p

## File Organization

```
milo832/
├── rtl/
│   ├── core/
│   │   ├── simt_pkg.vhd          -- Types and constants
│   │   ├── streaming_multiprocessor.vhd
│   │   └── shared_memory.vhd
│   ├── compute/
│   │   ├── alu.vhd               -- Integer ALU
│   │   ├── fpu.vhd               -- Floating point unit
│   │   ├── sfu.vhd               -- Special function unit
│   │   └── int_alu.vhd           -- Simple integer operations
│   ├── memory/
│   │   ├── operand_collector.vhd
│   │   ├── fifo.vhd
│   │   └── memory_controller.vhd
│   └── graphics/
│       ├── rasterizer.vhd
│       ├── texture_sampler.vhd
│       ├── rop.vhd
│       └── command_processor.vhd
├── tb/
│   ├── tb_simt_core.vhd
│   ├── tb_rasterizer.vhd
│   └── tb_texture_sampler.vhd
└── docs/
    ├── architecture.md
    └── isa_reference.md
```

## References

- Original SIMT-GPU-Core: https://github.com/aritramanna/SIMT-GPU-Core
- NVIDIA CUDA Programming Guide
- AMD RDNA Architecture Whitepaper
- Tile-Based Rendering (PowerVR Architecture)
