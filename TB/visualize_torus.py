import sys
import math
from PIL import Image, ImageDraw
import glob
import os

def render_frame(ppm_path, frame_idx, total_frames):
    # 3D vertices (match test_parallel_torus.sv "High-Density Donut")
    # 32 Threads (Phi) x 16 Steps (Theta) = 512 Vertices
    # R = 16, r = 8
    
    vertices3d = []
    edges = []
    
    PI = 3.1415926535
    R_major = 16.0
    r_minor = 8.0
    
    NUM_PHI = 32   # Threads
    NUM_THETA = 16 # Inner Loop
    
    grid = [[None for _ in range(NUM_THETA)] for _ in range(NUM_PHI)]
    
    for i in range(NUM_PHI):
        # phi = TID * (2^16 / 32)
        phi = i * (2.0 * PI / 32.0)
        
        for j in range(NUM_THETA):
            # theta = j * (2^16 / 16)
            theta = j * (2.0 * PI / 16.0)
            
            # Parametric Torus
            # x = (R + r*cos(theta)) * cos(phi)
            # y = (R + r*cos(theta)) * sin(phi)
            # z = r*sin(theta)
            
            x = (R_major + r_minor * math.cos(theta)) * math.cos(phi)
            y = (R_major + r_minor * math.cos(theta)) * math.sin(phi)
            z = r_minor * math.sin(theta)
            
            vertices3d.append((x, y, z))
            grid[i][j] = len(vertices3d) - 1

    # Generate Grid Edges
    for i in range(NUM_PHI):
        for j in range(NUM_THETA):
            p1 = grid[i][j]
            
            # Connect along Theta (Ring)
            p2 = grid[i][(j + 1) % NUM_THETA]
            edges.append((p1, p2))
            
            # Connect along Phi (Tube)
            p3 = grid[(i + 1) % NUM_PHI][j]
            edges.append((p1, p3))
    
    # Diagonal Axis Rotation: Both X and Y rotate Clockwise
    
    # 1. Y-Axis: Clockwise
    angle_y = -math.radians(frame_idx * 6.0)
    cos_y, sin_y = math.cos(angle_y), math.sin(angle_y)
    
    # 2. X-Axis: Clockwise (Dynamic, same as Y)
    angle_x = -math.radians(frame_idx * 6.0)
    cos_x, sin_x = math.cos(angle_x), math.sin(angle_x)

    projected_2d = []
    for x, y, z in vertices3d:
        # Y-axis rotation
        x1 = x * cos_y + z * sin_y
        z1 = z * cos_y - x * sin_y
        
        # X-axis rotation
        y2 = y * cos_x - z1 * sin_x
        z2 = z1 * cos_x + y * sin_x
        
        # Perspective Projection
        dist = 128
        focal = 128
        w = z2 + dist
        if w == 0: w = 1
        xp = (x1 * focal) / w
        yp = (y2 * focal) / w
        
        projected_2d.append((xp + 32, yp + 32))

    if not os.path.exists(ppm_path):
        return None

    with open(ppm_path, 'r') as f:
        lines = f.readlines()
    
    if len(lines) < 3: return None
    
    # Handle PPM comments if present, though TB doesn't generate them
    # Basic robust header parsing
    header_idx = 0
    while lines[header_idx].strip().startswith('#'): header_idx += 1
    if lines[header_idx].strip() != 'P1': 
        # try next line
        header_idx += 1
    
    # Dimensions usually after P1
    dims_idx = header_idx + 1
    while lines[dims_idx].strip().startswith('#'): dims_idx += 1
    
    dims = lines[dims_idx].split()
    width, height = int(dims[0]), int(dims[1])
    
    pixels = []
    # Read data
    for line in lines[dims_idx+1:]:
        if line.strip().startswith('#'): continue
        pixels.extend(map(int, line.split()))
        
    scale = 8
    # Dark grey background from reference image
    img = Image.new('RGB', (width * scale, height * scale), (40, 40, 40))
    draw = ImageDraw.Draw(img)
    
    # Draw reference wireframe
    ref_color = (100, 100, 100) # Draw expected wireframe in grey
    for e in edges:
        p1, p2 = projected_2d[e[0]], projected_2d[e[1]]
        draw.line([p1[0]*scale, p1[1]*scale, p2[0]*scale, p2[1]*scale], fill=ref_color, width=1)
        
    # Draw GPU vertices (from simulation output)
    for y in range(height):
        for x in range(width):
            if pixels[y * width + x] == 1:
                cx, cy = x * scale, y * scale
                # Reduced point size for high density
                r = 1.0
                draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=(255, 255, 255))
                # Faint halo
                rh = 3
                draw.ellipse([cx-rh, cy-rh, cx+rh, cy+rh], outline=(255, 255, 255, 40))
    
    return img

def create_animation(ppm_pattern, output_gif):
    ppm_files = sorted(glob.glob(ppm_pattern))
    if not ppm_files:
        print(f"No files found for pattern: {ppm_pattern}")
        return

    print(f"Processing {len(ppm_files)} frames...")
    frames = []
    for i, ppm in enumerate(ppm_files):
        # Determine total frames context. If single frame file, assume 48 for rotation logic
        total = 48 if len(ppm_files) == 1 else len(ppm_files)
        img = render_frame(ppm, i, total)
        if img:
            frames.append(img)
    
    if not frames:
        print("No frames processed successfully.")
        return

    if len(frames) == 1:
        frames[0].save(output_gif)
        print(f"Image saved to {output_gif}")
    else:
        # Save as animated GIF (24 fps -> 41ms per frame)
        frames[0].save(
            output_gif,
            save_all=True,
            append_images=frames[1:],
            optimize=False,
            duration=41,
            loop=0
        )
        print(f"Animation saved to {output_gif}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python visualize_torus.py <ppm_pattern> <output_gif_or_png>")
        sys.exit(1)
        
    create_animation(sys.argv[1], sys.argv[2])
