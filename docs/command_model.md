# Milo832 Command Model and Frame Flow

## Overview

The driver organizes GPU work through **command buffers** - pre-built sequences of operations that the GPU executes asynchronously. This decouples CPU and GPU, enabling parallel operation.

## Frame Timeline

```
        CPU (m65832)                              GPU (Milo832)
        ────────────                              ─────────────
Frame 0 ┌─────────────────┐
        │ Build cmd buf 0 │
        │ Upload vertices │
        │ Set uniforms    │
        └────────┬────────┘
                 │ KICK (write to doorbell register)
                 ▼
Frame 1 ┌─────────────────┐                 ┌─────────────────┐
        │ Build cmd buf 1 │                 │ Execute cmd 0   │
        │ Game logic      │                 │ Vertex shaders  │
        │ AI, physics     │                 │ Binning         │
        └────────┬────────┘                 │ Tile rendering  │
                 │ KICK                     └────────┬────────┘
                 ▼                                   │
Frame 2 ┌─────────────────┐                 ┌───────▼─────────┐
        │ Build cmd buf 2 │                 │ Execute cmd 1   │
        │                 │                 │                 │
        └────────┬────────┘                 └────────┬────────┘
                 │                                   │
                 ▼                                   ▼
              (continues)                        (continues)

        ◄─────── 1 frame latency ───────►
```

## Memory Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GPU MEMORY MAP                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  0x0000_0000 ┌────────────────────────────────┐                     │
│              │  CONTROL REGISTERS             │ 4 KB                │
│              │  • Command buffer pointer      │                     │
│              │  • Status, IRQ mask            │                     │
│              │  • Performance counters        │                     │
│  0x0000_1000 ├────────────────────────────────┤                     │
│              │  COMMAND RING BUFFER           │ 64 KB               │
│              │  • Circular buffer of commands │                     │
│              │  • Read/write pointers         │                     │
│  0x0001_0000 ├────────────────────────────────┤                     │
│              │  VERTEX BUFFER POOL            │ 1 MB                │
│              │  • Ring buffer for vertices    │                     │
│              │  • Multiple draw calls share   │                     │
│  0x0010_0000 ├────────────────────────────────┤                     │
│              │  INDEX BUFFER POOL             │ 256 KB              │
│              │                                │                     │
│  0x0014_0000 ├────────────────────────────────┤                     │
│              │  UNIFORM BUFFER                │ 64 KB               │
│              │  • MVP matrices                │                     │
│              │  • Material parameters         │                     │
│              │  • Light data                  │                     │
│  0x0015_0000 ├────────────────────────────────┤                     │
│              │  SHADER PROGRAM STORAGE        │ 256 KB              │
│              │  • Vertex shader code          │                     │
│              │  • Fragment shader code        │                     │
│  0x0019_0000 ├────────────────────────────────┤                     │
│              │  TEXTURE MEMORY                │ 4 MB                │
│              │  • Mipmapped textures          │                     │
│              │  • Palette tables              │                     │
│  0x0059_0000 ├────────────────────────────────┤                     │
│              │  TILE BIN LISTS                │ 256 KB              │
│              │  • Per-tile triangle lists     │                     │
│  0x0099_0000 ├────────────────────────────────┤                     │
│              │  TRIANGLE STORAGE              │ 2 MB                │
│              │  • Post-transform vertices     │                     │
│  0x0299_0000 ├────────────────────────────────┤                     │
│              │  FRAMEBUFFER                   │ 2× 1.2 MB           │
│              │  • Double-buffered             │                     │
│              │  • 640×480×32bpp = 1.2 MB each │                     │
│  0x049A_0000 └────────────────────────────────┘                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Command Types

```
┌─────────────────────────────────────────────────────────────────────┐
│                        COMMAND FORMAT                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Every command is 32 bits minimum, variable length:                  │
│                                                                      │
│  ┌────────┬────────┬────────────────────────────────────────────┐   │
│  │ OPCODE │ LENGTH │            PAYLOAD (optional)              │   │
│  │ 8 bits │ 8 bits │            0-N dwords                      │   │
│  └────────┴────────┴────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

OPCODES:
────────
0x01  NOP                   No operation (padding/alignment)
0x02  FENCE                 Memory barrier, wait for prior ops
0x03  IRQ                   Signal interrupt to CPU

0x10  SET_VERTEX_BUFFER     Set vertex buffer address + stride
0x11  SET_INDEX_BUFFER      Set index buffer address + format
0x12  SET_UNIFORM_BUFFER    Set uniform buffer address
0x13  SET_TEXTURE           Set texture descriptor (addr, size, format)
0x14  SET_RENDER_TARGET     Set framebuffer address
0x15  SET_VIEWPORT          Set viewport transform parameters
0x16  SET_SCISSOR           Set scissor rectangle

0x20  BIND_VERTEX_SHADER    Set vertex shader program address
0x21  BIND_FRAGMENT_SHADER  Set fragment shader program address

0x30  CLEAR                 Clear color/depth buffers
0x31  DRAW                  Draw primitives (vertex count, instance count)
0x32  DRAW_INDEXED          Draw indexed primitives

0x40  BEGIN_TILE_PASS       Start tile-based rendering
0x41  END_TILE_PASS         Finish tiles, write to framebuffer

0xF0  JUMP                  Jump to another command buffer
0xF1  CALL                  Call subroutine (for common state setup)
0xFF  END                   End of command buffer
```

## Detailed Frame Flow

### Phase 1: CPU Builds Command Buffer

```c
// Driver code running on m65832 CPU

void render_frame(Scene* scene) {
    CommandBuffer* cmd = alloc_command_buffer();
    
    // 1. Set render target (back buffer)
    cmd_set_render_target(cmd, backbuffer_addr);
    cmd_set_viewport(cmd, 0, 0, 640, 480);
    
    // 2. Clear
    cmd_clear(cmd, CLEAR_COLOR | CLEAR_DEPTH, 
              0x000000FF,  // black
              0xFFFFFF);   // max depth
    
    // 3. Begin geometry phase
    cmd_begin_tile_pass(cmd);
    
    // 4. For each material/mesh batch
    for (Batch* batch : scene->batches) {
        // Set shaders
        cmd_bind_vertex_shader(cmd, batch->vertex_shader);
        cmd_bind_fragment_shader(cmd, batch->fragment_shader);
        
        // Set textures
        cmd_set_texture(cmd, 0, batch->diffuse_texture);
        
        // Set uniforms (MVP matrix, etc)
        Matrix4 mvp = projection * view * batch->model_matrix;
        uint32_t uniform_offset = upload_uniforms(&mvp, sizeof(mvp));
        cmd_set_uniform_buffer(cmd, uniform_offset);
        
        // Set vertex/index buffers
        cmd_set_vertex_buffer(cmd, batch->vbo_offset, batch->vertex_stride);
        cmd_set_index_buffer(cmd, batch->ibo_offset, INDEX_U16);
        
        // Draw!
        cmd_draw_indexed(cmd, batch->index_count, 0);
    }
    
    // 5. End geometry phase - triggers tile rendering
    cmd_end_tile_pass(cmd);
    
    // 6. Signal completion
    cmd_irq(cmd, FRAME_DONE_IRQ);
    cmd_end(cmd);
    
    // 7. Submit to GPU
    kick_gpu(cmd);
}
```

### Phase 2: GPU Geometry Processing

```
┌─────────────────────────────────────────────────────────────────────┐
│                     GPU: GEOMETRY PHASE                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Command Processor reads: DRAW_INDEXED(count=300, base=0)           │
│                                                                      │
│  1. Launch vertex shader warps                                       │
│     ┌─────────────────────────────────────────────────┐             │
│     │ Warp 0: vertices 0-31    (threads 0-31)         │             │
│     │ Warp 1: vertices 32-63   (threads 0-31)         │             │
│     │ ...                                              │             │
│     │ Warp 9: vertices 288-299 (threads 0-11 active)  │             │
│     └─────────────────────────────────────────────────┘             │
│                          │                                           │
│                          ▼                                           │
│  2. Primitive Assembly (as vertex warps complete)                    │
│     ┌─────────────────────────────────────────────────┐             │
│     │ Read index buffer: [0,1,2], [3,4,5], ...        │             │
│     │ Fetch transformed vertices from VS output       │             │
│     │ Perspective divide: x/=w, y/=w, z/=w            │             │
│     │ Viewport transform: x = x*W/2 + W/2             │             │
│     │ Backface cull: skip if cross(e01,e02).z < 0     │             │
│     └─────────────────────────────────────────────────┘             │
│                          │                                           │
│                          ▼                                           │
│  3. Triangle Binning                                                 │
│     ┌─────────────────────────────────────────────────┐             │
│     │ For each surviving triangle:                     │             │
│     │   Compute bounding box                          │             │
│     │   For each tile in bbox:                        │             │
│     │     Append triangle ID to tile's list           │             │
│     └─────────────────────────────────────────────────┘             │
│                                                                      │
│  When END_TILE_PASS reached: All geometry processed, begin tiles    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Phase 3: GPU Tile Rendering

```
┌─────────────────────────────────────────────────────────────────────┐
│                     GPU: TILE PHASE                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  For tile (tx, ty) in all tiles:                                    │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 1. CLEAR TILE BUFFER (on-chip, fast)                          │  │
│  │    Color[16×16] = clear_color                                 │  │
│  │    Depth[16×16] = clear_depth                                 │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                          │                                           │
│                          ▼                                           │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 2. LOAD TILE'S TRIANGLE LIST from memory                      │  │
│  │    triangles[] = bin_lists[ty][tx]                            │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                          │                                           │
│                          ▼                                           │
│  For each triangle in tile's list:                                  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 3. RASTERIZE (fixed-function)                                 │  │
│  │    Generate fragments for pixels inside triangle              │  │
│  │    Batch into groups of 32                                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                          │                                           │
│                          ▼                                           │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 4. FRAGMENT SHADER (SIMT - 32 threads per warp)               │  │
│  │    Sample textures                                            │  │
│  │    Compute lighting                                           │  │
│  │    Output: RGBA color                                         │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                          │                                           │
│                          ▼                                           │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 5. ROP (on-chip tile buffer)                                  │  │
│  │    Depth test (vs tile Z-buffer)                              │  │
│  │    Alpha blend                                                │  │
│  │    Write to tile color buffer                                 │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                          │                                           │
│                          ▼                                           │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ 6. TILE WRITEBACK (DMA to framebuffer)                        │  │
│  │    Burst write tile to FB[ty*16..ty*16+15][tx*16..tx*16+15]   │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Avoiding Stalls: Pipeline Parallelism

The key to avoiding stalls is **overlapping work**:

```
                    Time ─────────────────────────────────────────────►

Draw Call 1:  [VS Warps 0-9]──►[Prim Assembly]──►[Binning]
                                                      │
Draw Call 2:        [VS Warps 0-5]──►[Prim Asm]──►[Binning]
                                                      │
                                                      ▼
                                              ┌─────────────┐
                                              │ END_TILE    │
                                              │ PASS        │
                                              └──────┬──────┘
                                                     │
Tile (0,0):                                   [Rast]──►[FS]──►[ROP]──►[WB]
Tile (1,0):                                       [Rast]──►[FS]──►[ROP]──►[WB]
Tile (2,0):                                           [Rast]──►[FS]──►[ROP]──►

Double-buffer tiles:
                    Tile N:   [Rast──FS──ROP]
                    Tile N+1:      [WB to FB]
                              ─────────────────
                              runs in parallel!
```

## State Caching

To minimize redundant state changes:

```
┌─────────────────────────────────────────────────────────────────────┐
│                     GPU STATE REGISTERS                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Current Vertex Shader    ──┐                                       │
│  Current Fragment Shader  ──┼── Only reload if changed              │
│  Current Textures[0-7]    ──┤                                       │
│  Current Uniforms         ──┘                                       │
│                                                                      │
│  Driver sorts draw calls by state to minimize changes:              │
│                                                                      │
│    Before: Draw(shaderA), Draw(shaderB), Draw(shaderA), Draw(shaderB)│
│    After:  Draw(shaderA), Draw(shaderA), Draw(shaderB), Draw(shaderB)│
│                                                                      │
│    Shader changes: 4 → 2                                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Synchronization Points

```
┌─────────────────────────────────────────────────────────────────────┐
│                     SYNC PRIMITIVES                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  FENCE command:                                                      │
│    Ensures all prior operations complete before continuing          │
│    Used between render passes, before reading render target         │
│                                                                      │
│  IRQ command:                                                        │
│    Signals CPU when GPU reaches this point                          │
│    Used for frame completion, vsync                                 │
│                                                                      │
│  Example - Render to texture then use as source:                    │
│                                                                      │
│    cmd_set_render_target(shadow_map);                               │
│    cmd_draw(...);  // render shadow casters                         │
│    cmd_fence();    // MUST wait for shadow map to complete          │
│    cmd_set_render_target(main_fb);                                  │
│    cmd_set_texture(0, shadow_map);  // now safe to sample           │
│    cmd_draw(...);  // render scene with shadows                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Register Interface

```
┌─────────────────────────────────────────────────────────────────────┐
│                     CONTROL REGISTERS                                │
├───────────┬─────────────────────────────────────────────────────────┤
│  Offset   │  Register                                               │
├───────────┼─────────────────────────────────────────────────────────┤
│  0x000    │  STATUS        (RO)  Bit 0: Busy, Bit 1: Fault         │
│  0x004    │  IRQ_STATUS    (RW)  Interrupt flags (write 1 to clear) │
│  0x008    │  IRQ_ENABLE    (RW)  Interrupt enable mask              │
│  0x00C    │  FAULT_ADDR    (RO)  Address of faulting access        │
│           │                                                         │
│  0x010    │  CMD_BASE      (RW)  Command buffer base address       │
│  0x014    │  CMD_SIZE      (RW)  Command buffer size               │
│  0x018    │  CMD_READ_PTR  (RO)  GPU's current read position       │
│  0x01C    │  CMD_WRITE_PTR (RW)  CPU writes here to kick GPU       │
│           │                                                         │
│  0x020    │  PERF_CYCLES   (RO)  Total GPU cycles                  │
│  0x024    │  PERF_VS_WARPS (RO)  Vertex shader warps executed      │
│  0x028    │  PERF_FS_WARPS (RO)  Fragment shader warps executed    │
│  0x02C    │  PERF_TRIS     (RO)  Triangles processed               │
│  0x030    │  PERF_TILES    (RO)  Tiles rendered                    │
│  0x034    │  PERF_STALLS   (RO)  Memory stall cycles               │
└───────────┴─────────────────────────────────────────────────────────┘

Kick sequence:
  1. CPU writes commands to ring buffer
  2. CPU updates CMD_WRITE_PTR
  3. GPU sees write_ptr > read_ptr, begins processing
  4. GPU increments read_ptr as commands complete
  5. When IRQ command reached, GPU sets IRQ_STATUS, signals CPU
```

## Practical Example: Rendering a Cube

```c
// 1. Upload vertex data (once)
float cube_verts[] = { /* 24 vertices with pos, uv, normal */ };
uint16_t cube_indices[] = { /* 36 indices for 12 triangles */ };
gpu_upload(VBO_OFFSET, cube_verts, sizeof(cube_verts));
gpu_upload(IBO_OFFSET, cube_indices, sizeof(cube_indices));

// 2. Upload shaders (once)  
gpu_upload(VS_OFFSET, vertex_shader_code, vs_size);
gpu_upload(FS_OFFSET, fragment_shader_code, fs_size);

// 3. Upload texture (once)
gpu_upload(TEX_OFFSET, texture_data, tex_size);

// 4. Each frame:
void draw_cube(Matrix4 model_matrix) {
    // Update uniforms
    Matrix4 mvp = projection * view * model_matrix;
    gpu_upload(UNIFORM_OFFSET, &mvp, sizeof(mvp));
    
    // Build command buffer
    CommandBuffer cmd;
    cmd_begin(&cmd);
    
    cmd_set_render_target(&cmd, framebuffer_addr);
    cmd_clear(&cmd, CLEAR_COLOR | CLEAR_DEPTH, 0x404040FF, 0xFFFFFF);
    
    cmd_begin_tile_pass(&cmd);
    
    cmd_bind_vertex_shader(&cmd, VS_OFFSET);
    cmd_bind_fragment_shader(&cmd, FS_OFFSET);
    cmd_set_texture(&cmd, 0, TEX_OFFSET, 64, 64, FORMAT_RGBA8);
    cmd_set_uniform_buffer(&cmd, UNIFORM_OFFSET);
    cmd_set_vertex_buffer(&cmd, VBO_OFFSET, 32);  // stride=32 bytes
    cmd_set_index_buffer(&cmd, IBO_OFFSET, INDEX_U16);
    
    cmd_draw_indexed(&cmd, 36, 0);  // 36 indices = 12 triangles
    
    cmd_end_tile_pass(&cmd);
    cmd_irq(&cmd, FRAME_DONE);
    cmd_end(&cmd);
    
    kick_gpu(&cmd);
}
```

Total command buffer size: ~100 bytes for a simple draw call!
