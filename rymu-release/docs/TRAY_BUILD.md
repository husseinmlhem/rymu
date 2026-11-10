# Windows tray and graphical installer build

Version 0.1.12 is a per-user owner-test MSI. The native Rust DLL is reused from
0.1.10 after a 388-file Rust/Cargo source comparison and exact DLL hash check.
The Windows runner C++ and Flutter AOT are rebuilt. Android remains 2076.

Use the pinned Windows environment in WINDOWS.md, then from the repository:

```powershell
$env:RYMU_ACCOUNT_API_BASE='https://rymu.iptvora-server.workers.dev/api/v1'
node scripts/windows-flutter.mjs build
python scripts/emit-windows-msi.py apps/native/flutter/build/windows/x64/runner/Release .local/msi/Rymu-0.1.12.wxs --version 0.1.12
.local/wix3141/candle.exe -nologo -arch x64 -out .local/msi/Rymu-0.1.12.wixobj .local/msi/Rymu-0.1.12.wxs
.local/wix3141/light.exe -nologo -spdb -ext .local/wix3141/WixUIExtension.dll -cultures:en-us -out artifacts/windows/Rymu-Windows-x64-0.1.12-Dev.msi .local/msi/Rymu-0.1.12.wixobj
python scripts/test-windows-msi.py artifacts/windows/Rymu-Windows-x64-0.1.12-Dev.msi apps/native/flutter/build/windows/x64/runner/Release --log-dir artifacts/logs/windows-0.1.12-msi-payload
```

Do not overwrite a published installer; retain its immutable checksum and use a
new product version for a replacement. See design/installer/README.md for the
graphical dialogs and finish-choice validation commands. The new explicit Finish
choices require exactly two installed-file custom actions: one synchronous
startup-setting call and one optional asynchronous launch. Neither is scheduled
in an install execute/UI sequence. The MSI checker only accepts their exact
names, types, FileKey and arguments; it still rejects services and arbitrary
custom actions. No shell interpreter, general command execution or elevation is
used. This is an intentional change from the previous zero-custom-action MSI.

The executable handles only `--rymu-installer-startup on|off` before loading the
Rust engine. It checks its installed per-user path, writes only Rymu's Run value
and pending choice, and returns a Win32 result. Account startup consumes that
choice before automatic defaults. `scripts/qa/windows-installer-startup-probe.py`
compiles the same helper in a test process with process-local HKCU redirection;
`scripts/qa/windows-startup-probe.py` checks the actual Dart Win32 operations.
These are registry component tests, not Windows reboot or MSI Finish tests.

The current source archive is generated with `scripts/package-tray-source.py`.
It uses temporary Git indexes, verifies exact upstream-patch reconstruction,
includes generated bridge files and installer artwork, and preserves the real
repository index. Build/installer/runtime/publication evidence is recorded in
`artifacts/tray-release.json`. Native tray GUI evidence was obtained on 0.1.11;
after an Escape stop no further native GUI input was used. Version 0.1.12 has
fresh compilation, component, guard, payload and MSI condition/table checks;
its full install/upgrade/Finish/uninstall UI and a real reboot remain unverified.
