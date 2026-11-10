# Rymu native Windows Installer UI

## Current design: Windows 0.1.12

The owner rejected the smaller 0.1.11 dialog. Version 0.1.12 replaces it with a
600-by-390 dialog-unit layout based on the actual website: its monochrome globe,
a dark rounded hero panel, three concise setup facts, silver/white cards and
clear setup/install/ready steps. Removal uses review/remove/done steps and the
same artwork. Text and buttons remain native controls; artwork is static and
does not pretend the MSI is a browser or animated glass UI.

The immutable final artifact is
`artifacts/windows/Rymu-Windows-x64-0.1.12-Dev.msi`, **36,618,240 bytes**, SHA-256
`9c583ce741e1a9dd6ec6abc71a0f1fe29525b00a508cc19618d4fe5e1f9d9e0e`.
WiX compilation/linking and ICE validation passed. All **92** extracted payload
files match the final 0.1.12 runner. UI/action-table checks and the **12** native
Windows Installer condition scenarios passed against these exact package bytes.
Evidence is in `artifacts/logs/windows-0.1.12-installer-final-light.log`,
`windows-0.1.12-installer-final-payload.log`,
`windows-0.1.12-installer-ui-checks.log` and
`windows-0.1.12-installer-condition-checks.log` in that same logs directory.

`generate-assets.py` composes the approved website globe and Windows mark;
`generate-ui.py` authors `rymu-ui.wxi`. Run those scripts before packaging.
`render-preview.py` makes **source-layout design previews**. These previews are
not screenshots, successful installations or evidence of real checkbox clicks.
The revised native dialogs have not been operated since Computer Use was stopped
with physical Escape during the earlier 0.1.11 test.

The last page has two independent checkboxes, checked by default:

- **Launch Rymu now** controls whether the installed app is opened after Finish.
- **Start Rymu with Windows** controls startup after Windows user sign-in.

**Finish** assigns `RYMU_STARTUP_ARG` to `on` or `off`, then invokes the installed
`Rymu.exe --rymu-installer-startup [RYMU_STARTUP_ARG]` synchronously with checked
return status. The optional launch follows. **Close**, Escape and the window X
close this page without these side effects. The UI explicitly says Finish saves
the choices and Close leaves them unchanged.

The latest user request authorizes exactly two narrowly scoped installed-file
custom actions, superseding the older no-custom-action packaging constraint:

| Action | MSI type | Source | Target | Return |
|---|---:|---|---|---|
| `RymuApplyStartup` | 18 | `RymuExe` | `--rymu-installer-startup [RYMU_STARTUP_ARG]` | synchronous, checked |
| `RymuLaunchNow` | 210 (18 + asynchronous/no-wait flags) | `RymuExe` | no arguments | asynchronous, no wait |

No script, shell, elevated process, service or custom action in any sequence
table is added. Both actions are reachable only from explicit Finish after a
full-UI first installation/major upgrade. Conditions exclude silent/basic/reduced
UI, uninstall, maintenance/repair, patch and administrative image operations.
The native helper validates the exact installed executable path and exact
argument, updates the app-owned Run preference plus its pending setting, and
does not load the main Flutter/Rust UI. Its implementation and component tests
are owned by the Windows runner update. If a helper failure occurs, its actual
interactive Windows Installer error behavior remains **not_run**, even though
the package requests checked return handling.

`verify-ui.py` checks the two-action allowlist, real event order, independent
checkboxes, escape/close path, unchanged upgrade identity and absence of
sequence/registry/service side effects. `verify-finish-conditions.py` uses
Windows Installer's own expression evaluator in an in-memory package session
for 12 checkbox/lifecycle combinations. It executes **zero custom actions**.
Use the final release logs for actual pass/fail results; condition evaluation is
not an installed Finish-button test.

The source bundle must include this whole directory, the installer verification
scripts, `design/assets/rymu-windows.ico`, and
`apps/web/src/globe-fallback.webp` so the artwork can be reproduced.

0.1.11 is already installed on the owner's machine and its immutable MSI is
preserved. 0.1.12 is a separate version and package; actual upgrade to 0.1.12,
new full-UI Finish handling, real uninstall and a new silent installation are
**not_run**. No claim of those actions follows from compilation, design previews
or the prior version's installation.

## Previous 0.1.11 implementation and observed installation

The earlier 0.1.11 MSI had a monochrome welcome, native Windows Installer progress,
completion, maintenance and explicit uninstall-confirmation flow. The approved
Windows icon is reused. Segoe UI, white/silver artwork and native buttons match
the application without attempting unsupported transparent/glass MSI controls.
The installer is English (`1033`); the application's Arabic/English selection
is unchanged. Native focus/default/cancel buttons and standard Windows scaling
remain available. Arabic installer localization is not implemented.

`generate-assets.py` produces the two BMP resources with Pillow from the existing
approved ICO. It does not create or substitute a new logo. `rymu-ui.wxi` is included
by `scripts/emit-windows-msi.py`. Link with WiX 3.14.1 `WixUIExtension.dll` and
`-cultures:en-us`; `scripts/build-windows-msi.ps1` includes these arguments.

The extension supplies its standard error, cancellation, disk-space and
files-in-use dialogs; their bitmap and font resources receive the same branding.
The actual progress bar subscribes to Windows Installer events. Removing the app
requires the maintenance **Uninstall** button and a second confirmation; **Keep
Rymu**, **Back** and **Cancel** do not schedule removal. The remove event uses
`ALL`, with `REMOVE=ALL` assigned before returning to the sequence. `REINSTALL`
skips the uninstall dialog, preserving the repair command path.

That 0.1.11 MSI was per-user with the original upgrade identity and no service or
custom action. `/qn` was structurally supported; no UI was inserted into the
execute sequence. The new UI does not launch the application or terminate a
remote host. Uninstall text instructs the user to quit from the tray first;
Windows Installer retains its normal files-in-use handling.

## User data and startup

The package does not delete the protected account vault, settings or personal
files. It does not create, change or remove the application's `RymuAutoHost`
value in the shared HKCU Run key. The app continues to own that setting, so
upgrading or repairing cannot silently override an explicit startup opt-out.

Known existing limitation: a value created by the app can remain after MSI
uninstall, pointing to the removed executable. It cannot launch that removed
installation, but the startup entry may remain visible in Windows. Disable
automatic hosting in Rymu before uninstalling if this cleanup is desired. WiX3
`RemoveRegistryValue` only deletes during installation, and deleting the entire
shared Run key would damage unrelated apps. No custom-action workaround was
added. [WiX3 schema](https://docs.firegiant.com/wix3/xsd/wix/removeregistryvalue/)

## Verification on November 10, 2026

- WiX compile/link and ICE validation passed. Existing ICE60/ICE69/ICE91 warnings
  concern file language metadata, the same-feature shortcut and intentional
  per-user paths; no validation errors remained.
- `scripts/windows-installer/verify-ui.py` passed against the final MSI: identity,
  no custom actions/services, no startup overrides/vault deletion, flow ordering,
  explicit removal confirmation, cancel/back, repair exclusion and real progress
  event mappings.
- `scripts/test-windows-msi.py` verified all 92 extracted payload files against
  the current native runner.
- Actual native **inactive previews** of welcome and removal confirmation were
  visually inspected and captured. These use `MsiEnableUIPreview`, do not execute
  setup actions, and are not installation/uninstallation tests.
- The exact final MSI was launched with full UI after a guard confirmed no
  existing related product, install directory, shortcut or running Rymu app.
  Its log records successful costing and creation of `RymuWelcomeDlg`. Before any
  Install/Uninstall button was clicked by the agent, Computer Use reported that
  the user stopped it with physical Escape. No further UI inputs or alternate
  API inputs were issued. The installer window was left to the user; it was not
  silently terminated or resumed by the agent.
- A later read-only process/log check observed the installer finish at 11:05:38
  with status **0**. That activity occurred outside agent UI automation; its
  actor was not inferred as a test result. `check-installed.py` then verified the
  exact MSI's registered product, all **92 installed files** against the runner,
  the Start menu shortcut, and unchanged encrypted-vault/startup fingerprints.
  Installation therefore has real machine evidence. The installed app was left
  intact; no uninstall was attempted afterward.
- Actual maintenance/cancel/uninstall navigation and a new `/qn` round-trip
  remain **not_run/interrupted**. Inactive previews and database assertions do
  not count as a completed uninstall or repair.

Preserved historical MSI: `artifacts/windows/Rymu-Windows-x64-0.1.11-Dev.msi`, 26,701,824 bytes,
SHA-256 `7100487bc7341ac898a11e274e70d6f6ae665ea748620a026da9c6d791cc6326`.
Its source and bytes were frozen before the interrupted interactive test.

Evidence: `artifacts/logs/windows-0.1.11-installer-ui-light.log`,
`artifacts/logs/windows-0.1.11-installer-interactive-install.log`,
`artifacts/logs/windows-0.1.11-installer-installed.log`,
`artifacts/screenshots/windows-0.1.11-installer-welcome-preview.png`,
`artifacts/screenshots/windows-0.1.11-installer-remove-preview.png`.
The preservation fingerprint record is local-only at
`.local/msi/ui-round-trip-preservation.json`; it contains hashes, never decrypted
tokens or the raw startup command. `check-preservation.py` refuses an existing
installation and never changes it.

The public Microsoft Store route is assessed separately in
`docs/MICROSOFT_STORE_READINESS_2026-11-10_AR.md`; this unsigned development MSI
is not a Store-certified release.
