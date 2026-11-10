"""Read-only MSI UI and safety checks. Does not install, repair or remove an app."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes as w
from pathlib import Path


def main() -> None:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("msi", type=Path)
    args = cli.parse_args()
    msi = ctypes.WinDLL("msi.dll")
    msi.MsiOpenDatabaseW.argtypes = (w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(w.UINT))
    msi.MsiDatabaseOpenViewW.argtypes = (w.UINT, w.LPCWSTR, ctypes.POINTER(w.UINT))
    msi.MsiViewExecute.argtypes = (w.UINT, w.UINT)
    msi.MsiViewFetch.argtypes = (w.UINT, ctypes.POINTER(w.UINT))
    msi.MsiRecordGetStringW.argtypes = (w.UINT, w.UINT, w.LPWSTR, ctypes.POINTER(w.DWORD))
    msi.MsiCloseHandle.argtypes = (w.UINT,)

    def check(status: int) -> None:
        if status:
            raise OSError(f"MSI API status {status}")

    db = w.UINT()
    check(msi.MsiOpenDatabaseW(str(args.msi.resolve(strict=True)), None, ctypes.byref(db)))

    def query(sql: str, columns: int) -> list[list[str]]:
        view = w.UINT()
        check(msi.MsiDatabaseOpenViewW(db, sql, ctypes.byref(view)))
        try:
            check(msi.MsiViewExecute(view, 0))
            rows = []
            while True:
                record = w.UINT()
                status = msi.MsiViewFetch(view, ctypes.byref(record))
                if status == 259:
                    return rows
                check(status)
                try:
                    row = []
                    for column in range(1, columns + 1):
                        buffer = ctypes.create_unicode_buffer(4096)
                        size = w.DWORD(len(buffer))
                        check(msi.MsiRecordGetStringW(record, column, buffer, ctypes.byref(size)))
                        row.append(buffer.value)
                    rows.append(row)
                finally:
                    msi.MsiCloseHandle(record)
        finally:
            msi.MsiCloseHandle(view)

    try:
        tables = {r[0] for r in query("SELECT `Name` FROM `_Tables`", 1)}
        assert not tables & {"ServiceInstall", "ServiceControl"}
        actions = query("SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`", 4)
        assert sorted(actions) == sorted([
            ["RymuApplyStartup", "18", "RymuExe", "--rymu-installer-startup [RYMU_STARTUP_ARG]"],
            ["RymuLaunchNow", "210", "RymuExe", ""],
        ])
        for table in ("InstallExecuteSequence", "InstallUISequence", "AdminExecuteSequence", "AdminUISequence"):
            if table in tables:
                assert not {r[0] for r in query(f"SELECT `Action` FROM `{table}`",1)} & {"RymuApplyStartup","RymuLaunchNow"}
        properties = dict(query("SELECT `Property`, `Value` FROM `Property`", 2))
        assert properties["UpgradeCode"].lower() == "{e20d6245-06d5-4909-9a0e-055dbdf88df5}"
        assert not properties.get("ALLUSERS")
        assert properties["ARPPRODUCTICON"] == "RymuAppIcon"
        registry = query("SELECT `Key`, `Name` FROM `Registry`", 2)
        assert all(not key.casefold().endswith("currentversion\\run") for key, _ in registry)
        if "RemoveRegistry" in tables:
            removals = query("SELECT `Key`, `Name` FROM `RemoveRegistry`", 2)
            assert all(not key.casefold().endswith("currentversion\\run") for key, _ in removals)
        assert all("vault" not in str(row).lower() for row in query("SELECT `FileName` FROM `RemoveFile`", 1))
        print("PASS identity retained; exactly two installed-file Finish actions; no scheduled actions, service, registry override or vault deletion")

        dialogs = {row[0] for row in query("SELECT `Dialog` FROM `Dialog`", 1)}
        expected = {"RymuWelcomeDlg", "RymuRemoveDlg", "RymuConfirmRemoveDlg", "RymuProgressDlg", "RymuExitDlg"}
        assert expected <= dialogs
        events = query("SELECT `Dialog_`, `Control_`, `Event`, `Argument` FROM `ControlEvent`", 4)
        remove = [row for row in events if row[2] == "Remove"]
        assert remove == [["RymuConfirmRemoveDlg", "Remove", "Remove", "ALL"]]
        assert ["RymuConfirmRemoveDlg", "Remove", "[REMOVE]", "ALL"] in events
        assert ["RymuRemoveDlg", "Remove", "NewDialog", "RymuConfirmRemoveDlg"] in events
        assert ["RymuConfirmRemoveDlg", "Back", "NewDialog", "RymuRemoveDlg"] in events
        assert ["RymuRemoveDlg", "Keep", "EndDialog", "Exit"] in events
        assert ["RymuWelcomeDlg", "Cancel", "SpawnDialog", "CancelDlg"] in events
        assert ["RymuProgressDlg", "Cancel", "SpawnDialog", "CancelDlg"] in events
        sequence = query("SELECT `Action`, `Condition`, `Sequence` FROM `InstallUISequence`", 3)
        ordered = {action: int(number) for action, _, number in sequence}
        assert ordered["CostFinalize"] < ordered["RymuRemoveDlg"] < ordered["RymuWelcomeDlg"]
        assert ordered["RymuWelcomeDlg"] < ordered["RymuProgressDlg"] < ordered["ExecuteAction"]
        assert ordered["RymuExitDlg"] == -1
        assert "NOT REINSTALL" in next(condition for action, condition, _ in sequence if action == "RymuRemoveDlg")
        assert "ProgressDlg" not in ordered, "An unbranded stock progress dialog is also sequenced"
        assert {"ErrorDlg", "FilesInUse", "MsiRMFilesInUse", "FatalError", "UserExit", "CancelDlg"} <= dialogs
        finish_events=query("SELECT `Control_`, `Event`, `Argument`, `Condition`, `Ordering` FROM `ControlEvent` WHERE `Dialog_`='RymuExitDlg'",5)
        ordered_finish=sorted([r for r in finish_events if r[0]=="Finish"],key=lambda r:int(r[4]))
        assert [(r[1],r[2],r[4]) for r in ordered_finish] == [
            ("[RYMU_STARTUP_ARG]","on","1"), ("[RYMU_STARTUP_ARG]","off","2"),
            ("DoAction","RymuApplyStartup","3"), ("DoAction","RymuLaunchNow","4"), ("EndDialog","Return","5")]
        for row in ordered_finish[:4]:
            for guard in ('UILevel >= 5','NOT Installed','NOT REMOVE','NOT REINSTALL','NOT PATCH','ACTION <> "ADMIN"'):
                assert guard in row[3]
        assert all(row[1]!="DoAction" for row in finish_events if row[0]=="Close")
        exit_dialog=query("SELECT `Control_Default`, `Control_Cancel` FROM `Dialog` WHERE `Dialog`='RymuExitDlg'",2)
        assert exit_dialog==[["Finish","Close"]]
        assert properties["RYMU_LAUNCH_NOW"]==properties["RYMU_START_WINDOWS"]=="1"
        checks=query("SELECT `Control`, `Property` FROM `Control` WHERE `Dialog_`='RymuExitDlg' AND `Type`='CheckBox'",2)
        assert sorted(checks)==[["LaunchNow","RYMU_LAUNCH_NOW"],["StartWindows","RYMU_START_WINDOWS"]]
        print("PASS independent completion checkboxes; startup then optional launch; Escape/Close have no helper/launch side effects")
        print("PASS branded install/remove flow, explicit removal confirmation, cancel/back and native failure dialogs")
        mappings = query("SELECT `Dialog_`, `Control_`, `Event`, `Attribute` FROM `EventMapping`", 4)
        assert ["RymuProgressDlg", "ProgressBar", "SetProgress", "Progress"] in mappings
        assert ["RymuProgressDlg", "ActionText", "ActionText", "Text"] in mappings
        print("PASS progress is subscribed to Windows Installer execution events")
    finally:
        msi.MsiCloseHandle(db)


if __name__ == "__main__":
    main()
