# Windows notification-area lifecycle validation — 2026-11-10

The first exact-runner and linked-MSI results below qualify **0.1.11** only.
The later **0.1.12** installer redesign and startup helper have separate no-UI
checks in the final section. They do not inherit a passing native-runner or
installer-UI result from the earlier binaries. No new graphical testing is authorized
after the user's Escape intervention; this review does not reopen applications
or navigate setup.

The reproducible OS-level smoke is `scripts/qa/windows-tray-smoke.py`. It accepts
an exact candidate bundle's `Rymu.exe` and records the executable, Rust DLL and
Flutter AOT SHA-256 values. It refuses to run if a Rymu main window is already
open, uses a new temporary `LOCALAPPDATA`/`APPDATA` profile, and only sends
messages to the process it launched. No owner account, Windows reboot or
Explorer termination is required.

```powershell
python scripts/qa/windows-tray-smoke.py --exe <candidate-bundle>/Rymu.exe --output artifacts/logs/windows-tray-native-smoke.json
```

The smoke checks actual Windows notification-icon registration with
`Shell_NotifyIconGetRect`, system-close hiding without process exit, notification
selection and Open-menu restoration, a native context menu, full Quit, removal
of the notification icon, and persistence of an encrypted non-secret vault
sentinel across application exit and restart. It snapshots the owner's Rymu
startup registry value and requires it to remain unchanged.

The recovery check removes only the test process's icon and posts the registered
`TaskbarCreated` message. This exercises the production recovery handler; it is
not an actual Explorer restart. Native command/callback dispatch is also not a
physical mouse test. The vault sentinel is not an authenticated account session.

## Results

Final-runner execution passed all **11 checks**, with harness exit code **0**,
at `2026-11-10T06:58:31Z`. Full Quit exited with code 0 in **0.159 seconds**.
The temporary profile was removed, no Rymu test process remained, and the
owner's startup registry value was unchanged. Evidence is in
[`windows-tray-native-smoke.json`](../artifacts/logs/windows-tray-native-smoke.json)
and its adjacent `.log`.

| Final component | SHA-256 |
| --- | --- |
| Rymu.exe | `21d53fbefbf7f2937a27cf3160c5706389b745f7e0f20a25b81214d3a41c7a04` |
| librustdesk.dll | `86da5df5692c24ad68cbf59d1821fdac21bd2425a6b747ded4f1a8ef88f4843f` |
| data/app.so | `b3e88d2737f34c982626418982151429ec94640bdd361d3088db18c3b3619f49` |

The first two attempts exposed a harness issue: `STARTF_USESHOWWINDOW/SW_HIDE`
overrides the runner's first `ShowWindow`, including a shortcut process's
restoration of the original window. The harness now launches this interactive
app normally. Attempt 3 passed all product checks but encountered a transient
locked log during scratch cleanup. The final harness retries bounded cleanup
and records retention if needed. All three earlier logs/JSON files are retained
with `-attempt1`, `-attempt2`, and `-attempt3` suffixes; no application code was
changed to make these checks pass.

These qualifications remain **not_run**:

- Real Windows reboot/logon and unattended hosting after it.
- A physical tray mouse interaction.
- An actual Explorer process restart.
- A real-account or remote-peer session, including disconnect on full Quit.

Account restoration, automatic-hosting migration, explicit opt-out and refresh
token handling are covered separately by the focused Flutter lifecycle tests
in `artifacts/logs/windows-tray-lifecycle-tests-final.log`. Their startup writer
is mocked, while vault persistence uses the isolated compiled DPAPI bridge.
Those results must not be presented as a real reboot or real Internet session.

## Review notes

The native tray uses the main process's window, not a second RustDesk service or
an upstream tray process. The icon's status distinguishes sign-in required,
waiting, hosting stopped and ready. On Windows-shell failure, a recoverable
visible window and full-exit action are required. Failure to register automatic
startup must not prevent ordinary account refresh. Both review findings were
addressed by the implementation agent before the final build: tray failure now
shows an explicit full-exit button, and startup migration errors no longer skip
the regular signed-in refresh.

Installer installation/uninstallation is outside this script. Exact installer
welcome/cancel and payload validation may run without changing the owner
installation. An isolated fixture installer must have a separate product,
upgrade identity, directory and registry scope; its results must be explicitly
labelled as fixture results.

## Independent installer source review

Reviewed `design/installer/rymu-ui.wxi` and `scripts/emit-windows-msi.py` after the
tray smoke. The package retains a per-user scope, standard Windows Installer
progress and files-in-use dialogs, explicit uninstall confirmation, and no
service or custom executable action. Dialog-preview rendering is not evidence
of successful installation or uninstallation.

Two concrete routing/condition corrections were sent to the installer author
and are **resolved** in both source and the independently read final linked MSI:

1. The Remove event should use documented `ALL`, with `REMOVE=ALL` set explicitly
   before returning from confirmation so the progress copy already describes
   removal. Microsoft documents that `REMOVE` is not necessarily `ALL` before
   `InstallValidate`. See [Remove ControlEvent](https://learn.microsoft.com/en-us/windows/win32/msi/remove-controlevent)
   and [conditioning removal actions](https://learn.microsoft.com/en-gb/windows/win32/msi/conditioning-actions-to-run-during-removal).
2. The installed-product maintenance dialog must exclude `REINSTALL`, otherwise
   a full-UI `/f` repair invocation lands in an uninstall-only flow. Standard
   command-line repair remains available even when `ARPNOMODIFY` hides Change in
   Apps & Features. See [Windows Installer ARP properties](https://learn.microsoft.com/en-us/windows/win32/msi/configuring-add-remove-programs-with-windows-installer).

The read-only MSI check confirmed the ordered `[REMOVE]=ALL`, `Remove ALL`,
`EndDialog Return` events, the `NOT REINSTALL` maintenance condition, and absence
of a CustomAction table. Evidence:
[`windows-tray-msi-review.json`](../artifacts/logs/windows-tray-msi-review.json).
Reviewed candidate SHA-256:
`7100487bc7341ac898a11e274e70d6f6ae665ea748620a026da9c6d791cc6326`.
This review did not run `msiexec`, navigate the wizard or install/remove files;
the installer agent records those separate UI and installation qualifications.

The app-created `HKCU/.../Run/RymuAutoHost` value is not currently owned by the
MSI. Retaining it on uninstall leaves an inert startup entry while the executable
is absent. Removing the shared Run key would be unsafe. WiX 3 explicitly states
that `RemoveRegistryValue` is install-only; scoped removal requires a deliberate
ownership/cleanup design, not a broad key deletion. See
[WiX 3 RemoveRegistryValue](https://docs.firegiant.com/wix3/xsd/wix/removeregistryvalue/).
If future cleanup removes the value, reinstall must restore an enabled saved
startup preference without overriding an explicit opt-out.

## 0.1.12 startup-helper source review

The later owner request adds explicit **Launch now** and **Start with Windows**
choices to the completed installer. This changes the earlier no-custom-action
design: exactly two installed-file EXE actions are intended, one synchronous
startup helper and one optional asynchronous ordinary launch. The final MSI
allowlist must be checked against the actual linked table, not these intentions.

Reviewed `rymu_installer_startup.cpp`, its `main.cpp` dispatch, and the Dart
startup preference integration. The helper recognizes exactly
`--rymu-installer-startup on|off`, returns before loading Rust or Flutter,
requires its own installed executable path, and only edits the fixed per-user
`RymuAutoHost` Run value and `Software/Rymu/Installer/StartWithWindows` DWORD.
It does not invoke a shell, install a service, request elevation or read login
credentials.

Two source findings are **resolved**:

- If the pending-preference write fails after updating Run, the helper now
  restores the prior Run value/type and returns a nonzero status.
- Once an installer OFF choice has been consumed, later enrollment respects
  the saved OFF preference instead of defaulting back to ON.

The MSI actions must run only from explicit Finish on a successful full-UI
installation, after files have been installed. Silent execution, repair,
uninstall, administrative image creation, cancellation and success-page
Escape/X must not trigger them. Microsoft's
[Type 18](https://learn.microsoft.com/en-us/windows/win32/msi/custom-action-type-18)
and [return-processing flags](https://learn.microsoft.com/en-us/windows/win32/msi/custom-action-return-processing-options)
define the installed-file and synchronous/asynchronous constraints.

The exact **0.1.12** executable passed **seven no-UI rejection checks** with
exit code 0: missing, invalid, extra and reordered helper arguments return 87;
the portable build refuses both ON and OFF with error 5; the existing
`--service-control` guard also returns 5. The owner Run value and pending
preference fingerprints match before and after. Exact EXE SHA-256:
`d161f0f05913acf4206307eda62119bcaeb00dea1e9f4d56ddc52b02a575ac17`.
Evidence:
[`windows-tray-0.1.12-helper-guards.json`](../artifacts/logs/windows-tray-0.1.12-helper-guards.json).

The repeatable no-UI command is:

```powershell
python scripts/qa/windows-tray-smoke.py --helper-guards-only --exe <portable-build>/Rymu.exe --output artifacts/logs/windows-tray-0.1.12-helper-guards.json
```

The successful ON/OFF registry writes were separately qualified by the startup
agent's production-helper component probe with a process-local HKCU override;
see `artifacts/logs/windows-installer-startup-probe.json`. That component probe
is not execution of the final installed EXE or an actual MSI Finish action.
The independent final **0.1.12** linked-MSI review **passed**. The MSI is
36,618,240 bytes, SHA-256
`9c583ce741e1a9dd6ec6abc71a0f1fe29525b00a508cc19618d4fe5e1f9d9e0e`.
Evidence:
[`windows-tray-0.1.12-msi-review.json`](../artifacts/logs/windows-tray-0.1.12-msi-review.json).
Its actual tables contain exactly `RymuApplyStartup` (type 18, synchronous,
checked) and `RymuLaunchNow` (type 210, asynchronous, no wait), both sourced only
from installed `RymuExe`. The only DoAction entries are on success-page Finish,
ordered after choosing ON/OFF; neither action is scheduled in any install,
administrative, advertising or UI sequence table. Close is the dialog's Cancel
control and publishes only EndDialog, so Escape/X does not bind to Finish.

The installer's separate 12-case `MsiEvaluateCondition` matrix passed against
the linked MSI without invoking custom actions. It covers all four checkbox
combinations plus silent, basic, reduced, uninstall, repair, maintenance, patch
and administrative-image contexts; see
`artifacts/logs/windows-0.1.12-installer-condition-checks.log`.

Actual **0.1.12** GUI navigation, successful Finish helper/application launch,
native tray interaction, and reboot remain **not_run**. In particular, a
checked synchronous helper return is verified in the MSI table; the error
dialog experience on helper failure has not been exercised. Earlier 0.1.11
UI/runner passes do not establish these later binary/UI results.
