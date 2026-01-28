#!/usr/bin/env python3
"""Convert PPM to PNG using PIL"""
import sys
try:
    from PIL import Image
except ImportError:
    print("Installing Pillow...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow", "-q"])
    from PIL import Image

def ppm_to_png(ppm_path, png_path, scale=8):
    """Convert PPM to scaled PNG"""
    with open(ppm_path, 'r') as f:
        # Skip header
        magic = f.readline().strip()
        assert magic == "P3", f"Expected P3 PPM, got {magic}"
        dims = f.readline().strip().split()
        width, height = int(dims[0]), int(dims[1])
        max_val = int(f.readline().strip())
        
        # Read pixel data
        pixels = []
        for line in f:
            values = line.strip().split()
            pixels.extend([int(v) for v in values])
        
        # Create image
        img = Image.new('RGB', (width, height))
        pixel_data = []
        for i in range(0, len(pixels), 3):
            r, g, b = pixels[i], pixels[i+1], pixels[i+2]
            pixel_data.append((r, g, b))
        
        img.putdata(pixel_data)
        
        # Scale up for better visibility
        img = img.resize((width * scale, height * scale), Image.NEAREST)
        img.save(png_path)
        print(f"Saved {png_path} ({width*scale}x{height*scale})")

if __name__ == "__main__":
    ppm_to_png("rendered_scene.ppm", "rendered_scene.png")
    print("Done!")
