"""Verify the attended MSI and optionally round-trip its per-user installation."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def sha256(file: Path) -> str:
    with file.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main() -> None:
    if sys.platform != "win32":
        raise SystemExit("Run the installer smoke on Windows.")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("msi", type=Path)
    parser.add_argument("runner", type=Path)
    parser.add_argument("--round-trip", action="store_true")
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    package = args.msi.resolve(strict=True)
    runner = args.runner.resolve(strict=True)
    msi = ctypes.WinDLL("msi.dll")
    uint = wintypes.UINT
    string = wintypes.LPCWSTR
    out_uint = ctypes.POINTER(uint)
    msi.MsiOpenDatabaseW.argtypes = (string, string, out_uint)
    msi.MsiDatabaseOpenViewW.argtypes = (uint, string, out_uint)
    msi.MsiViewExecute.argtypes = (uint, uint)
    msi.MsiViewFetch.argtypes = (uint, out_uint)
    msi.MsiRecordGetStringW.argtypes = (uint, uint, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
    msi.MsiRecordReadStream.argtypes = (uint, uint, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD))
    msi.MsiCloseHandle.argtypes = (uint,)
    msi.MsiQueryProductStateW.argtypes = (string,)
    msi.MsiEnumRelatedProductsW.argtypes = (string, wintypes.DWORD, wintypes.DWORD, wintypes.LPWSTR)

    def check(status: int) -> None:
        if status:
            raise OSError(f"Windows Installer API returned {status}")

    database = uint()
    check(msi.MsiOpenDatabaseW(str(package), None, ctypes.byref(database)))

    def query(sql: str, fields: int) -> list[list[str]]:
        view = uint()
        check(msi.MsiDatabaseOpenViewW(database, sql, ctypes.byref(view)))
        try:
            check(msi.MsiViewExecute(view, 0))
            rows = []
            while True:
                record = uint()
                status = msi.MsiViewFetch(view, ctypes.byref(record))
                if status == 259:
                    return rows
                check(status)
                try:
                    values = []
                    for index in range(1, fields + 1):
                        value = ctypes.create_unicode_buffer(512)
                        size = wintypes.DWORD(len(value))
                        check(msi.MsiRecordGetStringW(record, index, value, ctypes.byref(size)))
                        values.append(value.value)
                    rows.append(values)
                finally:
                    msi.MsiCloseHandle(record)
        finally:
            msi.MsiCloseHandle(view)

    def read_cabinet(name: str, destination: Path) -> None:
        if not name or any(not (part.isalnum() or part in "-_.") for part in name):
            raise ValueError("Invalid MSI cabinet stream name")
        view, record = uint(), uint()
        check(msi.MsiDatabaseOpenViewW(database, f"SELECT `Data` FROM `_Streams` WHERE `Name`='{name}'",
                                        ctypes.byref(view)))
        try:
            check(msi.MsiViewExecute(view, 0))
            check(msi.MsiViewFetch(view, ctypes.byref(record)))
            with destination.open("xb") as output:
                buffer = ctypes.create_string_buffer(65_536)
                while True:
                    size = wintypes.DWORD(len(buffer))
                    check(msi.MsiRecordReadStream(record, 1, buffer, ctypes.byref(size)))
                    if not size.value:
                        break
                    output.write(buffer.raw[:size.value])
        finally:
            if record.value:
                msi.MsiCloseHandle(record)
            msi.MsiCloseHandle(view)

    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    files = [file for file in runner.rglob("*") if file.is_file()
             and file.suffix.lower() not in {".pdb", ".exp", ".lib"}]

    try:
        tables = {row[0] for row in query("SELECT `Name` FROM `_Tables`", 1)}
        properties = dict(query("SELECT `Property`, `Value` FROM `Property`", 2))
        assert properties["ProductName"] in {"Rymu", "Rymu (Development)"}
        product_name = properties["ProductName"]
        if product_name == "Rymu":
            assert properties["Manufacturer"] == "Hussein Mlhem"
        assert not properties.get("ALLUSERS")
        assert not tables & {"ServiceInstall", "ServiceControl"}
        if "CustomAction" in tables:
            # The optional completion choices may only invoke our installed
            # executable. No script, shell, elevated or execute-sequence action.
            actions = query("SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`", 4)
            assert sorted(actions) == sorted([
                ["RymuApplyStartup", "18", "RymuExe", "--rymu-installer-startup [RYMU_STARTUP_ARG]"],
                ["RymuLaunchNow", "210", "RymuExe", ""],
            ]), actions
            for sequence in ("InstallExecuteSequence", "InstallUISequence"):
                if sequence in tables:
                    assert not {row[0] for row in query(f"SELECT `Action` FROM `{sequence}`", 1)} & {
                        "RymuApplyStartup", "RymuLaunchNow"}
        assert "RemoveFile" in tables
        assert "File" in tables and "Media" in tables
        assert query("SELECT `File` FROM `File` WHERE `File`='RymuExe'", 1) == [["RymuExe"]]
        product_code = properties["ProductCode"]
        upgrade_code = properties["UpgradeCode"]
        file_count = len(query("SELECT `File` FROM `File`", 1))
        assert len(files) == file_count
        print(f"PASS per-user Rymu package with {file_count} files, no services and only reviewed optional finish actions", flush=True)
        if not args.round_trip:
            cabinets = query("SELECT `Cabinet` FROM `Media`", 1)
            assert len(cabinets) == 1 and cabinets[0][0].startswith("#")
            with tempfile.TemporaryDirectory(prefix="payload-", dir=logs) as folder:
                scratch = Path(folder)
                cabinet = scratch / "payload.cab"
                extracted = scratch / "files"
                extracted.mkdir()
                read_cabinet(cabinets[0][0][1:], cabinet)
                expand = Path(os.environ["SystemRoot"], "System32", "expand.exe")
                subprocess.run([str(expand), "-F:*", str(cabinet), str(extracted)], check=True,
                               stdout=subprocess.DEVNULL, timeout=30)
                seen = {file.name.casefold(): file for file in extracted.iterdir() if file.is_file()}
                assert len(seen) == file_count
                for file in files:
                    relative = file.relative_to(runner).as_posix()
                    key = ("RymuExe" if relative == "Rymu.exe" else
                           "F" + hashlib.sha256(relative.casefold().encode()).hexdigest()[:22])
                    assert sha256(seen[key.casefold()]) == sha256(file), relative
                print(f"PASS every one of {file_count} extracted MSI cabinet files matches the compiled runner", flush=True)
    finally:
        msi.MsiCloseHandle(database)

    if not args.round_trip:
        return
    install = Path(os.environ["LOCALAPPDATA"], "Programs", "Rymu")
    menu = Path(os.environ["APPDATA"], "Microsoft/Windows/Start Menu/Programs/Rymu")
    shortcut = menu / f"{product_name}.lnk"
    if (install.exists() or any((menu / f"{name}.lnk").exists() for name in ("Rymu", "Rymu (Development)")) or
        msi.MsiEnumRelatedProductsW(upgrade_code, 0, 0, ctypes.create_unicode_buffer(39)) != 259):
        raise SystemExit("An existing Rymu installation or shortcut was found. Leave it intact.")
    installer = Path(os.environ["SystemRoot"], "System32", "msiexec.exe")

    def run(verb: str, target: str, action: str) -> None:
        log = logs / f"{action}.log"
        command = [str(installer), verb, target, "/qn", "/norestart", "/L*V", str(log),
                   f"ROOTDRIVE={install.anchor}"]
        try:
            result = subprocess.run(command, check=False, timeout=75)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"msiexec {verb} did not return in 75 seconds. See {log}.")
        print(f"msiexec {verb} exit_code={result.returncode}", flush=True)
        check(result.returncode)

    try:
        run("/i", str(package), "install")
        assert msi.MsiQueryProductStateW(product_code) == 5
        for file in files:
            installed = install / file.relative_to(runner)
            assert sha256(installed) == sha256(file), installed.name
        assert shortcut.is_file()
        guard = subprocess.run([str(install / "Rymu.exe"), "--service-control"], cwd=install,
                               check=False, timeout=10)
        assert guard.returncode == 5
        print(f"PASS installed hashes match all {file_count} build files, shortcut and guarded executable run", flush=True)
    finally:
        if msi.MsiQueryProductStateW(product_code) in {1, 5}:
            run("/x", product_code, "uninstall")
    assert msi.MsiQueryProductStateW(product_code) != 5
    assert not install.exists() and not shortcut.exists()
    print("PASS registered test product, installed files and shortcut were removed", flush=True)


if __name__ == "__main__":
    main()
