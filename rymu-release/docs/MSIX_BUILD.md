# Rymu MSIX packaging and qualification

Date: 2026-11-10. Status: **real Store identity reserved; final unsigned 1.0.14.0 candidate built and statically verified; not Store-ready**.

Related: `WINDOWS_STORE_STARTUP.md` records native startup behavior and validation; `MICROSOFT_STORE_LISTING_DRAFT_EN_AR.md` contains reviewable listing copy and current website gaps.

This path packages the complete native Windows runner. It does not change the published MSI, install Rymu, activate the host, add a certificate, change Developer Mode, purchase signing, or submit to Microsoft. The current website MSI remains 0.1.12. The new native/MSI engineering version is 0.1.14, mapped to **MSIX package version 1.0.14.0** because Store packages require a nonzero major component and zero fourth component. This mapping does not change the currently published MSI. The earlier 0.1.13 runner was an intermediate build. Final 1.0.14.0 packaging used the frozen 0.1.14 runner after the owner's monitor/trackpad, designated-folder and attribution source changes were complete. The script enforces Store version rules for real identity mode; historical 0.x audit packages are allowed only in explicit local qualification mode. [Store package version rules](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/package-version-numbering?pivots=store-installer-msix).

## Build inputs and identity

The parent agent observed the reserved **Rymu** product's Identity page in Partner Center on 2026-11-10, product ID **9PCVC3KR552G**. The copied identity at `.local/rymu-partner-center-identity.json` passed this script's real-identity validation and the Windows-derived family-name check:

| Identity field | Exact observed value |
| --- | --- |
| Package name | `HusseinMlhem.Rymu` |
| Publisher | `CN=F9C1B031-E95E-4F61-9D33-FEFE22907F92` |
| Publisher display name | `Hussein Mlhem` |
| Package family name | `HusseinMlhem.Rymu_fqz8v1xeapywr` |
| Application ID / AUMID | `Rymu` / `HusseinMlhem.Rymu_fqz8v1xeapywr!Rymu` |

Evidence: `artifacts/windows-store/partner-center-identity-validation.json`. Identity reservation is complete; package submission, certification, and publishing are not. The exact 0.1.14 runner was subsequently packaged as 1.0.14.0; results are below.

Python with Pillow, the complete Flutter Windows release folder, Visual Studio x64 `dumpbin`, and Windows SDK `MakeAppx` are required. The current installed SDK path is `C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64` (MakeAppx reports 10.0.26100.8249).

Before a Store candidate is built, reserve the actual product in Partner Center and copy its exact package identity name, publisher, publisher display name, and package family name into a private working copy of `scripts/windows-store/identity.template.json`. The template deliberately cannot build. No company or actual publisher identity is inferred from the product name. `displayName` must be the reserved app display name.

The script checks required values, rejects placeholders, and asks Windows `PackageFamilyNameFromId` to derive the family from name/publisher. It must match the copied family name. This checks consistency, **not account ownership or reservation**. Browser evidence must establish those separately. [Microsoft package identity guidance](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/package-identity-overview).

```powershell
python scripts/windows-store/build_msix.py `
  --identity .local/rymu-partner-center-identity.json `
  --runner apps/native/flutter/build/windows/x64/runner/Release `
  --version 1.0.14.0 `
  --output artifacts/windows-store/Rymu-Windows-x64-1.0.14.0-StoreCandidate-Unsigned.msix
```

If account identity is unavailable, the following explicit mode creates only a synthetic local qualification artifact. Its filename, manifest, display name, and evidence identify it as such. **Never upload this identity to Partner Center or offer it as the customer installer.**

```powershell
python scripts/windows-store/build_msix.py `
  --local-test-identity `
  --runner apps/native/flutter/build/windows/x64/runner/Release `
  --version 1.0.14.0 `
  --output artifacts/windows-store/Rymu-Windows-x64-1.0.14.0-LocalQualification.msix

python -m unittest discover -s scripts/windows-store -p test_identity.py -v
```

Outputs cannot overwrite earlier artifacts or evidence. Use a new version/output name after changing any payload. The build retains a unique `.local/rymu-msix-*` stage and unpack folder for inspection and creates an adjacent `.evidence` folder with the exact manifest, command logs, hashes, and report. It does not regenerate the Flutter/Rust binaries: build those first, wait for the build to finish, and pass that stable final runner. Input files are hashed again after packaging to reject an input changed mid-build.

## Package decisions

- Windows 11 x64: `Windows.Desktop`, minimum 10.0.22000.0, maximum tested schema/SDK target 10.0.26100.0. The manifest field does not claim actual OS runtime testing.
- Application ID `Rymu`, executable `Rymu.exe`, `uap10:RuntimeBehavior="packagedClassicApp"`, `uap10:TrustLevel="mediumIL"`, restricted capability `runFullTrust`. This preserves the normal desktop process model required for screen capture and input. No service, driver, elevation, injection, external MSI bootstrap, or registry-virtualization exemption is added. Microsoft still reviews this capability. [Application schema](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-f-application).
- Complete runner copied at package root, including Flutter/plugin/Rust DLLs, `data/app.so`, ICU, fonts, assets, `NOTICES.Z`, and `RUSTDESK-AGPL.txt`. The Flutter `DartProject` header expressly resolves its `data` path relative to the executable, so no current-directory workaround is needed.
- Visual assets derive deterministically from the approved `design/assets/rymu-windows.ico`: Store 50, square 44/150, and unplated target-size 24/32/48/256 PNGs. No new logo is introduced.
- `desktop:StartupTask` ID **`RymuStartup`**, `Enabled="false"`, normal `Rymu.exe`, no command-line arguments. The package-aware native settings control enables/disables the task using Windows' API and respects a user/policy disable. It runs after Windows user sign-in, not before login. Host consent and saved account restoration remain separate application requirements. No hidden immediate-registration restriction/capability is used. [StartupTask schema](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-desktop-startuptask).
- No custom URI registration: the existing Windows Google flow uses HTTP loopback `http://127.0.0.1:49383/callback`; Android's callback scheme is not copied into Windows.
- Only an unsigned `.msix` is produced. No fabricated `.msixupload`, certificate, or Store signature. Microsoft documents that Store distribution does not require the developer to sign the MSIX themselves; the Store signs during its own pipeline. The local artifact is not independently trusted. It does not add the special unsigned-install OID or use `Add-AppxPackage -AllowUnsigned`. [Microsoft signing guide](https://learn.microsoft.com/windows/msix/package/sign-msix-package-guide).

## Per-build checks and their limits

1. Require executable, native DLL, Flutter engine, Dart AOT data, ICU, manifests, and licenses; reject reparse points and obvious credentials/debug/installer extras.
2. Audit every PE payload with `dumpbin /dependents`; require AMD64. Report ASLR/NX flags and all static/delay imports. Resolve imports against root package DLLs, build-machine System32, or API-set names. Fail unbundled VC runtime imports even if this developer PC happens to have those DLLs: the manifest does not declare a VC framework dependency. This cannot establish dynamic `LoadLibrary`, driver, GPU, screen-capture, audio, or all fresh-machine availability.
3. Use `MakeAppx pack` with full semantic validation, SHA256 blockmap, and no overwrite. **No `/nv` or `/nfv` bypass.** Then use `MakeAppx unpack` and compare SHA256 for every staged file, including the manifest and branding. Check expected package metadata and absence of `AppxSignature.p7x`. [MakeAppx documentation](https://learn.microsoft.com/en-us/windows/msix/package/create-app-package-with-makeappx-tool).
4. Rehash the source runner and require unchanged input; write the artifact SHA256, exact commands/exit codes, and pass/fail state. `storeReady`, `installed`, `activated`, `submitted`, and `signed` remain false.

The installed Windows App Certification Kit was discovered at `C:/Program Files (x86)/Windows Kits/10/App Certification Kit`; only its documented help was invoked. **No WACK test passed or failed in this work.** Full WACK testing requires a deployed app and includes activation/runtime behavior. It must run on a separate clean test machine or isolated VM after a properly authorized signing/deployment strategy is available. MakeAppx is a packaging validator, not a substitute for WACK. [WACK prerequisites and workflow](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-app-certification-kit).

## Runtime and migration audit

The package installation directory is immutable. The account vault already writes to `LOCALAPPDATA/Rymu/Control/account.dat` and is DPAPI-protected; this must not be moved into the package directory. MSIX file/registry virtualization can alter where new AppData files are stored, while existing outside-package files can behave differently. Login persistence or uninstall cleanup cannot be proved by source review. No claim is made that package-private data automatically migrates to/from the existing MSI. [Packaged desktop runtime and virtualization](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes).

The startup extension replaces the MSI's HKCU Run integration only in the packaged process. The existing MSI's exact-path registration/Finish logic is preserved. Package startup needs both first-use consent and a subsequent real Windows sign-in test. A reboot is not performed on the owner's live remote host.

Both channels currently share the `Rymu` window class/title and fixed loopback callback port 49383. If the MSI is already running, package launch may restore it or the sign-in callback port may be occupied. **Do not claim side-by-side support.** Qualification must use a clean Windows account/VM with only one channel active; a migration design must explicitly handle preserved account data, duplicate startup entries, and single-instance routing before advertising an MSI-to-Store upgrade path.

The native API has a normal desktop DLL search dependency on `librustdesk.dll`, bundled alongside `Rymu.exe`. The package's immutable root protects those installed files, but dynamic resolution and actual startup remain runtime tests. The preexisting remote-control/security/physical-screen privacy limitations remain unchanged by packaging.

## Recorded baseline audit (old runner, not final Store runner)

The 0.1.12.0 audit was deliberately built before the native 0.1.13 package-aware startup changes. It proves the packaging route accepts the existing payload; it does not prove the startup branch exists in that binary.

- Artifact: `artifacts/windows-store/Rymu-Windows-x64-0.1.12.0-LocalQualification-Audit.msix`.
- Bytes: **35,698,013**; SHA256: `5ed6545141b3cb5baae3989f530d6159c01c48113dc0ed8430825e3a8e8af84d`.
- **92 runtime files**, **100 total staged files**; all hashes matched after unpack and source runner was unchanged.
- **14 AMD64 PE files**, each with ASLR/NX flags enabled; no unresolved static import on this build machine. `data/app.so` is Dart AOT data, not a PE executable in this runner.
- MakeAppx pack and unpack both exited 0. Package unsigned, no install/activation, no WACK result.
- Full machine-readable evidence in the adjacent `.evidence/report.json`.

## Remaining release gates

The real Partner Center product identity is obtained and checked, and the final native runner has been packaged. Archive corresponding source including build scripts, then qualify install/launch, Google/email sign-in, saved-session recovery, task enable/disable and user override, real logoff/reboot, tray Close/Quit, screen control/audio/privacy restoration, update/uninstall, and MSI migration on a clean Windows 11 test machine. Run WACK and address actual failures. Confirm Store listing/privacy/support/age-rating answers and restricted-capability rationale against implemented behavior before submission. None of these runtime/certification steps is implied by identity reservation or a successful ZIP/MSIX build.

## Final real-identity candidate — 1.0.14.0

The parent marked the native 0.1.14 runner stable after the fresh Rust and Flutter builds (`artifacts/logs/windows-0.1.14-native-build.log` and `windows-0.1.14-flutter-build.log`). The following package was then built from that unchanged runner using `.local/rymu-partner-center-identity.json`:

- Artifact: `artifacts/windows-store/Rymu-Windows-x64-1.0.14.0-StoreCandidate-Unsigned.msix`.
- Bytes: **35,727,366**.
- SHA256: `e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4`.
- Identity: `HusseinMlhem.Rymu`, publisher `CN=F9C1B031-E95E-4F61-9D33-FEFE22907F92`, version **1.0.14.0**, x64.
- MakeAppx pack and unpack exited **0**, with semantic validation enabled.
- **92 runtime files / 100 staged files**; every unpacked payload hash matched; source runner rehash was unchanged.
- **14 AMD64 PE files**; all report ASLR and NX compatibility. No unresolved static dependency and no unbundled VC runtime import was found on this build machine.
- Package remains **unsigned**, **not installed**, **not activated**, **not submitted**, and **not certified**. No WACK execution or owner-machine trust modification occurred.

| Component | SHA256 |
| --- | --- |
| Rymu.exe | `63c10fd125823ccf0a982ac17f6b3acd551937724754f10da119f048c3320548` |
| librustdesk.dll | `d925ffa5a74e786b1d9630c9066dbb1046258d8eb378bff770cd831264e0fa2d` |
| data/app.so | `1d9c6a3b6cf56cf5691021875dfa417d8d81fe98c27feeb202e423c8bf9a3b63` |

The adjacent `.evidence/report.json` includes every file hash, tool/script hashes, exact manifest, commands/exit codes, and runtime limitations. This candidate is for the reserved Store product; public website downloads remain a separate MSI/APK release operation and do not make this unsigned MSIX a customer installer.
