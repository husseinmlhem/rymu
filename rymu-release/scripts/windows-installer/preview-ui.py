"""Show an inactive native MSI dialog preview, with no installation actions."""
import argparse
import ctypes
from ctypes import wintypes as w
from pathlib import Path
import time

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument("msi", type=Path)
cli.add_argument("dialog", choices=("RymuWelcomeDlg", "RymuRemoveDlg", "RymuConfirmRemoveDlg", "RymuProgressDlg", "RymuExitDlg"))
cli.add_argument("--seconds", type=int, default=30, choices=range(1, 61))
args = cli.parse_args()
msi = ctypes.WinDLL("msi.dll")
user = ctypes.WinDLL("user32.dll")
msi.MsiOpenDatabaseW.argtypes = (w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(w.UINT))
msi.MsiEnableUIPreview.argtypes = (w.UINT, ctypes.POINTER(w.UINT))
msi.MsiPreviewDialogW.argtypes = (w.UINT, w.LPCWSTR)
msi.MsiCloseHandle.argtypes = (w.UINT,)

def check(status):
    if status:
        raise OSError(f"MSI preview returned {status}")

db, preview = w.UINT(), w.UINT()
check(msi.MsiOpenDatabaseW(str(args.msi.resolve(strict=True)), None, ctypes.byref(db)))
try:
    check(msi.MsiEnableUIPreview(db, ctypes.byref(preview)))
    check(msi.MsiPreviewDialogW(preview, args.dialog))
    print(f"READ-ONLY native preview: {args.dialog}; buttons are inactive, no setup actions", flush=True)
    deadline = time.monotonic() + args.seconds
    message = w.MSG()
    while time.monotonic() < deadline:
        while user.PeekMessageW(ctypes.byref(message), None, 0, 0, 1):
            user.TranslateMessage(ctypes.byref(message))
            user.DispatchMessageW(ctypes.byref(message))
        time.sleep(0.02)
finally:
    if preview.value:
        msi.MsiPreviewDialogW(preview, None)
        msi.MsiCloseHandle(preview)
    msi.MsiCloseHandle(db)
