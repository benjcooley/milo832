# FPGA Hardware Reference

Quick reference for target FPGA platform constraints and capabilities.

## AMD Xilinx Kria KV260 (Primary Target)

**Device:** Zynq UltraScale+ XCK26 (custom K26 variant)

### Logic Resources
| Resource | Count | Notes |
|----------|-------|-------|
| System Logic Cells | ~256K | LUTs + registers |
| CLB Slices | ~30K | 8 LUTs per slice |
| DSP48E2 Slices | 1,248 | 27×18 multiply, 48-bit accumulate |

### Memory Resources
| Type | Count | Size Each | Total | Ports |
|------|-------|-----------|-------|-------|
| Block RAM (BRAM) | 144 | 36 Kb | 5.1 Mb | True dual-port |
| UltraRAM | 64 | 288 Kb | 18 Mb | Single-port (cascade for DP) |

### BRAM Configuration Options
- 36Kb mode: 1K×36, 2K×18, 4K×9, 8K×4, 16K×2, 32K×1
- 18Kb mode (split): Same depths, half width
- 72-bit wide with ECC
- True dual-port: independent R/W per port
- Max bandwidth: 2 reads + 2 writes per cycle (dual port)

### UltraRAM Configuration
- Fixed 4K×72 (288Kb) per block
- Single port per block (can cascade for pseudo-dual-port)
- Built-in pipeline registers
- Good for large sequential buffers
- **Best for:** Framebuffer tiles, large FIFOs

### DSP48E2 Capabilities
- 27×18 signed multiply
- 48-bit accumulator
- Pre-adder (27-bit)
- Pattern detector
- Cascade chains for wide multiply/MAC
- ~741 MHz max
- **Can be used for:** Texture filtering, vertex transform, interpolation

### External Memory
- DDR4: 4GB on KV260 carrier
- Bandwidth: ~19 GB/s theoretical

### Processor System (PS)
- Quad-core ARM Cortex-A53 @ 1.2GHz
- Dual-core ARM Cortex-R5
- Mali-400 MP2 GPU (not useful for us)

---

## Intel/Altera DE2-115 (Secondary Target)

**Device:** Cyclone IV EP4CE115F29C7

### Logic Resources
| Resource | Count | Notes |
|----------|-------|-------|
| Logic Elements (LEs) | 114,480 | 4-input LUT + register |
| Logic Array Blocks | 7,155 | 16 LEs per LAB |
| Embedded Multipliers | 266 | 18×18 signed multiply |

### Memory Resources
| Type | Count | Size Each | Total | Ports |
|------|-------|-----------|-------|-------|
| M9K Blocks | 432 | 9 Kb (8Kb + 1Kb parity) | 3.888 Mb | True dual-port |

### M9K Configuration Options
- 8K×1, 4K×2, 2K×4, 1K×8, 1K×9, 512×16, 512×18, 256×32, 256×36
- True dual-port, simple dual-port, single-port
- Byte enables supported
- ROM mode available
- **Note:** Much smaller than UltraScale+ BRAM!

### Embedded Multipliers
- 266 × 18×18 blocks
- Can split to 532 × 9×9
- No built-in accumulator (need fabric)
- **Can be used for:** Texture filtering, basic multiply

### External Memory
- SDRAM: 128MB (32-bit bus)
- SRAM: 2MB (16-bit bus)
- Flash: 8MB

### Clock Resources
- 4 PLLs
- 20 global clock networks

---

## Design Implications

### Tile Buffer Sizing

**What fits in on-chip RAM:**

| Platform | BRAM for Tiles | Tile Config | Notes |
|----------|----------------|-------------|-------|
| KV260 | 64 BRAM (2.25 Mb) | 32×32 RGBA @ 32bpp = 32Kb | ~70 tiles in BRAM |
| KV260 | 32 UltraRAM (9 Mb) | 64×64 RGBA = 128Kb | ~70 tiles in URAM |
| DE2-115 | 200 M9K (1.8 Mb) | 16×16 RGBA = 8Kb | ~225 tiles |

**Recommendation:** 
- KV260: 32×32 tiles, use UltraRAM for tile color+depth buffer
- DE2-115: 16×16 tiles, use M9K for tile buffer

### Texture Cache Sizing

| Platform | Allocated | Cache Lines (64B) | Notes |
|----------|-----------|-------------------|-------|
| KV260 | 32 BRAM (1.1 Mb) | ~2,200 lines | 4-way, 550 sets |
| DE2-115 | 100 M9K (900 Kb) | ~1,800 lines | 4-way, 450 sets |

### DSP Usage for Filtering

**Bilinear filter (1 texel, 4 channels):**
- 4 multiplies for weights × 4 channels = 16 multiplies
- With DSP sharing: 4 DSPs per filtered texel (time-multiplexed)

**32 parallel bilinear filters:**
| Platform | DSPs Available | DSPs for Filtering | Feasible? |
|----------|----------------|-------------------|-----------|
| KV260 | 1,248 | 128-512 | Yes |
| DE2-115 | 266 | 128-256 | Tight but yes |

### Memory Bandwidth Budget

**KV260 DDR4:**
- 19 GB/s theoretical
- ~10 GB/s practical with arbitration
- At 100 MHz GPU clock: 100 bytes/cycle budget

**DE2-115 SDRAM:**
- ~400 MB/s (32-bit @ 100MHz, ~50% efficiency)
- At 50 MHz GPU clock: 8 bytes/cycle budget
- **This is the main bottleneck!**

### Tile-Based Rendering Justification

Without tile rendering on DE2-115:
- 640×480 @ 32bpp = 1.2 MB framebuffer (won't fit in BRAM)
- Every pixel write goes to SDRAM
- Z-buffer read+write = 2 more accesses
- Texture fetch = more accesses
- **Result:** Completely memory bound

With 16×16 tile rendering:
- Tile buffer: 16×16×8 bytes (RGBA+Z) = 2KB (fits in M9K!)
- Render entire tile on-chip
- Single burst write to SDRAM when done
- **Result:** 10-50× less memory traffic

---

## Summary Recommendations

### KV260 Configuration
```
Tile size:        32×32 pixels
Tile buffer:      32×32×8 = 8KB per tile (RGBA + Depth)
                  Use 4 UltraRAM for double-buffered tile (2 tiles)
Texture cache:    16KB (32 BRAM)
Shared memory:    16KB per SM (32 BRAM)
Register file:    Distributed RAM or BRAM
Warps:            8 per SM (256 threads)
SMs:              2 (512 total threads)
DSPs for filter:  256 (8 per thread for tex filter)
```

### DE2-115 Configuration
```
Tile size:        16×16 pixels
Tile buffer:      16×16×8 = 2KB per tile
                  Use 2 M9K for double-buffered tile
Texture cache:    8KB (8 M9K)
Shared memory:    8KB per SM (8 M9K)
Register file:    M9K blocks
Warps:            4 per SM (128 threads)
SMs:              1 (128 total threads)
DSPs for filter:  128 (4 per thread, time-multiplexed)
```
