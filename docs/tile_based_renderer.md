# Tile-Based Rendering Architecture

## Overview

The Milo832 GPU uses tile-based deferred rendering (TBDR) to minimize external memory bandwidth. This approach is essential for the DE2-115's limited SDRAM bandwidth and beneficial for the KV260's power efficiency.

## Rendering Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                      GEOMETRY PHASE                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │   Vertex     │───▶│   Vertex     │───▶│   Primitive          │  │
│  │   Fetch      │    │   Shader     │    │   Assembly           │  │
│  │              │    │   (SIMT)     │    │   (Triangles)        │  │
│  └──────────────┘    └──────────────┘    └──────────┬───────────┘  │
│                                                      │               │
│                                          ┌───────────▼───────────┐  │
│                                          │   Clip & Cull         │  │
│                                          │   (View Frustum)      │  │
│                                          └───────────┬───────────┘  │
│                                                      │               │
│                                          ┌───────────▼───────────┐  │
│                                          │   Viewport            │  │
│                                          │   Transform           │  │
│                                          └───────────┬───────────┘  │
│                                                      │               │
└──────────────────────────────────────────────────────┼──────────────┘
                                                       │
┌──────────────────────────────────────────────────────▼──────────────┐
│                      BINNING PHASE                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Triangle Binner                            │   │
│  │                                                               │   │
│  │   For each triangle:                                          │   │
│  │   1. Compute bounding box                                     │   │
│  │   2. Find overlapping tiles                                   │   │
│  │   3. Add triangle ID to each tile's list                     │   │
│  │                                                               │   │
│  │   ┌─────┬─────┬─────┬─────┬─────┐                            │   │
│  │   │ T0  │ T1  │ T2  │ T3  │ ... │  Tile Lists (in DDR/SDRAM) │   │
│  │   │[2,5]│[1,2]│[2,3]│[3,4]│     │  (Triangle IDs per tile)   │   │
│  │   └─────┴─────┴─────┴─────┴─────┘                            │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────┬──────────────┘
                                                       │
┌──────────────────────────────────────────────────────▼──────────────┐
│                      RASTERIZATION PHASE (Per-Tile)                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  For each tile:                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  1. Clear tile buffer (on-chip BRAM/URAM)                    │   │
│  │     ┌────────────────────────────────────────┐               │   │
│  │     │  Color Buffer    │   Depth Buffer      │               │   │
│  │     │  32×32×32bpp     │   32×32×24bpp       │  (KV260)      │   │
│  │     │  = 4KB           │   = 3KB             │               │   │
│  │     │  16×16×32bpp     │   16×16×24bpp       │  (DE2-115)    │   │
│  │     │  = 1KB           │   = 768B            │               │   │
│  │     └────────────────────────────────────────┘               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  2. For each triangle in tile's list:                        │   │
│  │     ┌────────────────────────────────────────┐               │   │
│  │     │        Tile Rasterizer                 │               │   │
│  │     │                                        │               │   │
│  │     │  • Compute edge functions              │               │   │
│  │     │  • Test each pixel in tile             │               │   │
│  │     │  • Generate fragments (batches of 32)  │               │   │
│  │     └───────────────────┬────────────────────┘               │   │
│  │                         │                                     │   │
│  │     ┌───────────────────▼────────────────────┐               │   │
│  │     │      Fragment Queue (32-deep)          │               │   │
│  │     │  Batches fragments into warps          │               │   │
│  │     └───────────────────┬────────────────────┘               │   │
│  │                         │                                     │   │
│  │     ┌───────────────────▼────────────────────┐               │   │
│  │     │      Fragment Shader (SIMT)            │               │   │
│  │     │  • Texture sampling                    │               │   │
│  │     │  • Lighting calculations               │               │   │
│  │     │  • Output: final color                 │               │   │
│  │     └───────────────────┬────────────────────┘               │   │
│  │                         │                                     │   │
│  │     ┌───────────────────▼────────────────────┐               │   │
│  │     │      Tile ROP (on-chip)                │               │   │
│  │     │  • Depth test vs tile Z-buffer         │               │   │
│  │     │  • Alpha blending                      │               │   │
│  │     │  • Write to tile color buffer          │               │   │
│  │     └────────────────────────────────────────┘               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  3. Write completed tile to framebuffer (burst transfer)     │   │
│  │     Tile → DDR/SDRAM (one DMA burst per tile)                │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Memory Layout

### Screen Tiling

```
KV260: 1920×1080 with 32×32 tiles = 60×34 = 2,040 tiles
DE2-115: 640×480 with 16×16 tiles = 40×30 = 1,200 tiles

Screen (640×480):
┌──────┬──────┬──────┬──────┬─────   ─┬──────┐
│ T0,0 │ T1,0 │ T2,0 │ T3,0 │   ...   │T39,0 │
├──────┼──────┼──────┼──────┼─────   ─┼──────┤
│ T0,1 │ T1,1 │ T2,1 │ T3,1 │   ...   │T39,1 │
├──────┼──────┼──────┼──────┼─────   ─┼──────┤
│  :   │  :   │  :   │  :   │         │  :   │
├──────┼──────┼──────┼──────┼─────   ─┼──────┤
│T0,29 │T1,29 │T2,29 │T3,29 │   ...   │T39,29│
└──────┴──────┴──────┴──────┴─────   ─┴──────┘
```

### Triangle Bin Lists

Stored in external memory. Each tile has a list of triangle indices that touch it.

```
Tile List Header (per tile): 8 bytes
┌─────────────────┬─────────────────┐
│ Triangle Count  │ List Pointer    │
│ (16 bits)       │ (32 bits)       │
└─────────────────┴─────────────────┘

Triangle Entry: 4 bytes each
┌─────────────────────────────────────┐
│ Triangle Index (32 bits)            │
└─────────────────────────────────────┘

Memory budget for bin lists:
- 1,200 tiles × 8 bytes header = 9.6 KB
- Average 10 triangles/tile × 4 bytes = 48 KB
- Total: ~60 KB for moderate scene
```

### Tile Buffer (On-Chip)

```
KV260 (32×32 tile):
┌─────────────────────────────────────┐
│ Color: 32×32×4 bytes = 4,096 bytes  │ (1 UltraRAM or 2 BRAM)
│ Depth: 32×32×3 bytes = 3,072 bytes  │ (1 BRAM)
│ Total: 7,168 bytes per tile         │
│ Double-buffered: 14,336 bytes       │
└─────────────────────────────────────┘

DE2-115 (16×16 tile):
┌─────────────────────────────────────┐
│ Color: 16×16×4 bytes = 1,024 bytes  │ (1 M9K)
│ Depth: 16×16×3 bytes = 768 bytes    │ (1 M9K)
│ Total: 1,792 bytes per tile         │
│ Double-buffered: 3,584 bytes        │
└─────────────────────────────────────┘
```

## Component Details

### 1. Triangle Binner

**Function:** Assigns each triangle to all tiles it overlaps.

**Algorithm:**
```
for each triangle T:
    bbox = compute_bounding_box(T.v0, T.v1, T.v2)
    tile_min_x = bbox.min_x / TILE_SIZE
    tile_max_x = bbox.max_x / TILE_SIZE
    tile_min_y = bbox.min_y / TILE_SIZE
    tile_max_y = bbox.max_y / TILE_SIZE
    
    for ty in tile_min_y..tile_max_y:
        for tx in tile_min_x..tile_max_x:
            tile_lists[ty][tx].append(T.index)
```

**Implementation:**
- Processes one triangle per cycle
- Bounding box computation: combinational
- Tile list append: requires memory write per tile touched
- For triangle touching N tiles: N cycles

### 2. Tile Rasterizer

**Function:** Generates fragments for all pixels covered by triangles in a tile.

**Key Features:**
- Processes one triangle at a time within a tile
- Uses edge function for inside test
- Outputs fragments in batches of 32 (one warp)
- Early-out for triangles that miss the tile entirely

**Fragment Output Format:**
```
Fragment (per thread): 24 bytes
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ X (16b)  │ Y (16b)  │ Z (32b)  │ U (32b)  │ V (32b)  │Color(32b)│
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘

Warp of 32 fragments: 768 bytes
```

### 3. Fragment Batcher

**Function:** Collects fragments and dispatches full warps to SIMT shader.

**Operation:**
- Accumulates fragments from rasterizer
- When 32 fragments collected (or triangle done), dispatch warp
- Handles partial warps at triangle boundaries
- Tracks which pixels in tile have been touched

### 4. Tile ROP

**Function:** Depth test and blending using tile's on-chip buffers.

**Operations:**
- Read depth from tile Z-buffer (1 cycle, on-chip)
- Compare fragment Z vs buffer Z
- If pass: blend color, write color buffer, write Z buffer
- All on-chip: no external memory traffic!

### 5. Tile Writeback

**Function:** DMA completed tile to framebuffer.

**Optimization:**
- Only write pixels that were actually rendered (dirty mask)
- Burst transfer: 64-128 bytes per beat
- Double-buffer: render tile N+1 while writing tile N

## Performance Analysis

### DE2-115 (Worst Case Platform)

**SDRAM Bandwidth:** 400 MB/s = 50 MB/s per direction realistic

**Without tiling (immediate mode):**
```
Per pixel: Z read (3B) + Z write (3B) + Color write (4B) = 10 bytes minimum
640×480 = 307,200 pixels
At 60 FPS: 307,200 × 10 × 60 = 184 MB/s just for framebuffer
Leaves: ~-130 MB/s for textures (impossible!)
```

**With 16×16 tiling:**
```
Per tile: 1,024 bytes color writeback (once per tile)
1,200 tiles × 1,024 = 1.2 MB per frame
At 60 FPS: 72 MB/s for framebuffer writeback
Triangle data: ~10 KB per frame = negligible
Texture data: ~30 MB/s budget remaining
Result: Feasible!
```

### Fragment Generation Rate

**Target:** Keep SIMT cores busy

```
SIMT runs at 100 MHz, 32 threads per warp
If shader takes 50 cycles: 32 pixels / 50 cycles = 0.64 pixels/cycle
640×480 @ 60 FPS = 18.4M pixels/second
At 100 MHz: need 0.18 pixels/cycle average (after culling)

Rasterizer target: 1 pixel/cycle peak (32 pixels/32 cycles)
With 2:1 overdraw: 0.5 visible pixels/cycle
Conclusion: Single rasterizer is sufficient
```

## State Machine

```
┌─────────────────────────────────────────────────────────────────┐
│                     Tile Renderer FSM                            │
└─────────────────────────────────────────────────────────────────┘

     ┌──────────┐
     │  IDLE    │◄─────────────────────────────────────────┐
     └────┬─────┘                                          │
          │ frame_start                                    │
          ▼                                                │
     ┌──────────┐                                          │
     │  CLEAR   │ Clear tile buffer                        │
     │  TILE    │ (fast: write 0 to all)                   │
     └────┬─────┘                                          │
          │                                                │
          ▼                                                │
     ┌──────────┐                                          │
     │  LOAD    │ Fetch tile's triangle list               │
     │  LIST    │ from external memory                     │
     └────┬─────┘                                          │
          │                                                │
          ▼                                                │
     ┌──────────┐     last_triangle    ┌──────────┐        │
     │  SETUP   │─────────────────────▶│  WRITE   │        │
     │TRIANGLE  │                      │  TILE    │────────┘
     └────┬─────┘                      └──────────┘
          │                                  ▲
          ▼                                  │
     ┌──────────┐                           │
     │ RASTERIZE│ Generate fragments        │
     │ TRIANGLE │ in 32-fragment batches    │
     └────┬─────┘                           │
          │                                  │
          ▼                                  │
     ┌──────────┐                           │
     │  SHADE   │ Dispatch to SIMT          │
     │  WARP    │ (texture, lighting)       │
     └────┬─────┘                           │
          │                                  │
          ▼                                  │
     ┌──────────┐                           │
     │  ROP     │ Z-test, blend             │
     │  (tile)  │ Write tile buffer         │
     └────┬─────┘                           │
          │                                  │
          │ next_triangle                    │
          └────────────────────────────────▶│
```

## Resource Allocation

### KV260
| Component | BRAM | UltraRAM | DSP | LUTs |
|-----------|------|----------|-----|------|
| Tile Color Buffer (×2) | - | 2 | - | 100 |
| Tile Depth Buffer (×2) | 2 | - | - | 100 |
| Triangle Binner | 4 | - | 2 | 2,000 |
| Tile Rasterizer | 2 | - | 8 | 4,000 |
| Fragment Batcher | 2 | - | - | 1,000 |
| Tile ROP | - | - | 4 | 1,500 |
| **Subtotal** | 10 | 2 | 14 | 8,700 |

### DE2-115
| Component | M9K | Multipliers | LEs |
|-----------|-----|-------------|-----|
| Tile Color Buffer (×2) | 2 | - | 100 |
| Tile Depth Buffer (×2) | 2 | - | 100 |
| Triangle Binner | 4 | 2 | 2,000 |
| Tile Rasterizer | 2 | 4 | 3,000 |
| Fragment Batcher | 2 | - | 800 |
| Tile ROP | - | 2 | 1,200 |
| **Subtotal** | 12 | 8 | 7,200 |
