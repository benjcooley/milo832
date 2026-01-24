import sys
import math
from PIL import Image, ImageDraw
import glob
import os

def render_frame(ppm_path, frame_idx, total_frames):
    # 3D vertices (match test_parallel_pyramid.sv)
    # V0: (-16, -16, -16)
    # V1: ( 16, -16, -16)
    # V2: ( 16, -16,  16)
    # V3: (-16, -16,  16)
    # V4: (  0,  16,   0) (Apex)
    vertices3d = [
        (-16, -16, -16), 
        ( 16, -16, -16), 
        ( 16, -16,  16), 
        (-16, -16,  16),
        (  0,  16,   0)
    ]
    
    # Pyramid Edges
    edges = [
        # Base Square
        (0, 1), (1, 2), (2, 3), (3, 0),
        # Side Edges (Base to Apex)
        (0, 4), (1, 4), (2, 4), (3, 4)
    ]
    
    # 1. Rotate around Y by dynamic angle
    angle_y = math.radians(frame_idx * (360.0 / total_frames)) if total_frames > 1 else 0
    cos_y, sin_y = math.cos(angle_y), math.sin(angle_y)
    
    # 2. Rotate around X by static 30 degrees
    angle_x = math.radians(30.0)
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
    
    dims = lines[1].split()
    width, height = int(dims[0]), int(dims[1])
    pixels = []
    for line in lines[2:]:
        pixels.extend(map(int, line.split()))
        
    scale = 8
    # Dark grey background from reference image
    img = Image.new('RGB', (width * scale, height * scale), (40, 40, 40))
    draw = ImageDraw.Draw(img)
    
    # Draw reference wireframe
    ref_color = (100, 100, 100) # Draw expected wireframe in grey
    for e in edges:
        p1, p2 = projected_2d[e[0]], projected_2d[e[1]]
        draw.line([p1[0]*scale, p1[1]*scale, p2[0]*scale, p2[1]*scale], fill=ref_color, width=2)
        
    # Draw GPU vertices (from simulation output)
    for y in range(height):
        for x in range(width):
            if pixels[y * width + x] == 1:
                cx, cy = x * scale, y * scale
                # Bright white highlights for rendered pixels
                draw.ellipse([cx-4, cy-4, cx+4, cy+4], fill=(255, 255, 255))
                draw.ellipse([cx-6, cy-6, cx+6, cy+6], outline=(255, 255, 255, 80))
    
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
        print("Usage: python visualize_pyramid.py <ppm_pattern> <output_gif_or_png>")
        sys.exit(1)
        
    create_animation(sys.argv[1], sys.argv[2])
