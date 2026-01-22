import sys
import math
from PIL import Image, ImageDraw

import glob
import os

def render_frame(ppm_path, frame_idx, total_frames):
    # 3D vertices
    vertices3d = [
        (-16, -16, -16), (16, -16, -16), (16, 16, -16), (-16, 16, -16),
        (-16, -16,  16), (16, -16,  16), (16, 16,  16), (-16, 16,  16)
    ]
    edges = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (6, 7), (7, 4), (5, 6),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]
    
    # Rotation angle matching Verilog (frame * (360 / total_frames))
    angle = math.radians(frame_idx * (360.0 / total_frames))
    cos_th, sin_th = math.cos(angle), math.sin(angle)
    rotated_2d = []
    for x, y, z in vertices3d:
        xr = x * cos_th + z * sin_th
        rotated_2d.append((xr + 32, y + 32))

    with open(ppm_path, 'r') as f:
        lines = f.readlines()
    
    dims = lines[1].split()
    width, height = int(dims[0]), int(dims[1])
    pixels = []
    for line in lines[2:]:
        pixels.extend(map(int, line.split()))
        
    scale = 8
    img = Image.new('RGB', (width * scale, height * scale), (5, 5, 10))
    draw = ImageDraw.Draw(img)
    
    # Draw reference wireframe
    ref_color = (60, 60, 100)
    for e in edges:
        p1, p2 = rotated_2d[e[0]], rotated_2d[e[1]]
        draw.line([p1[0]*scale, p1[1]*scale, p2[0]*scale, p2[1]*scale], fill=ref_color, width=1)
        
    # Draw GPU vertices
    for y in range(height):
        for x in range(width):
            if pixels[y * width + x] == 1:
                cx, cy = x * scale, y * scale
                draw.ellipse([cx-3, cy-3, cx+3, cy+3], fill=(255, 255, 255))
                draw.ellipse([cx-5, cy-5, cx+5, cy+5], outline=(255, 255, 255, 50))
    
    return img

def create_animation(ppm_pattern, output_gif):
    ppm_files = sorted(glob.glob(ppm_pattern))
    if not ppm_files:
        print(f"No files found for pattern: {ppm_pattern}")
        return

    print(f"Processing {len(ppm_files)} frames...")
    frames = []
    for i, ppm in enumerate(ppm_files):
        frames.append(render_frame(ppm, i, len(ppm_files)))
    
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
    if "*" in sys.argv[1]:
        create_animation(sys.argv[1], sys.argv[2])
    else:
        # Fallback to single frame
        img = render_frame(sys.argv[1], 6, 48) # Default 45 deg if single
        img.save(sys.argv[2])
