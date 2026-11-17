# Corresponding source: Windows 0.1.16 and unchanged Android 2077

This combined archive is local release preparation. It does not establish that Windows 0.1.16 was published or submitted to Microsoft Store. The live public release checked on 2026-11-17 was Windows 0.1.15 and Android 2077.

The outer `Rymu/apps/native` tree corresponds to the tested Windows 0.1.16 changes: cancel an unfinished sign-in, release its callback listener, ignore late canceled results and allow retry. Its two Windows Dart files and added regression test match the exact source hashes in `artifacts/windows/windows-0.1.16-release.json`. The actual build, 16 component tests and package checks are described in `WINDOWS_RELEASE_0.1.16_2026-11-12_AR.md`. No new application build or runtime session is claimed by this source-packaging step.

## Exact Android source is retained separately

The public Android APK remains version 1.5.1, code 2077, 71,037,692 bytes, SHA-256 `5d112a9d2fdc53625d42abf389a5349857f5b669a0a613011d391ec70b340497`. It was not rebuilt, re-signed or version-bumped for this release.

Although the new behavior is Windows-specific, the existing Android Flutter compiler evidence includes `windows_account.dart` and `windows_home.dart`: `main.dart` imports the Windows home module. Therefore the outer updated tree is not described as identical to the original Android compiler inputs.

For Android 2077, extract the nested archive under `Rymu/android-2077-original-source/` into a **separate folder** and use its own `Rymu/apps/native` tree and included Android build scripts. The nested archive is the exact earlier corresponding source, `Rymu-Native-Public-0.1.14-2077-Source.zip`, 9,458,740 bytes, SHA-256 `2a4fc09c72fd6760c99dedf9443d34800aabbbea58af46f7c4e56285d8d2cd3a`. It includes the original generated bridges and pinned native dependency source. Its recorded source/build correspondence remains in `artifacts/logs/android-public-2077-source-parity.json` and `android-public-2077-source-parity-compiler.json` in the main workspace.

This separation preserves the exact original Android source while delivering the newer Windows source in one downloadable archive. It does not claim a byte-reproducible signed APK or include a signing private key. The internal review-endpoint APK built on 2026-11-12 is a separate debug-signed test artifact and is not the public Android release covered here.

## Verification and preservation

The packaging helper uses a temporary Git index, verifies that the canonical patch reconstructs the outer native tree, checks recorded hashes and CRCs, and refuses to replace an existing archive. The nested Android source is also checked entry by entry, including its record, path restrictions and credential-marker exclusions. Both original Git indexes, the previous patch, the previous verification record and existing immutable release files are preserved; the old patch and verification record are backed up before updating the current canonical patch.

The independent final audit is `artifacts/logs/public-source-0.1.16-2077-audit.json`. Existing public catalog binaries and their old source ZIPs must remain available for historical immutable download URLs. The new combined source can be linked to the unchanged Android APK because it contains its exact original source, not because the outer Windows tree is claimed to be identical.

No production/account settings, Android keystore, Store submission, installation or real peer session is changed by this work. Existing third-party license/provenance and physical runtime qualification limits remain as recorded in the release documentation.
