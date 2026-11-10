"""Build Android drawable layers and Dart mark from the canonical Rymu SVG."""

from pathlib import Path
import re
from xml.etree import ElementTree as ET
from xml.sax.saxutils import quoteattr


def save(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


flutter = Path(__file__).resolve().parents[1]
assets = flutter.parents[2] / "design" / "assets"
resource = flutter / "android" / "app" / "src" / "main" / "res"
namespace = "{http://www.w3.org/2000/svg}"

mark = (assets / "rymu-mark.svg").read_text(encoding="utf-8").strip()
save(flutter / "lib" / "rymu_android" / "brand.dart",
     "// Generated from design/assets/rymu-mark.svg.\n"
     "const rymuMarkSvg = r'''\n" + mark + "\n''';\n")

foreground = ET.parse(assets / "rymu-android-foreground.svg").getroot()
background = ET.parse(assets / "rymu-android-background.svg").getroot()
outer, = foreground.findall(f"{namespace}g")
inner, = outer.findall(f"{namespace}g")
translate_scale = re.fullmatch(r"translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)", outer.attrib["transform"])
translate = re.fullmatch(r"translate\((-?[\d.]+) (-?[\d.]+)\)", inner.attrib["transform"])
assert translate_scale and translate, "Unexpected SVG group transform"
x, y, scale = translate_scale.groups()
inner_x, inner_y = translate.groups()
gradients = {gradient.attrib["id"]: gradient for gradient in foreground.iter(f"{namespace}linearGradient")}
paths = inner.findall(f"{namespace}path")
background_color = background.find(f"{namespace}path").attrib["fill"]


def draw_path(path: ET.Element, gradient_enabled: bool) -> str:
    source = gradients[path.attrib["fill"][5:-1]]
    geometry = quoteattr(path.attrib["d"])
    stops = list(source)
    if not gradient_enabled:
        return f'      <path android:pathData={geometry} android:fillColor={quoteattr(stops[1].attrib["stop-color"])} />'
    coordinates = " ".join(
        f'android:{dest}={quoteattr(source.attrib[key])}'
        for key, dest in zip(("x1", "y1", "x2", "y2"), ("startX", "startY", "endX", "endY"))
    )
    items = "\n".join(
        f'            <item android:offset={quoteattr(stop.attrib.get("offset", "0"))} android:color={quoteattr(stop.attrib["stop-color"])} />'
        for stop in stops
    )
    return f'''      <path android:pathData={geometry}>
        <aapt:attr name="android:fillColor">
          <gradient android:type="linear" {coordinates}>
{items}
          </gradient>
        </aapt:attr>
      </path>'''


def vector(*, tile: bool, gradient: bool) -> str:
    outline = (f'  <path android:fillColor="{background_color}" android:pathData="'
               'M22 0h64q22 0 22 22v64q0 22 -22 22H22Q0 108 0 86V22Q0 0 22 0Z" />\n') if tile else ""
    paths_xml = "\n".join(draw_path(path, gradient) for path in paths)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
{outline}  <group android:translateX="{x}" android:translateY="{y}" android:scaleX="{scale}" android:scaleY="{scale}">
    <group android:translateX="{inner_x}" android:translateY="{inner_y}">
{paths_xml}
    </group>
  </group>
</vector>
'''


save(resource / "drawable-v26" / "rymu_adaptive_foreground.xml", vector(tile=False, gradient=True))
save(resource / "mipmap-anydpi" / "ic_launcher.xml", vector(tile=True, gradient=False))
save(resource / "mipmap-anydpi-v24" / "ic_launcher.xml", vector(tile=True, gradient=True))
save(resource / "mipmap-anydpi-v26" / "ic_launcher.xml", '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/rymu_launcher_background" />
  <foreground android:drawable="@drawable/rymu_adaptive_foreground" />
</adaptive-icon>
''')
save(resource / "values" / "rymu_colors.xml", f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
  <color name="rymu_launcher_background">{background_color}</color>
</resources>
''')
