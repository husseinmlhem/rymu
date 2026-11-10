"""Static source-layout previews, not screenshots or executed installer results."""
from pathlib import Path
import re
import textwrap
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
NS={"w":"http://schemas.microsoft.com/wix/2006/wi"}
tree=ET.parse(HERE/"rymu-ui.wxi")
styles={e.attrib["Id"]:e.attrib for e in tree.findall(".//w:TextStyle",NS)}
S=2
fontdir=Path("C:/Windows/Fonts")

def font(style):
    spec=styles[style]
    return ImageFont.truetype(str(fontdir/("segoeuib.ttf" if spec.get("Bold")=="yes" else "segoeui.ttf")),round(int(spec["Size"])*S))

def draw_text(draw,xy,text,style,width):
    spec=styles[style]; f=font(style)
    color=tuple(int(spec.get(k,"35")) for k in ("Red","Green","Blue"))
    lines=[]
    for paragraph in text.replace("\r","").split("\n"):
        line=""
        for word in paragraph.split(" "):
            proposed=f"{line} {word}".strip()
            if line and draw.textlength(proposed,font=f)>width:
                lines.append(line);line=word
            else:line=proposed
        lines.append(line)
    draw.multiline_text(xy,"\n".join(lines),font=f,fill=color,spacing=2*S)

for ident,name in (("RymuWelcomeDlg","welcome"),("RymuExitDlg","finish"),("RymuConfirmRemoveDlg","remove")):
    dialog=tree.find(f'.//w:Dialog[@Id="{ident}"]',NS)
    im=Image.new("RGB",(1200,844),"#f0f0f0")
    draw=ImageDraw.Draw(im)
    draw.text((20,9),"Rymu Setup",font=ImageFont.truetype(str(fontdir/"segoeui.ttf"),18),fill="#515151")
    draw.text((1165,6),"×",font=ImageFont.truetype(str(fontdir/"segoeui.ttf"),24),fill="#515151")
    im.paste(Image.open(HERE/f"{name}.bmp"),(0,40))
    draw=ImageDraw.Draw(im)
    for c in dialog.findall("w:Control",NS):
        a=c.attrib
        if a.get("Hidden")=="yes" or a["Type"]=="Bitmap":continue
        x,y,w,h=[int(a[k])*S for k in ("X","Y","Width","Height")];y+=40
        value=a.get("Text","").replace("[ProductVersion]","0.1.12")
        style="WixUI_Font_Normal"
        match=re.match(r"\{\\([^}]+)\}",value)
        if match:style=match.group(1);value=value[match.end():]
        if a["Type"]=="Text":draw_text(draw,(x,y),value,style,w)
        elif a["Type"]=="Line":draw.line((x,y,x+w,y),fill="#dcdcdc",width=1)
        elif a["Type"]=="CheckBox":
            draw.rounded_rectangle((x,y+4,x+22,y+26),radius=3,fill="#171717")
            draw.line((x+5,y+15,x+10,y+21,x+18,y+9),fill="white",width=2)
            draw_text(draw,(x+30,y),value,style,w-30)
        elif a["Type"]=="PushButton":
            draw.rounded_rectangle((x,y,x+w,y+h),radius=5,fill="#ffffff",outline="#6c6c6c",width=1)
            f=font(style); value=value.replace("&","")
            draw.text((x+(w-draw.textlength(value,font=f))/2,y+8),value,font=f,fill="#171717")
    draw.rectangle((0,820,1200,844),fill="#171717")
    draw.text((18,824),"SOURCE LAYOUT PREVIEW  /  Native Windows controls may render slightly differently  /  Not an install test",font=ImageFont.truetype(str(fontdir/"segoeui.ttf"),12),fill="#ffffff")
    im.save(ROOT/f"artifacts/screenshots/windows-0.1.12-installer-{name}-design.png")
