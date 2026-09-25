import os
import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def create_musi_logo(size=512):
    # Create super-sampled image for smooth anti-aliased curves
    scale = 4
    canvas_size = size * scale
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. Background Rounded Squircle
    padding = int(24 * scale)
    corner_radius = int(100 * scale)
    
    # Gradient background: Deep obsidian to dark royal violet
    bg = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    
    # Draw rounded rectangle mask
    bg_draw.rounded_rectangle(
        [padding, padding, canvas_size - padding, canvas_size - padding],
        radius=corner_radius,
        fill=(15, 16, 26, 255) # #0F101A
    )
    
    # Subtle inner gradient overlay
    for i in range(padding, canvas_size - padding):
        t = (i - padding) / (canvas_size - 2 * padding)
        # Gradient from #1E1238 at top to #0D0E17 at bottom
        r = int(30 * (1 - t) + 13 * t)
        g = int(18 * (1 - t) + 14 * t)
        b = int(56 * (1 - t) + 23 * t)
        # We can draw horizontal lines masked
    
    img.paste(bg, (0, 0), bg)
    draw = ImageDraw.Draw(img)

    # Subtle outer glow border
    draw.rounded_rectangle(
        [padding, padding, canvas_size - padding, canvas_size - padding],
        radius=corner_radius,
        outline=(139, 92, 246, 90), # #8B5CF6 with alpha
        width=int(6 * scale)
    )

    # 2. Central Music Emblem:
    # A stylish modern icon with stylized soundwaves + music note in electric violet gradient
    # Center coordinates
    cx = canvas_size // 2
    cy = canvas_size // 2 - int(20 * scale)

    # Draw vibrant soundwave bars forming an 'M' shape / rhythm curve
    # Bar heights forming rhythmic M pattern: [short, medium, high, medium, high, medium, short]
    bar_heights = [70, 130, 190, 120, 190, 130, 70]
    bar_width = int(22 * scale)
    spacing = int(16 * scale)
    total_bars_width = len(bar_heights) * bar_width + (len(bar_heights) - 1) * spacing
    start_x = cx - total_bars_width // 2

    # Draw glowing backdrop behind bars
    glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        [cx - int(140 * scale), cy - int(120 * scale), cx + int(140 * scale), cy + int(120 * scale)],
        fill=(124, 58, 237, 70) # violet glow
    )
    glow = glow.filter(ImageFilter.GaussianBlur(int(35 * scale)))
    img.paste(glow, (0, 0), glow)
    draw = ImageDraw.Draw(img)

    # Color palette for bars: Gradient from #7C3AED (violet) to #EC4899 (pink/rose)
    for idx, h in enumerate(bar_heights):
        bx = start_x + idx * (bar_width + spacing)
        bh = int(h * scale)
        by1 = cy - bh // 2
        by2 = cy + bh // 2
        radius = bar_width // 2
        
        # Color interpolation across bars
        ratio = idx / (len(bar_heights) - 1)
        r = int(139 * (1 - ratio) + 236 * ratio)
        g = int(92 * (1 - ratio) + 72 * ratio)
        b = int(246 * (1 - ratio) + 153 * ratio)
        
        draw.rounded_rectangle(
            [bx, by1, bx + bar_width, by2],
            radius=radius,
            fill=(r, g, b, 255)
        )

    # 3. Text "Musi" at bottom of squircle
    # Simple clean typographic dots or letter accents
    # Draw "MUSI" or clean sound dots
    dot_y = canvas_size - padding - int(60 * scale)
    # 4 stylish dots below
    dot_radius = int(7 * scale)
    for i in range(4):
        dx = cx - int(45 * scale) + i * int(30 * scale)
        alpha = 255 if i == 1 or i == 2 else 140
        draw.ellipse(
            [dx - dot_radius, dot_y - dot_radius, dx + dot_radius, dot_y + dot_radius],
            fill=(167, 139, 250, alpha)
        )

    # Downsample to target size with Lanczos for ultra-crisp quality
    final_img = img.resize((size, size), Image.Resampling.LANCZOS)
    return final_img

# Output directories
base_res = r"c:\Users\sreel\OneDrive\Desktop\Musi\musi\android\app\src\main\res"

sizes = {
    os.path.join(base_res, "mipmap-mdpi", "ic_launcher.png"): 48,
    os.path.join(base_res, "mipmap-hdpi", "ic_launcher.png"): 72,
    os.path.join(base_res, "mipmap-xhdpi", "ic_launcher.png"): 96,
    os.path.join(base_res, "mipmap-xxhdpi", "ic_launcher.png"): 144,
    os.path.join(base_res, "mipmap-xxxhdpi", "ic_launcher.png"): 192,
    os.path.join(base_res, "drawable", "musi_splash_logo.png"): 384,
}

for path, size in sizes.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    icon = create_musi_logo(size)
    icon.save(path, "PNG")
    print(f"Generated {path} ({size}x{size})")

print("All Musi logos generated successfully!")
