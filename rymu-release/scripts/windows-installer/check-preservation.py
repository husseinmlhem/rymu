"""Guard an exact installer round-trip and compare protected state without decrypting it."""
import argparse
import ctypes
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import winreg

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument("stage", choices=("before", "after"))
cli.add_argument("record", type=Path)
args = cli.parse_args()
msi = ctypes.WinDLL("msi.dll")
msi.MsiEnumRelatedProductsW.argtypes = (w.LPCWSTR, w.DWORD, w.DWORD, w.LPWSTR)
code = ctypes.create_unicode_buffer(39)
status = msi.MsiEnumRelatedProductsW("{E20D6245-06D5-4909-9A0E-055DBDF88DF5}", 0, 0, code)
assert status == 259, f"A related Rymu installation exists (status={status}); stop without changing it"
install = Path(os.environ["LOCALAPPDATA"], "Programs", "Rymu")
shortcut = Path(os.environ["APPDATA"], "Microsoft/Windows/Start Menu/Programs/Rymu/Rymu (Development).lnk")
assert not install.exists() and not shortcut.exists(), "Existing Rymu files or shortcut found; stop"
vault = Path(os.environ["LOCALAPPDATA"], "Rymu/Control/account.dat")
protected_hash = hashlib.sha256(vault.read_bytes()).hexdigest() if vault.exists() else None
try:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as key:
        value, kind = winreg.QueryValueEx(key, "RymuAutoHost")
        startup_hash = hashlib.sha256(f"{kind}:{value}".encode()).hexdigest()
except FileNotFoundError:
    startup_hash = None
state = {"protected_vault_hash": protected_hash, "startup_value_hash": startup_hash}
if args.stage == "before":
    if args.record.exists():
        raise SystemExit("Preservation record exists; retain it, choose a new file")
    args.record.parent.mkdir(parents=True, exist_ok=True)
    args.record.write_text(json.dumps(state), encoding="utf-8")
    print("PASS no existing Rymu install, shortcut or related product; protected-state fingerprint recorded")
else:
    assert state == json.loads(args.record.read_text(encoding="utf-8")), "Protected user state changed"
    print("PASS no Rymu installation present; encrypted account and startup preference unchanged")
