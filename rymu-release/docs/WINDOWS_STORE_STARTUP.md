# Packaged Windows startup — 0.1.13 candidate

The Store candidate separates two choices in Settings:

- **Resume hosting when Rymu opens** saves consent for the signed-in enrolled
  host. A manual or Windows-triggered launch may resume that consent. Stop
  hosting clears it. Signing out removes the account's hosting consent.
- **Start Rymu with Windows** uses the package's `RymuStartup` StartupTask.
  Its manifest starts with `Enabled="false"`. Only an explicit switch action
  requests enablement. It opens Rymu after Windows user sign-in; it is not a
  machine service or a guarantee of unattended access before sign-in.

Store sign-out/Stop hosting do not change the independent OS startup setting.
An enabled task can open the signed-out app, but cannot start authenticated
hosting without a saved enrolled account and hosting consent. A newly detected
Store account does not receive the MSI's legacy automatic-hosting migration.
An explicit enrollment action that requests hosting may save hosting consent;
it still cannot enable Windows startup.

`windows_package_identity.dart` calls `GetCurrentPackageFullName` once per
process. `APPMODEL_ERROR_NO_PACKAGE` selects the existing MSI path;
`ERROR_INSUFFICIENT_BUFFER` identifies the packaged process. Any unexpected
result fails closed. Both the Dart Run-key writer and the native MSI Finish
helper reject packaged identity before accessing their legacy settings.
The private 0.1.12 MSI and its immutable downloads are preserved.

`rymu_packaged_startup.cpp` owns a separate Flutter method channel. Its fixed
TaskId is `RymuStartup`; it accepts no arbitrary executable/task arguments.
C++/WinRT awaits `GetAsync` and `RequestEnableAsync` on the originating Windows
STA without blocking Flutter. A lifetime guard prevents replies after the
engine is destroyed. `DisabledByUser`, `DisabledByPolicy`, and
`EnabledByPolicy` remain authoritative. Windows user/policy disables are not
silently reversed. The UI explains how to re-enable through Windows Settings,
and refreshes the state on window focus. API requests have an eight-second UI
timeout and a visible retry option; the native bridge rejects overlapping
requests until the current OS request completes.

The new runner source uses SDK C++/WinRT headers and the Windows SDK
`windowsapp` import library. It adds no package dependency, driver, service,
Rust changes, generated bridge changes, or system policy/registry changes.
The existing MSI startup implementation remains synchronous and otherwise
unchanged below the new package-identity guards.

## Verified in this workspace

- Standalone compilation of the production native startup source with MSVC
  `/std:c++20 /W4 /WX`: passed. Evidence:
  `artifacts/logs/windows-packaged-startup-compile.log`.
- Focused Dart analysis of identity, startup API, account and home: passed.
- Windows lifecycle tests: **13 passed**, including the ten existing MSI,
  tray, layout, token rotation and restart-consent regressions plus three Store
  cases. The new cases check consent across account recreation, explicit
  startup enablement with Windows user disable, and error retry/policy state.
  They use mocked platform-channel responses and a disposable local profile,
  not a registered package or the owner's account. Evidence:
  `artifacts/logs/windows-store-startup-lifecycle-tests-final.log`.
- The first test run exposed a finder mismatch for `TextButton.icon` in the
  new retry test. The finder was corrected; its failed log is retained as
  `windows-store-startup-lifecycle-tests.log`.

The full 0.1.13 runner build and MSIX pack/validation are recorded separately
by the release/packaging work. **Actual StartupTask enable/disable, packaged
authentication/storage, Windows Settings interaction, and real reboot/logon
remain unverified until a trusted package with the final identity is installed
in a dedicated test environment.** No owner installation, running app, OS
startup preference, certificate store, or Windows setting was changed for
these tests. MSI/Store coexistence still needs qualification because the
existing runner window class and OAuth loopback port are shared.

## API references

- [StartupTask and packaged desktop consent semantics](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask?view=winrt-26100)
- [RequestEnableAsync and user-controlled disables](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask.requestenableasync?view=winrt-26100)
- [GetCurrentPackageFullName return values](https://learn.microsoft.com/en-us/windows/win32/api/appmodel/nf-appmodel-getcurrentpackagefullname)

