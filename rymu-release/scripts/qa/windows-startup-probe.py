"""Compile and run the production startup setter in a disposable HKCU subtree."""
from __future__ import annotations

import hashlib
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import uuid
import winreg


ROOT = Path(__file__).resolve().parents[2]
RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"


def owner_run_value():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN) as key:
            return winreg.QueryValueEx(key, "RymuAutoHost")
    except FileNotFoundError:
        return None


def remove_owned_subtree(path: str, owned: str):
    if path != owned and not path.startswith(owned + "\\"):
        raise RuntimeError("Refusing registry cleanup outside owned probe key")
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0,
                            winreg.KEY_READ | winreg.KEY_WRITE) as key:
            children = [winreg.EnumKey(key, i)
                        for i in range(winreg.QueryInfoKey(key)[0])]
        for child in children:
            remove_owned_subtree(path + "\\" + child, owned)
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)
    except FileNotFoundError:
        pass


def main():
    if sys.platform != "win32":
        raise RuntimeError("This probe requires Windows")
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="windows-tray-startup-probe")
    options = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", options.label):
        raise RuntimeError("Invalid evidence label")
    run_id = uuid.uuid4().hex
    sandbox_key = "Software\\RymuStartupProbe-" + run_id
    marker = uuid.uuid4().hex
    lane = ROOT / ".local" / ("rymu-startup-probe-" + run_id)
    if not lane.resolve().is_relative_to((ROOT / ".local").resolve()):
        raise RuntimeError("Invalid scratch directory")
    profile = lane / "profile"
    executable = profile / "Programs" / "Rymu" / "Rymu.exe"
    executable.parent.mkdir(parents=True)
    log = ROOT / "artifacts/logs" / (options.label + ".log")
    record = log.with_suffix(".json")
    if log.exists() or record.exists():
        raise RuntimeError("Preserve prior probe evidence before rerunning")
    sdk = ROOT / ".local/flutter-sdk/flutter"
    dart = sdk / "bin/cache/dart-sdk/bin/dart.exe"
    packages = ROOT / "apps/native/flutter/.dart_tool/package_config.json"
    source = Path(__file__).with_suffix(".dart")
    production = ROOT / "apps/native/flutter/lib/rymu/windows_logon_start.dart"
    before = owner_run_value()
    evidence = {
        "scope": "Actual production Win32 Run registration and removal under process-local HKCU redirection",
        "windows_logon_or_reboot": "not_run",
        "production_source_sha256": hashlib.sha256(production.read_bytes()).hexdigest(),
        "probe_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "harness_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "checks": {},
    }
    with log.open("w", encoding="utf-8") as output:
        build = subprocess.run([str(dart), "compile", "exe", "--packages=" + str(packages),
                                str(source), "--output=" + str(executable)],
                               cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                               timeout=240, creationflags=subprocess.CREATE_NO_WINDOW)
        evidence["compile_exit_code"] = build.returncode
        if build.returncode:
            raise RuntimeError("Probe compilation failed; see saved log")
        owns_key = False
        try:
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sandbox_key):
                    raise RuntimeError("Refusing an existing probe key")
            except FileNotFoundError:
                pass
            with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, sandbox_key, 0,
                                    winreg.KEY_ALL_ACCESS) as key:
                owns_key = True
                winreg.SetValueEx(key, "RymuProbeMarker", 0, winreg.REG_SZ, marker)
            env = dict(os.environ, LOCALAPPDATA=str(profile), APPDATA=str(profile),
                       DART_SUPPRESS_ANALYTICS="true")
            probe = subprocess.run([str(executable), sandbox_key, marker],
                                   cwd=lane, env=env, capture_output=True, text=True,
                                   timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
            output.write(probe.stdout)
            output.write(probe.stderr)
            evidence["probe_exit_code"] = probe.returncode
            if probe.returncode:
                raise RuntimeError("Sandbox probe failed; see saved log")
            evidence["checks"].update(json.loads(probe.stdout.strip()))
        finally:
            if owns_key:
                remove_owned_subtree(sandbox_key, sandbox_key)
            evidence["checks"]["owner_run_value_unchanged"] = owner_run_value() == before
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sandbox_key):
                    evidence["checks"]["owned_registry_subtree_removed"] = False
            except FileNotFoundError:
                evidence["checks"]["owned_registry_subtree_removed"] = True
            record.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if not all(evidence["checks"].values()):
        raise RuntimeError("A startup probe check failed")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
