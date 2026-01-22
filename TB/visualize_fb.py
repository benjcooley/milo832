import sys
from PIL import Image, ImageDraw

def convert_ppm_to_png(ppm_path, png_path):
    # Cube definition (from testbench)
    vertices = [
        (16, 16), (48, 16), (48, 48), (16, 48), # Back face
        (20, 20), (44, 20), (44, 44), (20, 44)  # Front face
    ]
    edges = [
        (0, 1), (1, 2), (2, 3), (3, 0), # Back face
        (4, 5), (5, 6), (6, 7), (7, 4), # Front face
        (0, 4), (1, 5), (2, 6), (3, 7)  # Connecting edges
    ]
    
    try:
        # Read the P1 PPM (ASCII)
        with open(ppm_path, 'r') as f:
            lines = f.readlines()
        
        # Parse header
        magic = lines[0].strip()
        if magic != 'P1':
            print(f"Error: Expected P1 magic number, got {magic}")
            return
            
        dims = lines[1].strip().split()
        width, height = int(dims[0]), int(dims[1])
        
        # Parse data
        pixels = []
        for line in lines[2:]:
            pixels.extend(map(int, line.split()))
            
        # Scale for output (8x)
        scale = 8
        out_width, out_height = width * scale, height * scale
        
        # Create final high-res image
        img = Image.new('RGB', (out_width, out_height), (10, 10, 15)) # Dark blue-black bg
        draw = ImageDraw.Draw(img)
        
        # 1. Draw wireframe edges (blue-gray reference)
        ref_color = (60, 60, 80)
        for edge in edges:
            v1_idx, v2_idx = edge
            v1 = vertices[v1_idx]
            v2 = vertices[v2_idx]
            draw.line([v1[0]*scale, v1[1]*scale, v2[0]*scale, v2[1]*scale], 
                      fill=ref_color, width=1)
        
        # 2. Draw simulation pixels from PPM (Clean white dots)
        # We draw them as slightly anti-aliased circles to avoid "square" artifacts
        for y in range(height):
            for x in range(width):
                if pixels[y * width + x] == 1:
                    cx, cy = x * scale, y * scale
                    # Draw a nice clean dot
                    draw.ellipse([cx-3, cy-3, cx+3, cy+3], fill=(255, 255, 255))
                    # Add a subtle glow
                    draw.ellipse([cx-5, cy-5, cx+5, cy+5], outline=(255, 255, 255, 50))

        img.save(png_path)
        print(f"Successfully rendered clean visualization to {png_path}")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 visualize_fb.py <input.ppm> <output.png>")
    else:
        convert_ppm_to_png(sys.argv[1], sys.argv[2])
