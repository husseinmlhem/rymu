"""No-UI component probe of the actual installer helper under HKCU redirection."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid
import winreg

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("startup_qa", Path(__file__).with_name("windows-startup-probe.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


def owner_choice():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Rymu\Installer") as key:
            return winreg.QueryValueEx(key, "StartWithWindows")
    except FileNotFoundError:
        return None


def main():
    suffix = uuid.uuid4().hex
    owned = "Software\\RymuStartupProbe-" + suffix
    marker = uuid.uuid4().hex
    lane = ROOT / ".local" / ("rymu-installer-startup-" + suffix)
    profile = lane / "profile"
    executable = profile / "Programs/Rymu/Rymu.exe"
    executable.parent.mkdir(parents=True)
    log = ROOT / "artifacts/logs/windows-installer-startup-probe.log"
    record = log.with_suffix(".json")
    if log.exists() or record.exists():
        raise RuntimeError("Preserve prior probe evidence")
    vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
    installation = subprocess.check_output([str(vswhere), "-latest", "-products", "*",
        "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
        text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()
    setup = Path(installation) / "Common7/Tools/VsDevCmd.bat"
    environment = subprocess.check_output(
        f'cmd.exe /d /s /c ""{setup}" -arch=x64 -host_arch=x64 >nul && set"',
        text=True, creationflags=subprocess.CREATE_NO_WINDOW)
    env = {name.upper(): value for name, value in os.environ.items()}
    for line in environment.splitlines():
        if "=" in line and not line.startswith("="):
            name, value = line.split("=", 1)
            env[name.upper()] = value
    production = ROOT / "apps/native/flutter/windows/runner/rymu_installer_startup.cpp"
    before_run, before_choice = qa.owner_run_value(), owner_choice()
    evidence = {"scope": "Production C++ helper component; no installed app or GUI launch",
        "real_msi_finish_or_reboot": "not_run",
        "production_source_sha256": hashlib.sha256(production.read_bytes()).hexdigest(), "checks": {}}
    owns_key = False
    with log.open("w", encoding="utf-8") as output:
        compiler = Path(env["VCTOOLSINSTALLDIR"]) / "bin/Hostx64/x64/cl.exe"
        result = subprocess.run([str(compiler), "/nologo", "/std:c++17", "/EHsc", "/W4", "/WX",
            str(Path(__file__).with_suffix(".cpp")), str(production),
            "/Fe:" + str(executable), "/link", "advapi32.lib"], cwd=lane, env=env,
            stdout=output, stderr=subprocess.STDOUT, timeout=120,
            creationflags=subprocess.CREATE_NO_WINDOW)
        evidence["compile_exit_code"] = result.returncode
        if result.returncode:
            raise RuntimeError("Helper component compilation failed")
        try:
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owned):
                    raise RuntimeError("Existing sandbox key; refusing")
            except FileNotFoundError:
                pass
            with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, owned, 0, winreg.KEY_ALL_ACCESS) as key:
                owns_key = True
                winreg.SetValueEx(key, "RymuProbeMarker", 0, winreg.REG_SZ, marker)
            result = subprocess.run([str(executable), owned, marker], cwd=lane,
                env=dict(env, LOCALAPPDATA=str(profile), APPDATA=str(profile)),
                capture_output=True, text=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
            output.write(result.stdout + result.stderr)
            evidence["probe_exit_code"] = result.returncode
            if result.returncode:
                raise RuntimeError("Helper component probe failed")
            evidence["checks"].update(json.loads(result.stdout.strip()))
        finally:
            if owns_key:
                qa.remove_owned_subtree(owned, owned)
            evidence["checks"]["owner_run_and_pending_unchanged"] = (
                before_run == qa.owner_run_value() and before_choice == owner_choice())
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owned):
                    evidence["checks"]["owned_subtree_removed"] = False
            except FileNotFoundError:
                evidence["checks"]["owned_subtree_removed"] = True
            record.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if not all(evidence["checks"].values()):
        raise RuntimeError("Probe check failed")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
