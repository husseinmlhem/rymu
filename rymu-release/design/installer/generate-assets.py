"""Compose MSI artwork from the approved site globe and logo, without UI input."""
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
S = 2

def xy(box):
    return tuple(round(v * S) for v in box)

def canvas(kind):
    im = Image.new("RGB", xy((600, 344)), "#f7f7f7")
    draw = ImageDraw.Draw(im)
    draw.rounded_rectangle(xy((16, 16, 234, 328)), radius=24*S, fill="#171717")
    globe = Image.open(ROOT / "apps/web/src/globe-fallback.webp").convert("RGBA")
    globe.thumbnail(xy((252, 238)), Image.Resampling.LANCZOS)
    layer = Image.new("RGBA", im.size)
    layer.paste(globe, xy((0, 73)), globe)
    mask = Image.new("L", im.size)
    ImageDraw.Draw(mask).rounded_rectangle(xy((16, 16, 234, 328)), radius=24*S, fill=255)
    im.paste(layer, (0, 0), Image.composite(layer.getchannel("A"), Image.new("L", im.size), mask))
    icon = Image.open(HERE.parent / "assets/rymu-windows.ico").convert("RGBA").resize(xy((30,30)), Image.Resampling.LANCZOS)
    im.paste(icon, xy((32,31)), icon)
    draw = ImageDraw.Draw(im)
    if kind == "welcome":
        cards = [(268,184,574,225), (268,231,574,272), (268,278,574,319)]
    elif kind == "finish":
        cards = [(268,177,574,293)]
    else:
        cards = [(268,180,574,300)]
    for box in cards:
        draw.rounded_rectangle(xy(box), radius=12*S, fill="#ffffff", outline="#dcdcdc", width=1*S)
    im.save(HERE / f"{kind}.bmp")

for page in ("welcome", "finish", "progress", "remove"):
    canvas(page)

# Standard WiX failure and file-in-use dialogs retain their own 370-DU layout.
dialog = Image.new("RGB", (555,351), "#f7f7f7")
icon = Image.open(HERE.parent / "assets/rymu-windows.ico").convert("RGBA").resize((84,84), Image.Resampling.LANCZOS)
dialog.paste(icon, (56,81), icon)
dialog.save(HERE / "dialog.bmp")
banner = Image.new("RGB", (555,66), "#f7f7f7")
icon.thumbnail((36,36), Image.Resampling.LANCZOS)
banner.paste(icon, (489,15), icon)
banner.save(HERE / "banner.bmp")
