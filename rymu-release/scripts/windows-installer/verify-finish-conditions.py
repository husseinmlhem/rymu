"""Evaluate actual MSI Finish conditions in memory; never execute custom actions."""
import argparse
import ctypes
from ctypes import wintypes as w
from pathlib import Path

cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument("msi",type=Path)
args=cli.parse_args()
msi=ctypes.WinDLL("msi.dll")
msi.MsiOpenDatabaseW.argtypes=(w.LPCWSTR,w.LPCWSTR,ctypes.POINTER(w.UINT))
msi.MsiDatabaseOpenViewW.argtypes=(w.UINT,w.LPCWSTR,ctypes.POINTER(w.UINT))
msi.MsiViewExecute.argtypes=(w.UINT,w.UINT)
msi.MsiViewFetch.argtypes=(w.UINT,ctypes.POINTER(w.UINT))
msi.MsiRecordGetStringW.argtypes=(w.UINT,w.UINT,w.LPWSTR,ctypes.POINTER(w.DWORD))
msi.MsiOpenPackageExW.argtypes=(w.LPCWSTR,w.DWORD,ctypes.POINTER(w.UINT))
msi.MsiSetPropertyW.argtypes=(w.UINT,w.LPCWSTR,w.LPCWSTR)
msi.MsiEvaluateConditionW.argtypes=(w.UINT,w.LPCWSTR)
msi.MsiSetInternalUI.argtypes=(w.UINT,ctypes.POINTER(w.HWND))
msi.MsiCloseHandle.argtypes=(w.UINT,)
def check(status):
    if status: raise OSError(f"MSI status {status}")
db,view,session=w.UINT(),w.UINT(),w.UINT()
try:
    path=str(args.msi.resolve(strict=True))
    check(msi.MsiOpenDatabaseW(path,None,ctypes.byref(db)))
    check(msi.MsiDatabaseOpenViewW(db,"SELECT `Event`, `Argument`, `Condition`, `Ordering` FROM `ControlEvent` WHERE `Dialog_`='RymuExitDlg' AND `Control_`='Finish'",ctypes.byref(view)))
    check(msi.MsiViewExecute(view,0)); rows=[]
    while True:
        record=w.UINT(); status=msi.MsiViewFetch(view,ctypes.byref(record))
        if status==259:break
        check(status)
        try:
            fields=[]
            for n in range(1,5):
                text=ctypes.create_unicode_buffer(2048); size=w.DWORD(len(text))
                check(msi.MsiRecordGetStringW(record,n,text,ctypes.byref(size)));fields.append(text.value)
            rows.append(fields)
        finally:msi.MsiCloseHandle(record)
    rows.sort(key=lambda r:int(r[3]))
    msi.MsiSetInternalUI(2,None)
    # IGNOREMACHINESTATE: an in-memory session for expressions only, not a setup run.
    check(msi.MsiOpenPackageExW(path,1,ctypes.byref(session)))
    base={"UILevel":"5","Installed":"","REMOVE":"","REINSTALL":"","PATCH":"","ACTION":"INSTALL","RYMU_LAUNCH_NOW":"1","RYMU_START_WINDOWS":"1"}
    cases=[
        ("both_on",{},"on",True),
        ("launch_off",{"RYMU_LAUNCH_NOW":""},"on",False),
        ("startup_off",{"RYMU_START_WINDOWS":""},"off",True),
        ("both_off",{"RYMU_LAUNCH_NOW":"","RYMU_START_WINDOWS":""},"off",False),
        ("silent",{"UILevel":"2"},None,False),
        ("basic",{"UILevel":"3"},None,False),
        ("reduced",{"UILevel":"4"},None,False),
        ("uninstall",{"REMOVE":"ALL"},None,False),
        ("repair",{"Installed":"1","REINSTALL":"ALL"},None,False),
        ("maintenance",{"Installed":"1"},None,False),
        ("patch",{"PATCH":"fixture-patch"},None,False),
        ("admin_image",{"ACTION":"ADMIN"},None,False),
    ]
    for name,updates,expected_mode,launch in cases:
        for key,value in (base|updates).items():check(msi.MsiSetPropertyW(session,key,value))
        mode=[]; actions=[]
        for event,argument,condition,_ in rows:
            result=msi.MsiEvaluateConditionW(session,condition)
            assert result in (0,1), (name,condition,result)
            if not result:continue
            if event=="[RYMU_STARTUP_ARG]":mode.append(argument)
            if event=="DoAction":actions.append(argument)
        assert mode==([] if expected_mode is None else [expected_mode]),(name,mode)
        expected=[] if expected_mode is None else ["RymuApplyStartup"]+(["RymuLaunchNow"] if launch else [])
        assert actions==expected,(name,actions)
        print(f"PASS {name}: startup={expected_mode or 'not invoked'}, launch={launch}")
    print("PASS 12 actual Windows Installer condition scenarios; zero custom actions executed")
finally:
    for h in (session,view,db):
        if h.value:msi.MsiCloseHandle(h)
