# Windows x64 runner build

Current owner package: **0.1.12**, published November 10. It adds a system-tray icon, hide-on-close, explicit Quit, preserved account/startup choices and a graphical MSI based on the website with optional launch and Windows startup choices on Finish. The native privacy DLL is unchanged. See the [Arabic report](TRAY_UPDATE_2026-11-10_AR.md), [build recipe](TRAY_BUILD.md) and [release record](../artifacts/tray-release.json). Two narrowly reviewed installed-file Finish actions are now required; the old zero-custom-action packaging description below is historical. Final GUI installation/upgrade/Finish/uninstall and actual reboot remain unqualified after the Escape stop; the observed installed machine version is 0.1.11. Pre-logon hosting is not implemented. Earlier version-specific sections below are build history.

The attended Rymu runner uses the pinned RustDesk 1.5.1 source, Flutter 3.24.5, Dart 3.5.4 and the upstream Windows x64 engine archive described in [BUILD_AND_RUN.md](BUILD_AND_RUN.md). The standard Rust and Windows dependency steps are there. Use a dedicated SDK inside the project’s `.local` directory. For this workstation’s Visual Studio Build Tools 2026, the SDK’s Windows generator switch includes `18 => 'Visual Studio 18 2026'`. Apply that compatibility change and the upstream dropdown patch to the dedicated SDK only. Visual Studio 2022 uses the upstream generator switch as written.

## Plan policy owner build

Version 0.1.2 defaults to the hosted account API. For single-display grants, the attended host publishes the Windows primary display as logical index zero. It restricts capture, follow-display, subscription and screenshot paths to that display. Pro grants can retain the existing multi-display behavior. Four Rust tests passed, the rebuilt engine returned three local display descriptors, and both unsigned packages matched the staged runner's 92 files. The package and bridge checks ran locally. Clean installation and an actual remote peer session are pending.

[Owner-test MSI](../artifacts/windows/Rymu-Windows-x64-Plan-Policy-Dev.msi) · [Portable ZIP](../artifacts/windows/Rymu-Windows-x64-Plan-Policy-Portable-Dev.zip) · [Package evidence](../artifacts/logs/windows-plan-policy-package.log)

## Build on C: with a prepared Rust DLL

This workaround uses the locked Flutter manifests and the pinned SDK’s plugin generator. It is useful when Flutter's standard pub wrapper waits on an inaccessible drive or cannot create plugin symlinks. It creates junctions in the project’s generated Windows build directory and keeps the package cache, project, temp files and SDK on C:. Run its stages serially using an SDK that no other active build uses.

From the project root in Command Prompt:

```cmd
python scripts\windows-native.py build
node scripts\windows-flutter.mjs prepare
node scripts\windows-flutter.mjs build .local\flutter-sdk\flutter --local
```

The workstation-native helper uses Rust 1.75.0 in `.local/rustup-win`, the locked Cargo cache in `.local/cargo-shim`, pinned vcpkg in `.local/vcpkg`, and libclang 15.0.6 in `.local/llvm-15-ntfs`. It uses the release profile with optimization level 1, eight code generation units, LTO off, and only the shared library target. It stages the DLL at `apps/native/target/release/librustdesk.dll`. Place the generated Rust and Dart bridge files in the fork first. The [PyPI Windows x64 libclang wheel](https://pypi.org/project/libclang/15.0.6/#files) used here has SHA-256 `1acbadc725aa58250c8b9c201dcd694ac68858ccf9d585e8645ccd72fc29a7df`.

`prepare` uses the C: Pub cache from `PUB_CACHE` or the standard local user cache. With a cold cache, run `node scripts\windows-flutter.mjs prepare .local\flutter-sdk\flutter --online` to fetch the locked versions. The helper rejects existing plugin entries that resolve to a different source. Run it again after a dependency change and inspect any conflict before replacing old generated output.

The `--local` binary is for loopback development. It points at the local API on port 18787 and the account website on port 15173. The bundle is in:

```text
apps/native/flutter/build/windows/x64/runner/Release
```

The directory must travel together. It contains `Rymu.exe`, the Flutter engine, the compiled Rust DLL, eleven native plugin DLLs, ICU data, AOT application code and Flutter assets. This build uses the attended application flow. It does not register a Windows service.

## Recorded workstation result

The copied SDK’s Flutter tool package configuration initially referenced 95 packages on an unresponsive volume. A locked Dart pub run regenerated the SDK configuration with all 97 package roots on C:. Flutter then generated the native registrants and CMake plugin list. Seventeen NTFS junction entries cover the resolved Windows packages, including Dart-only packages. The x64 Flutter build completed with exit code 0, including kernel and AOT compilation, CMake generation, C++ linking and bundle installation.

The final bundled EXE and Rust DLL are x64 PE32+ files without an embedded certificate directory. The DLL hash matched the staged Rust output. The no-operation CLI probe `Rymu.exe --service-control` returned Win32 error 5. The runner removes the upstream SCM dispatcher and checks this flag before loading the Rust library. This probe exercises command rejection and the executable loader. Runtime launch and remote session tests are recorded separately.

Microsoft Dumpbin inspected all fourteen bundled EXE/DLL images and reported their imports. The static import list contains no MSVC redistributable DLL names. This inspection does not validate optional dependencies loaded dynamically at runtime or clean-machine installation.

The final Windows runner opened on the workstation. The signed-out Devices screen was observed in English and Arabic, including right-to-left navigation. The compiled DLL enumerated three Windows display descriptors. Its probe also exercised DPAPI in an isolated temporary profile, tested the device public key against an RFC 8032 test vector, and rejected a public default rendezvous. Two targeted Rust tests passed.

The unsigned WiX MSI and portable ZIP are in `artifacts/windows/`. The MSI requires Windows 11 x64 (build 22000 or newer). Windows Installer reported compatibility values 603 and 9600 on the tested Windows 11 build 26300. The package now checks the native registry build number, with `VersionNT64` only for architecture. WiX schema and ICE validation exited 0 with ICE60 and ICE91 warnings for file language metadata and intentional per-user placement. The MSI database contains no service or custom action tables, and all 92 cabinet files matched the compiled bundle by SHA-256. [VersionNT64 property](https://learn.microsoft.com/en-us/windows/win32/msi/versionnt64)

An earlier MSI run stalled at `CostInitialize`, and the next retry returned 1618. On November 5, 2026, a later per-user install on the same Windows 11 workstation completed with Windows Installer status 0. All 92 installed files matched the build by SHA-256, and the **Rymu (Development)** Start menu shortcut was present. Clean-OS installation and removal are still unqualified. See [the install evidence](../artifacts/logs/windows-msi-install-current.log).

## Connect installed copies to the hosted account

Use the owner's invitation to create a passkey on the [Rymu account page](https://rymu.iptvora-server.workers.dev/account). Use a passkey you can access on both devices, such as one available from your phone. In each installed copy, open **Settings → Account service and private relay → Edit**. Set **Control API URL** to `https://rymu.iptvora-server.workers.dev/api/v1` and save.

Choose **Sign in**, give each computer a distinct name, and allow hosting on the intended host. Compare the authorization code shown in the app with the browser prompt. When the app shows the enrollment code, use **Open approval**, verify that code in the account, and return to **Finish setup**. For a screen session, configure the same authorized private rendezvous, relay and server public key on both computers, then select **Start hosting** on the host. The public account service and the private media path are verified separately.

## Panorama owner build

The Panorama Windows development build uses the selected monochrome launcher icon and an opt-in HTTPS account endpoint. A fresh profile uses the hosted service. If a profile previously saved a local endpoint, open **Settings → Account service and private relay → Edit** and set the hosted URL before signing in.

```powershell
$env:RYMU_BROWSER_CHANNEL = 'chrome'
node scripts/generate-windows-icon.mjs
$env:RYMU_ACCOUNT_API_BASE = 'https://rymu.iptvora-server.workers.dev/api/v1'
node scripts/windows-flutter.mjs build .local/flutter-sdk/flutter
```

The owner artifacts are [Panorama per-user MSI](../artifacts/windows/Rymu-Windows-x64-Panorama-Dev.msi) and [Panorama portable ZIP](../artifacts/windows/Rymu-Windows-x64-Panorama-Portable-Dev.zip). The MSI uses version 0.1.1 and the existing upgrade code. Each unsigned package matched all 92 files of the Panorama runner. The build passed five isolated account configuration tests, 14 display geometry checks and the compiled bridge smoke. The new MSI was checked at the payload and upgrade-metadata levels. Installation and a native peer session are pending. See `artifacts/logs/windows-panorama-final-build.log`, `artifacts/logs/windows-panorama-account-test.log` and `artifacts/logs/windows-panorama-msi-payload.log`.

Evidence:

- `artifacts/logs/windows-c-lane-sdk-pub.log`
- `artifacts/logs/windows-c-lane-plugins.log`
- `artifacts/logs/windows-c-lane-build.log`
- `artifacts/logs/windows-runner-pe-and-guard.json`
- `artifacts/logs/windows-runner-imports.log`
- `artifacts/logs/windows-bundle-runtime-dependencies.json`
- `artifacts/logs/windows-flutter-recipe-prepare.log`
- `artifacts/logs/windows-ntfs-build.log`
- `artifacts/logs/windows-ntfs-test.log`
- `artifacts/logs/windows-final-bridge.log`
- `artifacts/logs/windows-msi-light.log`
- `artifacts/logs/windows-msi-payload.log`
- `artifacts/logs/windows-msi-round-trip-final.log`
- `artifacts/logs/windows-msi-round-trip-c.log`
- `artifacts/screenshots/windows-home-en.jpg`
- `artifacts/screenshots/windows-home-ar.jpg`
