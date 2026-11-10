"""Exercise an exact Windows runner's tray on the current desktop, in a test profile.

Only the process launched here receives window messages. The owner app must be
closed before this test. No reboot, Explorer restart, login, or peer is implied.
"""
from __future__ import annotations

import argparse
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import winreg


class Guid(c.Structure):
    _fields_ = [("data1", w.DWORD), ("data2", w.WORD), ("data3", w.WORD),
                ("data4", w.BYTE * 8)]


class IconIdentifier(c.Structure):
    _fields_ = [("cbSize", w.DWORD), ("hWnd", w.HWND), ("uID", w.UINT),
                ("guidItem", Guid)]


class NotifyIcon(c.Structure):
    _fields_ = [("cbSize", w.DWORD), ("hWnd", w.HWND), ("uID", w.UINT),
                ("uFlags", w.UINT), ("uCallbackMessage", w.UINT),
                ("hIcon", w.HICON), ("szTip", w.WCHAR * 128),
                ("dwState", w.DWORD), ("dwStateMask", w.DWORD),
                ("szInfo", w.WCHAR * 256), ("uTimeoutOrVersion", w.UINT),
                ("szInfoTitle", w.WCHAR * 64), ("dwInfoFlags", w.DWORD),
                ("guidItem", Guid), ("hBalloonIcon", w.HICON)]


class GuiThreadInfo(c.Structure):
    _fields_ = [("cbSize", w.DWORD), ("flags", w.DWORD)] + [
        (name, w.HWND) for name in ("active", "focus", "capture", "menuOwner",
                                    "moveSize", "caret")
    ] + [("caretRect", w.RECT)]


user = c.WinDLL("user32", use_last_error=True)
shell = c.WinDLL("shell32", use_last_error=True)
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
user.EnumWindows.argtypes = (callback, w.LPARAM)
user.GetWindowThreadProcessId.argtypes = (w.HWND, c.POINTER(w.DWORD))
user.GetWindowThreadProcessId.restype = w.DWORD
user.GetWindowTextW.argtypes = (w.HWND, w.LPWSTR, c.c_int)
user.GetClassNameW.argtypes = (w.HWND, w.LPWSTR, c.c_int)
user.IsWindowVisible.argtypes = (w.HWND,)
user.PostMessageW.argtypes = (w.HWND, w.UINT, w.WPARAM, w.LPARAM)
user.RegisterWindowMessageW.argtypes = (w.LPCWSTR,)
user.RegisterWindowMessageW.restype = w.UINT
user.GetGUIThreadInfo.argtypes = (w.DWORD, c.POINTER(GuiThreadInfo))
shell.Shell_NotifyIconGetRect.argtypes = (c.POINTER(IconIdentifier), c.POINTER(w.RECT))
shell.Shell_NotifyIconGetRect.restype = c.c_long
shell.Shell_NotifyIconW.argtypes = (w.DWORD, c.POINTER(NotifyIcon))
shell.Shell_NotifyIconW.restype = w.BOOL

CALLBACK = 0x8052
ICON_ID = 1
OPEN = 0x7351
QUIT = 0x7352
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE = "RymuAutoHost"


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def startup_value():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            return winreg.QueryValueEx(key, RUN_VALUE)
    except FileNotFoundError:
        return None


def windows(pid=None):
    found = []

    @callback
    def collect(hwnd, _):
        owner = w.DWORD()
        thread = user.GetWindowThreadProcessId(hwnd, c.byref(owner))
        title, name = c.create_unicode_buffer(256), c.create_unicode_buffer(256)
        user.GetWindowTextW(hwnd, title, len(title))
        user.GetClassNameW(hwnd, name, len(name))
        if (pid is None or owner.value == pid) and (
            name.value == "FLUTTER_RUNNER_WIN32_WINDOW"
            and title.value.startswith("Rymu")
        ):
            found.append((hwnd, thread, title.value))
        return True

    if not user.EnumWindows(collect, 0):
        raise c.WinError(c.get_last_error())
    return found


def icon_rect(hwnd):
    identifier = IconIdentifier(cbSize=c.sizeof(IconIdentifier), hWnd=hwnd, uID=ICON_ID)
    rect = w.RECT()
    result = shell.Shell_NotifyIconGetRect(c.byref(identifier), c.byref(rect))
    if result < 0:
        return None
    return [rect.left, rect.top, rect.right, rect.bottom]


def post(hwnd, message, wp=0, lp=0):
    if not user.PostMessageW(hwnd, message, wp, lp):
        raise c.WinError(c.get_last_error())


def wait_for(label, predicate, process=None, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if process is not None and process.poll() is not None:
            raise AssertionError(f"Process exited {process.returncode} while waiting for {label}")
        result = predicate()
        if result:
            return result
        time.sleep(0.08)
    raise AssertionError(f"Timed out waiting for {label}")


def fixture_vault(exe, profile, operation):
    # The subprocess loads only the supplied DLL and a scratch profile. It never
    # reads or prints owner tokens. The sentinel is not a sign-in credential.
    snippet = """
import ctypes as c, json, os, sys
from pathlib import Path
dll, operation = Path(sys.argv[1]), sys.argv[2]
with os.add_dll_directory(str(dll.parent)):
    engine = c.WinDLL(str(dll))
    call = engine.rymu_control
    call.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]
    call.restype = c.c_ssize_t
    fixture = {'qaSentinel': 'non-secret tray persistence fixture', 'settings': {'api': 'https://rymu.iptvora-server.workers.dev/api/v1', 'locale': 'en'}}
    value = {'op': 'vaultWrite', 'data': fixture} if operation == 'write' else {'op': 'vaultRead'}
    raw = json.dumps(value).encode()
    data, out = c.create_string_buffer(raw), c.create_string_buffer(65536)
    count = call(data, len(raw), out, len(out))
    assert 0 < count <= len(out)
    result = json.loads(out.raw[:count])
    assert result.get('value') == (True if operation == 'write' else fixture), 'Fixture vault mismatch'
    path = Path(os.environ['LOCALAPPDATA'], 'Rymu', 'Control', 'account.dat')
    assert fixture['qaSentinel'].encode() not in path.read_bytes()
print('PASS scratch DPAPI fixture ' + operation)
"""
    env = dict(os.environ, LOCALAPPDATA=str(profile), APPDATA=str(profile / "Roaming"))
    result = subprocess.run([sys.executable, "-c", snippet, str(exe.parent / "librustdesk.dll"),
                             operation], env=env, text=True, capture_output=True, timeout=25)
    if result.returncode:
        raise AssertionError(f"Isolated vault {operation} failed: {result.stderr[-1500:]}")


def helper_guards(args):
    """Only rejected helper calls: no normal app launch or registry writes."""
    exe = args.exe.resolve(strict=True)
    installed = Path(os.environ["LOCALAPPDATA"], "Programs", "Rymu", "Rymu.exe").resolve()
    if exe == installed:
        raise RuntimeError("Guard probe requires the portable build path, never the owner's installed executable")

    def snapshot():
        values = []
        for key_name, value_name in [(RUN_KEY, RUN_VALUE),
                                      (r"Software\Rymu\Installer", "StartWithWindows")]:
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_name) as key:
                    values.append(winreg.QueryValueEx(key, value_name))
            except FileNotFoundError:
                values.append(None)
        return values

    before = snapshot()
    report = {"startedAt": datetime.now(timezone.utc).isoformat(),
              "runner": str(exe), "sha256": sha256(exe),
              "scope": "Exact EXE argument/path rejection only; no GUI or successful startup mutation",
              "registryFingerprintBefore": hashlib.sha256(repr(before).encode()).hexdigest(),
              "checks": [], "status": "failed"}
    cases = [(["--rymu-installer-startup"], 87),
             (["--rymu-installer-startup", "invalid"], 87),
             (["--rymu-installer-startup", "on", "extra"], 87),
             (["on", "--rymu-installer-startup"], 87),
             (["--rymu-installer-startup", "on"], 5),
             (["--rymu-installer-startup", "off"], 5),
             (["--service-control"], 5)]
    try:
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        for arguments, expected in cases:
            start = time.monotonic()
            process = subprocess.Popen([str(exe), *arguments], cwd=exe.parent,
                                       startupinfo=startup, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            try:
                until = start + 5
                while process.poll() is None and time.monotonic() < until:
                    assert not windows(process.pid), "Rejected helper opened a Rymu window"
                    time.sleep(0.01)
                assert process.poll() is not None, "Rejected helper did not exit promptly"
                assert process.returncode == expected, (arguments, process.returncode, expected)
                assert snapshot() == before, "Rejected helper changed owner startup registry values"
                report["checks"].append({"arguments": arguments, "exitCode": process.returncode,
                                         "seconds": round(time.monotonic() - start, 3), "status": "passed"})
                print(f"PASS {' '.join(arguments)} returns {expected}; registry unchanged", flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        report["status"] = "passed"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report["registryFingerprintAfter"] = hashlib.sha256(repr(snapshot()).encode()).hexdigest()
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def run(args):
    exe = args.exe.resolve(strict=True)
    if exe.name != "Rymu.exe":
        raise ValueError("Pass the final bundle's Rymu.exe")
    if windows():
        raise RuntimeError("An existing Rymu window is open; no owner process will be touched")
    before_startup = startup_value()
    report = {
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "runner": str(exe),
        "hashes": {str(p.relative_to(exe.parent)): sha256(p) for p in [
            exe, exe.parent / "librustdesk.dll", exe.parent / "data/app.so"]},
        "scope": "Exact release executable/DLL/AOT, signed-out isolated profile; native message dispatch",
        "notRun": ["real Windows reboot/logon", "physical mouse tray interaction",
                   "actual Explorer restart", "real account sign-in or remote peer session"],
        "checks": [],
    }

    def passed(name, **evidence):
        report["checks"].append({"name": name, "status": "passed", **evidence})
        print("PASS " + name, flush=True)

    scratch = Path(tempfile.mkdtemp(prefix="rymu-tray-qa-"))
    profile = scratch / "profile"
    profile.mkdir()
    (profile / "Roaming").mkdir()
    (profile / "temp").mkdir()
    process = None
    hwnd = None
    try:
        fixture_vault(exe, profile, "write")
        env = dict(os.environ, LOCALAPPDATA=str(profile), APPDATA=str(profile / "Roaming"),
                   TEMP=str(profile / "temp"), TMP=str(profile / "temp"))
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        # This is the interactive app under test, not a background build helper.
        # SW_HIDE would override the runner's first ShowWindow, including the
        # singleton shortcut process's attempt to restore the existing window.
        startup.wShowWindow = 1
        with (scratch / "runner.log").open("w", encoding="utf-8") as log:
            process = subprocess.Popen([str(exe)], cwd=exe.parent, env=env, startupinfo=startup,
                                       stdout=log, stderr=subprocess.STDOUT)
            found = wait_for("runner window", lambda: windows(process.pid), process, 40)
            hwnd, thread, _ = found[0]
            rect = wait_for("registered tray icon", lambda: icon_rect(hwnd), process, 30)
            passed("shell registered the process notification icon", rect=rect)
            wait_for("visible main window", lambda: user.IsWindowVisible(hwnd), process)

            post(hwnd, 0x0112, 0xF060)  # WM_SYSCOMMAND / SC_CLOSE: same close route as X.
            wait_for("hidden main window", lambda: not user.IsWindowVisible(hwnd), process)
            time.sleep(1)
            assert process.poll() is None and icon_rect(hwnd) is not None
            passed("system close hides main window while process and icon stay alive")

            post(hwnd, CALLBACK, 0, (ICON_ID << 16) | 0x0400)  # NIN_SELECT v4.
            wait_for("tray callback reopen", lambda: user.IsWindowVisible(hwnd), process)
            passed("notification icon selection restores the main window")

            post(hwnd, 0x0112, 0xF060)
            wait_for("second close hides", lambda: not user.IsWindowVisible(hwnd), process)
            post(hwnd, 0x0111, OPEN)  # Native menu WM_COMMAND.
            wait_for("Open command restores", lambda: user.IsWindowVisible(hwnd), process)
            passed("native Open menu command restores the window")

            post(hwnd, 0x0112, 0xF060)
            wait_for("hidden before shortcut reopen", lambda: not user.IsWindowVisible(hwnd), process)
            reopened = subprocess.run([str(exe)], cwd=exe.parent, env=env,
                                      startupinfo=startup, stdout=log,
                                      stderr=subprocess.STDOUT, timeout=25)
            assert reopened.returncode in (0, 1), "Shortcut launch failed unexpectedly"
            wait_for("shortcut restores original window", lambda: user.IsWindowVisible(hwnd), process)
            assert len(windows(process.pid)) == 1 and icon_rect(hwnd) is not None
            passed("second launch restores the existing process instead of a duplicate window",
                   secondLaunchExitCode=reopened.returncode)

            # TrackPopupMenu enters this process's menu mode. Escape targets only
            # that window; it does not inject keyboard input into another app.
            post(hwnd, 0x0112, 0xF060)
            wait_for("hidden before context menu", lambda: not user.IsWindowVisible(hwnd), process)
            post(hwnd, CALLBACK, 0, (ICON_ID << 16) | 0x007B)

            def menu_open():
                info = GuiThreadInfo(cbSize=c.sizeof(GuiThreadInfo))
                return user.GetGUIThreadInfo(thread, c.byref(info)) and bool(info.flags & 4)

            wait_for("native tray menu", menu_open, process)
            post(hwnd, 0x001F)  # WM_CANCELMODE closes only this process's menu.
            wait_for("native menu dismissed", lambda: not menu_open(), process)
            passed("tray context callback opens and dismisses a real native menu while main window is hidden")

            post(hwnd, 0x0112, 0xF060)
            wait_for("hidden before icon recovery", lambda: not user.IsWindowVisible(hwnd), process)
            icon = NotifyIcon(cbSize=c.sizeof(NotifyIcon), hWnd=hwnd, uID=ICON_ID)
            assert shell.Shell_NotifyIconW(2, c.byref(icon)), "Could not remove test-owned icon"
            wait_for("test icon removed", lambda: icon_rect(hwnd) is None, process)
            message = user.RegisterWindowMessageW("TaskbarCreated")
            assert message
            post(hwnd, message)
            wait_for("icon restored by recovery handler", lambda: icon_rect(hwnd), process)
            passed("TaskbarCreated handler restores removed test-owned icon", actualExplorerRestart=False)

            start = time.monotonic()
            post(hwnd, 0x0111, QUIT)
            assert process.wait(timeout=15) == 0
            wait_for("icon removed after Quit", lambda: icon_rect(hwnd) is None)
            passed("Quit command exits cleanly and removes notification icon",
                   seconds=round(time.monotonic() - start, 3), exitCode=process.returncode)
            fixture_vault(exe, profile, "read")
            passed("encrypted scratch vault survives normal application exit")

            process = subprocess.Popen([str(exe)], cwd=exe.parent, env=env, startupinfo=startup,
                                       stdout=log, stderr=subprocess.STDOUT)
            found = wait_for("restarted runner window", lambda: windows(process.pid), process, 40)
            hwnd, _, _ = found[0]
            wait_for("restarted runner icon", lambda: icon_rect(hwnd), process, 30)
            post(hwnd, 0x0111, QUIT)
            assert process.wait(timeout=15) == 0
            fixture_vault(exe, profile, "read")
            passed("encrypted scratch vault survives a full application restart",
                   realAccount=False, realWindowsReboot=False)
        assert startup_value() == before_startup, "Signed-out fixture changed owner startup setting"
        passed("owner startup registry value remains unchanged")
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        if process is not None and process.poll() is None:
            if hwnd:
                post(hwnd, 0x0111, QUIT)
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.terminate()  # Only the PID spawned by this script.
                process.wait(timeout=5)
        current = startup_value()
        if current != before_startup:
            report["startupChangedUnexpectedly"] = True
            # Do not overwrite a concurrent owner action. Restore only a value
            # that explicitly points inside this script's scratch directory.
            if current and str(scratch).lower() in str(current[0]).lower():
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
                    if before_startup is None:
                        winreg.DeleteValue(key, RUN_VALUE)
                    else:
                        winreg.SetValueEx(key, RUN_VALUE, 0, before_startup[1], before_startup[0])
                report["startupRestored"] = True
        # Keep scratch diagnostics on failure; successful cleanup is restricted
        # to a freshly created, verified test directory.
        if report.get("status") == "passed":
            resolved = scratch.resolve()
            assert resolved.parent == Path(tempfile.gettempdir()).resolve()
            assert resolved.name.startswith("rymu-tray-qa-")
            for attempt in range(8):
                try:
                    shutil.rmtree(resolved)
                    report["scratchCleanup"] = "removed"
                    break
                except PermissionError:
                    time.sleep(0.25)
            else:
                # A scanner or inherited console handle may briefly retain a
                # log. Keep the non-secret fixture rather than killing another
                # process or misreporting successful product checks as failed.
                report["scratchCleanup"] = "retained_locked_file"
                report["scratchDirectory"] = str(resolved)
        else:
            print(f"Fixture diagnostics retained: {scratch}", flush=True)
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"Evidence: {args.output}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper-guards-only", action="store_true",
                        help="No GUI: exercise only rejected helper/service calls from a portable path")
    parsed = parser.parse_args()
    (helper_guards if parsed.helper_guards_only else run)(parsed)
