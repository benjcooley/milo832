# Texture Subsystem Architecture

## Overview

The texture subsystem integrates with the SIMT streaming multiprocessor as a functional unit alongside the ALU, FPU, SFU, and LSU. It handles texture sampling for all 32 threads in a warp simultaneously.

## Integration with SIMT Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                  Streaming Multiprocessor                    │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐ │
│  │   ALU   │  │   FPU   │  │   SFU   │  │      LSU        │ │
│  │ 32-wide │  │ 32-wide │  │ 32-wide │  │    32-wide      │ │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────────┬────────┘ │
│       │            │            │                 │          │
│       └────────────┴─────┬──────┴─────────────────┘          │
│                          │                                   │
│  ┌───────────────────────▼───────────────────────────────┐  │
│  │              Texture Unit (TEX)                        │  │
│  │  ┌──────────────────────────────────────────────────┐ │  │
│  │  │         32 Texture Address Generators            │ │  │
│  │  │   (UV → texel coords, format decode, LOD)        │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  │                         │                              │  │
│  │  ┌──────────────────────▼───────────────────────────┐ │  │
│  │  │            Request Coalescer                     │ │  │
│  │  │   Groups requests by cache line / ETC block      │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  │                         │                              │  │
│  │  ┌──────────────────────▼───────────────────────────┐ │  │
│  │  │         Texture Cache (16KB, 4-way)              │ │  │
│  │  │   Tags + Data, LRU replacement                   │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  │                         │ (misses)                     │  │
│  │  ┌──────────────────────▼───────────────────────────┐ │  │
│  │  │              Miss Queue (MSHR)                   │ │  │
│  │  │   Tracks outstanding memory requests             │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  │                         │                              │  │
│  │  ┌──────────────────────▼───────────────────────────┐ │  │
│  │  │         Format Decoders (per thread)             │ │  │
│  │  │   ETC, Paletized, RGBA decode                    │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  │                         │                              │  │
│  │  ┌──────────────────────▼───────────────────────────┐ │  │
│  │  │         32 Bilinear Filter Units                 │ │  │
│  │  │   4 texels → 1 filtered result per thread        │ │  │
│  │  └──────────────────────┬───────────────────────────┘ │  │
│  └─────────────────────────┼────────────────────────────┘  │
│                            │                                │
│                   ┌────────▼────────┐                       │
│                   │   Writeback     │                       │
│                   │   (32 results)  │                       │
│                   └─────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │  Memory System  │
                    │  (DDR/SDRAM)    │
                    └─────────────────┘
```

## Execution Flow

### 1. TEX Instruction Issue

When the warp scheduler issues a TEX instruction:
- Operand collector provides UV coordinates for all 32 threads
- Texture unit receives: warp ID, thread mask, UV pairs, texture ID, LOD

### 2. Address Generation (1 cycle)

Each of 32 address generators computes:
- Texel coordinates from normalized UVs (multiply by texture size)
- Apply wrap mode (repeat, clamp, mirror)
- For bilinear: compute 4 texel addresses (u0,v0), (u1,v0), (u0,v1), (u1,v1)
- Calculate fractional weights for interpolation

### 3. Request Coalescing (1-2 cycles)

The coalescer groups the 128 texel requests (32 threads × 4 texels):
- Sort by cache line address
- Merge duplicates (very common - adjacent pixels sample same texels)
- Typical reduction: 128 requests → 4-16 unique cache line requests

### 4. Cache Lookup (1-2 cycles)

For each unique request:
- Check texture cache tags
- Hit: data immediately available
- Miss: queue to MSHR, issue memory request

### 5. Memory Fetch (Variable, 50-200 cycles)

For cache misses:
- MSHR tracks which threads are waiting for which data
- Memory controller fetches 64-byte cache lines
- On return: fill cache, wake waiting requests

### 6. Format Decode (1-2 cycles)

Once texels are available, decode based on format:
- **ETC1/ETC2**: Decompress 4x4 block → extract needed texels
- **Paletized**: Index into palette RAM (separate 256×32-bit SRAM)
- **Direct (RGBA4444, etc)**: Unpack to RGBA8888

### 7. Bilinear Filtering (1 cycle)

Each filter unit computes:
```
result = texel00 * (1-fu) * (1-fv) +
         texel10 * fu * (1-fv) +
         texel01 * (1-fu) * fv +
         texel11 * fu * fv
```

### 8. Writeback

Results written to register file via normal writeback path.
Scoreboard cleared, warp can proceed.

## Latency Hiding

Like LSU operations, texture fetches are long-latency. The SIMT model handles this:

1. Warp 0 issues TEX → scoreboard marks destination register busy
2. Warp 0 stalls (can't use result yet)
3. Scheduler switches to Warp 1, 2, 3... (zero-overhead context switch)
4. Texture data returns → scoreboard clears
5. Warp 0 becomes ready again

With 8+ warps resident, texture latency is mostly hidden.

## Supported Texture Formats

| Format | BPP | Palette | Block Size | Notes |
|--------|-----|---------|------------|-------|
| MONO1 | 1 | No | 8 pixels/byte | Monochrome bitmap |
| PAL4 | 4 | 16 colors | 2 pixels/byte | 16-color indexed |
| PAL8 | 8 | 256 colors | 1 pixel/byte | 256-color indexed |
| RGBA4444 | 16 | No | 1 pixel/2 bytes | Direct color |
| ETC1 | 4 | No | 4x4 block/64 bits | RGB only |
| ETC2_RGB | 4 | No | 4x4 block/64 bits | Improved RGB |
| ETC2_RGBA | 8 | No | 4x4 block/128 bits | RGB + Alpha |

## Mipmap Support

- Up to 11 mip levels (2048×2048 max)
- LOD specified per-instruction (TXL) or per-thread
- No trilinear filtering (mip banding acceptable)
- Mip addresses pre-computed and stored in texture descriptor

## Texture Descriptor (32 bytes)

```
Offset  Size  Field
0x00    4     Base address (mip 0)
0x04    2     Width
0x06    2     Height
0x08    1     Format
0x09    1     Wrap mode U (2 bits) + V (2 bits) + reserved
0x0A    1     Num mip levels
0x0B    1     Reserved
0x0C    4     Palette address (for indexed formats)
0x10    4     Mip 1 address
0x14    4     Mip 2 address
0x18    4     Mip 3 address
0x1C    4     Mip 4+ offset table pointer
```

## Resource Estimates

### KV260 Configuration
- Texture cache: 16KB (uses Block RAM)
- Palette RAM: 1KB (256 × 32-bit)
- Address generators: 32 (modest logic)
- Filter units: 32 (multipliers from DSP slices)
- Estimated: ~15K LUTs, 32 DSP slices, 20 Block RAMs

### DE2-115 Configuration
- Texture cache: 8KB
- Palette RAM: 1KB
- Estimated: ~10K LEs, 32 multipliers, 80Kb embedded memory
