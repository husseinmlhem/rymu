"""Author the native MSI globe layout with accessible controls and explicit finish actions."""
from pathlib import Path
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
NS = "http://schemas.microsoft.com/wix/2006/wi"
ET.register_namespace("", NS)

def e(parent, tag, **attrs):
    return ET.SubElement(parent, f"{{{NS}}}{tag}", {k: str(v) for k,v in attrs.items()})

def publish(control, event=None, value=None, condition="1", order=None, prop=None):
    attrs = {"Value": value}
    attrs["Property" if prop else "Event"] = prop or event
    if order is not None: attrs["Order"] = order
    node = e(control, "Publish", **attrs)
    node.text = condition

def condition(control, action, value):
    e(control, "Condition", Action=action).text = value

def text(dialog, ident, x, y, width, height, value, style="WixUI_Font_Normal", **attrs):
    return e(dialog, "Control", Id=ident, Type="Text", X=x, Y=y, Width=width, Height=height,
             Transparent="yes", NoPrefix="yes", Text=f"{{\\{style}}}{value}", **attrs)

def button(dialog, ident, x, title, default=False, cancel=False, width=88):
    attrs = {}
    if default: attrs["Default"] = "yes"
    if cancel: attrs["Cancel"] = "yes"
    return e(dialog, "Control", Id=ident, Type="PushButton", X=x, Y=358, Width=width, Height=22, Text=title, **attrs)

root = ET.Element(f"{{{NS}}}Include")
ui = e(root, "UI", Id="RymuUI")
for ident, size, color, bold in [
    ("WixUI_Font_Normal",9,35,False), ("WixUI_Font_Bigger",22,23,True),
    ("WixUI_Font_Title",11,23,True), ("RymuMuted",8,81,False),
    ("RymuStep",7,110,False), ("RymuStepActive",7,23,True),
    ("RymuWhite",12,245,False), ("RymuBrand",20,255,True)]:
    attrs = {"Bold":"yes"} if bold else {}
    e(ui,"TextStyle",Id=ident,FaceName="Segoe UI",Size=size,Red=color,Green=color,Blue=color,**attrs)
e(ui,"Property",Id="DefaultUIFont",Value="WixUI_Font_Normal")
e(ui,"Property",Id="RYMU_LAUNCH_NOW",Value="1")
e(ui,"Property",Id="RYMU_START_WINDOWS",Value="1")
for ident in ("ErrorDlg","FatalError","UserExit","FilesInUse","MsiRMFilesInUse","OutOfDiskDlg"):
    e(ui,"DialogRef",Id=ident)

def dialog(ident, kind, step, modeless=False):
    d=e(ui,"Dialog",Id=ident,Width=600,Height=390,Title="Rymu Setup", **({"Modeless":"yes"} if modeless else {}))
    # Native controls and bitmap use identical geometry in the source preview.
    e(d,"Control",Id="Artwork",Type="Bitmap",X=0,Y=0,Width=600,Height=344,Text=f"Rymu_{kind}")
    text(d,"Brand",70,32,140,30,"rymu", "RymuBrand")
    text(d,"HeroCaption",32,284,184,34,"Free essentials.\r\nAlways.","RymuWhite")
    for number,label in enumerate(("REVIEW","REMOVE","DONE") if kind=="remove" else ("SET UP","INSTALL","READY"),1):
        c=text(d,f"Step{number}",268+(number-1)*102,29,102,14,f"0{number}  {label}","RymuStepActive" if number==step else "RymuStep")
        if kind in ("progress","finish"):
            condition(c,"hide",'REMOVE = "ALL"')
            c=text(d,f"RemoveStep{number}",268+(number-1)*102,29,102,14,f'0{number}  {("REVIEW","REMOVE","DONE")[number-1]}',"RymuStepActive" if number==step else "RymuStep",Hidden="yes")
            condition(c,"show",'REMOVE = "ALL"')
    e(d,"Control",Id="BottomLine",Type="Line",X=0,Y=344,Width=600,Height=0)
    text(d,"Version",20,363,272,14,"RYMU  /  [ProductVersion]  /  WINDOWS 11 x64", "RymuStep")
    return d

d=dialog("RymuWelcomeDlg","welcome",1)
text(d,"Title",268,67,304,62,"Your desktop.\r\nAnywhere.","WixUI_Font_Bigger")
text(d,"Intro",268,139,304,31,"Connect to your computer from your phone or another PC. One familiar account.")
for number,(title,body) in enumerate((
    ("Free essentials, forever", "Everyday remote access without a subscription."),
    ("Your devices, together", "Windows host. Android and Windows controllers."),
    ("Keep what matters", "Your saved sign-in and settings stay when you update."))):
    y=184+47*number
    text(d,f"FeatureTitle{number}",282,y+7,278,15,title,"WixUI_Font_Title")
    text(d,f"FeatureBody{number}",282,y+24,278,13,body,"RymuMuted")
b=button(d,"Install",398,"&Install Rymu",True,width=100)
publish(b,"EndDialog","Return","OutOfDiskSpace <> 1")
publish(b,"SpawnDialog","OutOfDiskDlg","OutOfDiskSpace = 1")
b=button(d,"Cancel",510,"Cancel",cancel=True,width=70)
publish(b,"SpawnDialog","CancelDlg")

d=dialog("RymuProgressDlg","progress",2,True)
text(d,"Title",268,69,304,63,"A moment.\r\nThen, anywhere.","WixUI_Font_Bigger")
t=text(d,"Installing",268,140,304,32,"Windows is setting up Rymu for this account. Your personal files stay in place.")
condition(t,"hide",'REMOVE = "ALL"')
t=text(d,"Removing",268,140,304,32,"Windows is removing the app. Your account settings and personal files stay in place.",Hidden="yes")
condition(t,"show",'REMOVE = "ALL"')
text(d,"ProgressLabel",284,197,274,16,"Setup progress","WixUI_Font_Title")
c=e(d,"Control",Id="ProgressBar",Type="ProgressBar",X=284,Y=225,Width=274,Height=10,ProgressBlocks="no")
e(c,"Subscribe",Event="SetProgress",Attribute="Progress")
c=text(d,"ActionText",284,249,274,34,"", "RymuMuted")
e(c,"Subscribe",Event="ActionText",Attribute="Text")
text(d,"Wait",268,312,304,14,"Keep this window open until setup finishes.","RymuMuted")
b=button(d,"Cancel",510,"Cancel",True,True,width=70)
publish(b,"SpawnDialog","CancelDlg")

for confirm in (False,True):
    d=dialog("RymuConfirmRemoveDlg" if confirm else "RymuRemoveDlg","remove",1)
    text(d,"Title",268,67,304,63,"Ready to\r\nremove Rymu?" if confirm else "Your setup.\r\nYour choice.","WixUI_Font_Bigger")
    text(d,"Intro",268,141,304,30,"Uninstalling ends remote access through this installation." if confirm else "Rymu is installed for your Windows account. Keep it, or remove the app from this computer.")
    text(d,"KeepHeading",284,195,274,18,"Your data stays yours","WixUI_Font_Title")
    text(d,"KeepText",284,222,274,60,"Saved sign-in, settings and personal files remain.\r\n\r\nBefore continuing, quit Rymu from its tray menu to end active connections.")
    if confirm:
        b=button(d,"Back",398,"&Back",True,width=100)
        publish(b,"NewDialog","RymuRemoveDlg")
        b=button(d,"Remove",510,"&Uninstall",width=70)
        publish(b,prop="REMOVE",value="ALL",order=1)
        publish(b,"Remove","ALL",order=2)
        publish(b,"EndDialog","Return",order=3)
        b=button(d,"Cancel",308,"Cancel",cancel=True,width=78)
        publish(b,"EndDialog","Exit")
    else:
        b=button(d,"Keep",398,"&Keep Rymu",True,True,width=100)
        publish(b,"EndDialog","Exit")
        b=button(d,"Remove",510,"&Uninstall",width=70)
        publish(b,"NewDialog","RymuConfirmRemoveDlg")

d=dialog("RymuExitDlg","finish",3)
finish_gate='UILevel >= 5 AND NOT Installed AND NOT REMOVE AND NOT REINSTALL AND NOT PATCH AND ACTION <> "ADMIN"'
t=text(d,"InstalledTitle",268,67,304,62,"Welcome\r\nto Rymu.","WixUI_Font_Bigger")
condition(t,"hide",'REMOVE = "ALL" OR ACTION = "ADMIN"')
t=text(d,"RemovedTitle",268,67,304,62,"Rymu\r\nis removed.","WixUI_Font_Bigger",Hidden="yes")
condition(t,"show",'REMOVE = "ALL"')
t=text(d,"AdminTitle",268,67,304,62,"Package\r\nis ready.","WixUI_Font_Bigger",Hidden="yes")
condition(t,"show",'ACTION = "ADMIN"')
t=text(d,"Intro",268,139,304,30,"Everything is in place. Choose how Rymu starts, then finish setup.")
condition(t,"hide",f"NOT ({finish_gate})")
for ident,prop,y,label,detail in (
    ("LaunchNow","RYMU_LAUNCH_NOW",190,"Launch Rymu now","Open the app when you finish setup."),
    ("StartWindows","RYMU_START_WINDOWS",241,"Start Rymu with Windows","Starts after you sign in to Windows.")):
    c=e(d,"Control",Id=ident,Type="CheckBox",X=282,Y=y,Width=278,Height=18,Property=prop,CheckBoxValue="1",Text=label)
    condition(c,"hide",f"NOT ({finish_gate})")
    t=text(d,ident+"Detail",296,y+22,262,16,detail,"RymuMuted")
    condition(t,"hide",f"NOT ({finish_gate})")
t=text(d,"LaterNote",268,306,304,26,"Finish saves these choices. Close leaves them unchanged.","RymuMuted")
condition(t,"hide",f"NOT ({finish_gate})")
t=text(d,"RemovedText",284,195,274,90,"The app has been removed. Your saved account settings and personal files are still on this computer.\r\n\r\nYou can install Rymu again whenever you need it.",Hidden="yes")
condition(t,"show",'REMOVE = "ALL"')
t=text(d,"MaintainedText",284,195,274,90,"Rymu setup is complete. Your startup preference has not been changed.\r\n\r\nOpen Rymu from the Start menu when you are ready.",Hidden="yes")
condition(t,"show",f'NOT ({finish_gate}) AND REMOVE <> "ALL" AND ACTION <> "ADMIN"')
t=text(d,"AdminText",284,195,274,90,"The administrative package is ready. This operation has not started Rymu or changed its startup preference.",Hidden="yes")
condition(t,"show",'ACTION = "ADMIN"')
b=button(d,"Finish",480,"&Finish",True,width=100)
publish(b,prop="RYMU_STARTUP_ARG",value="on",order=1,condition=f'{finish_gate} AND RYMU_START_WINDOWS = "1"')
publish(b,prop="RYMU_STARTUP_ARG",value="off",order=2,condition=f'{finish_gate} AND RYMU_START_WINDOWS <> "1"')
publish(b,"DoAction","RymuApplyStartup",finish_gate,3)
publish(b,"DoAction","RymuLaunchNow",f'{finish_gate} AND RYMU_LAUNCH_NOW = "1"',4)
publish(b,"EndDialog","Return",order=5)
b=button(d,"Close",390,"Close",cancel=True,width=78)
publish(b,"EndDialog","Return")

sequence=e(ui,"InstallUISequence")
e(sequence,"Show",Dialog="RymuWelcomeDlg",Before="RymuProgressDlg").text="NOT Installed OR RESUME"
e(sequence,"Show",Dialog="RymuRemoveDlg",Before="RymuWelcomeDlg").text="Installed AND NOT RESUME AND NOT PATCH AND NOT REINSTALL"
e(sequence,"Show",Dialog="RymuProgressDlg",Before="ExecuteAction")
e(sequence,"Show",Dialog="RymuExitDlg",OnExit="success")
e(e(ui,"AdminUISequence"),"Show",Dialog="RymuExitDlg",OnExit="success")
e(root,"UIRef",Id="WixUI_Common")
ET.indent(root)
ET.ElementTree(root).write(HERE / "rymu-ui.wxi", encoding="utf-8", xml_declaration=True)
