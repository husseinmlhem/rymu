# Exact Store payload: disposable Server registration smoke

Manual workflow mode `store-msix-smoke`, standard `windows-2025`, 40-minute job limit. Source-build mode/default and its concurrency-group value are preserved; Store smoke has a distinct concurrency group and cannot cancel the source build.

Input is the exact submitted unsigned MSIX 1.0.14.0, 35,727,366 bytes, SHA256 `e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4`. The reviewed JSON pins all 100 extracted payload files. No binary or credential is checked into this repository.

1. An authorized publisher may attach that file, under its exact filename, to an **unpublished draft** release in `husseinmlhem/rymu`. Supply its numeric release and asset IDs to the manual workflow. Never publish the draft as a download workaround.
2. The job has only `contents: read`. Its first external data operation validates the repository is public, release is still draft, and asset metadata is exact. GET asset supports direct 200 or a single approved GitHub storage redirect without forwarding authorization. A permission failure stops the job before certificates/installation; there is no token escalation or public fallback.
3. On disposable Server 2025 only, verify the original archive and 100 payload hashes. Test-sign a **copy** using a short-lived, nonexportable private key in the job user's My store and a public certificate in that VM's TrustedPeople store. Do not touch Trusted Root. The signature changes the envelope, not the submitted payload.
4. Verify the signed copy/payload, register it for the current job user, read package identity/status, then uninstall. Do not launch the app, log in, activate hosting, test a peer, modify its settings or use owner credentials. Remove only the just-created trust/key entries. The disposable VM is discarded even on failure.
5. Emit bounded JSON to console only. No artifact upload, PFX/private-key export, signed-copy publication, paid runner or billing setting. Probe AppCert file presence, but do not run it or describe Server registration as WACK/Windows 11 qualification.

`Validate` and `test_store_msix_smoke.ps1` are safe local configuration/pure guard checks; Download/Install reject a local environment before mutation. Windows PowerShell 5.1 runs Install because it hosts the native Appx cmdlets. All CI changes are separately hashed in source-baseline ciInputs. Original archive hashes/source overlays and the one-workflow allowlist remain intact.

The draft token's actual visibility is established only by a real dispatched Download step, not the publisher's local gh credentials. If it fails, report that limitation and stop that transfer route. No result should be called passed until the actual Get-AppxPackage and removal checks succeed.

## Separately authorized public-payload reconstruction

The real read-only draft metadata request was unavailable in run 42817080633. Permissions were not broadened and the draft was not published. A separately authorized `package_input=public-msi-payload` mode avoids private transfer entirely:

- An anonymous request downloads only the existing immutable public 0.1.14 MSI, pinned to 36,651,008 bytes and SHA256 `bd7a1ce138be3adf6f54fce8d9ba989f56eac8cfa5efe5f7b4e03deb15b41174`. Redirects, different lengths/hashes and overlong transfers fail closed. No token, account or cookie is supplied.
- Read-only Windows Installer database APIs and `expand.exe` extract the embedded cabinet; no installer/custom action is invoked. The unchanged reviewed `test-windows-msi.py` additionally checks its tables and all 92 runtime files without `--round-trip`.
- Eight Store-only inputs in `store-payload-assets/` are exact bytes extracted from the submitted MSIX: its manifest and seven PNGs, 38,532 bytes total. Their hashes and every runtime hash must match the original 100-file expectation.
- MakeAppx packs/unpacks that payload. The exact root `AppxBlockMap.xml` is SDK metadata outside those 100 files; its 100 references, SHA256 blocks and whole-file hashes are independently checked. All other unexpected extracted files are rejected except the exact signature footprint in the signed-copy check.
- The existing disposable signing/registration/uninstall safeguards then apply. Evidence explicitly says **payload-identical reconstruction**, `exactSubmittedArchiveTested=false`; it records the reconstructed envelope hash separately from the original reference hash. This is not an exact-archive, native app activation, peer, Windows 11 or WACK test.

Both paths preserve the original draft, source workflow and owner device. Reconstructed and signed packages, certificates and keys are never uploaded.
