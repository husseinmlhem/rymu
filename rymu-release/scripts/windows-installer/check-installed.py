"""Read-only verification of an already completed per-user MSI installation."""
import argparse
import ctypes
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import winreg

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument("msi", type=Path)
cli.add_argument("runner", type=Path)
cli.add_argument("--preservation-record", type=Path)
args = cli.parse_args()
msi = ctypes.WinDLL("msi.dll")
msi.MsiOpenDatabaseW.argtypes = (w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(w.UINT))
msi.MsiDatabaseOpenViewW.argtypes = (w.UINT, w.LPCWSTR, ctypes.POINTER(w.UINT))
msi.MsiViewExecute.argtypes = (w.UINT, w.UINT)
msi.MsiViewFetch.argtypes = (w.UINT, ctypes.POINTER(w.UINT))
msi.MsiRecordGetStringW.argtypes = (w.UINT, w.UINT, w.LPWSTR, ctypes.POINTER(w.DWORD))
msi.MsiQueryProductStateW.argtypes = (w.LPCWSTR,)
msi.MsiCloseHandle.argtypes = (w.UINT,)
db, view, record = w.UINT(), w.UINT(), w.UINT()
def check(status):
    if status:
        raise OSError(f"MSI API status {status}")
try:
    check(msi.MsiOpenDatabaseW(str(args.msi.resolve(strict=True)), None, ctypes.byref(db)))
    check(msi.MsiDatabaseOpenViewW(db, "SELECT `Value` FROM `Property` WHERE `Property`='ProductCode'", ctypes.byref(view)))
    check(msi.MsiViewExecute(view, 0))
    check(msi.MsiViewFetch(view, ctypes.byref(record)))
    product = ctypes.create_unicode_buffer(39)
    size = w.DWORD(len(product))
    check(msi.MsiRecordGetStringW(record, 1, product, ctypes.byref(size)))
    assert msi.MsiQueryProductStateW(product.value) == 5, "Expected product is not installed"
finally:
    for handle in (record, view, db):
        if handle.value:
            msi.MsiCloseHandle(handle)
install = Path(os.environ["LOCALAPPDATA"], "Programs/Rymu")
runner = args.runner.resolve(strict=True)
files = [p for p in runner.rglob("*") if p.is_file() and p.suffix.lower() not in {".pdb", ".lib", ".exp"}]
for file in files:
    target = install / file.relative_to(runner)
    assert target.is_file(), str(file.relative_to(runner))
    assert hashlib.sha256(target.read_bytes()).digest() == hashlib.sha256(file.read_bytes()).digest(), str(file.relative_to(runner))
shortcut = Path(os.environ["APPDATA"], "Microsoft/Windows/Start Menu/Programs/Rymu/Rymu (Development).lnk")
assert shortcut.is_file(), "Start menu shortcut absent"
print(f"PASS expected MSI product installed; all {len(files)} installed files match runner; Start menu shortcut exists")
if args.preservation_record:
    vault = Path(os.environ["LOCALAPPDATA"], "Rymu/Control/account.dat")
    protected_hash = hashlib.sha256(vault.read_bytes()).hexdigest() if vault.exists() else None
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as key:
            value, kind = winreg.QueryValueEx(key, "RymuAutoHost")
            startup_hash = hashlib.sha256(f"{kind}:{value}".encode()).hexdigest()
    except FileNotFoundError:
        startup_hash = None
    state = {"protected_vault_hash": protected_hash, "startup_value_hash": startup_hash}
    assert state == json.loads(args.preservation_record.read_text(encoding="utf-8")), "Protected state differs from before-install fingerprint"
    print("PASS protected account vault and startup preference unchanged by this installation")
