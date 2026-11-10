# Exact Store payload: disposable Server registration smoke

Manual workflow mode `store-msix-smoke`, standard `windows-2025`, 40-minute job limit. Source-build mode/default and its concurrency-group value are preserved; Store smoke has a distinct concurrency group and cannot cancel the source build.

Input is the exact submitted unsigned MSIX 1.0.14.0, 35,727,366 bytes, SHA256 `e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4`. The reviewed JSON pins all 100 extracted payload files. No binary or credential is checked into this repository.

1. An authorized publisher may attach that file, under its exact filename, to an **unpublished draft** release in `husseinmlhem/rymu`. Supply its numeric release and asset IDs to the manual workflow. Never publish the draft as a download workaround.
2. The job has only `contents: read`. Its first external data operation validates the repository is public, release is still draft, and asset metadata is exact. GET asset supports direct 200 or a single approved GitHub storage redirect without forwarding authorization. A permission failure stops the job before certificates/installation; there is no token escalation or public fallback.
3. On disposable Server 2025 only, verify the original archive and 100 payload hashes. Test-sign a **copy** using a short-lived, nonexportable private key in the job user's My store and a public certificate in that VM's TrustedPeople store. Do not touch Trusted Root. The signature changes the envelope, not the submitted payload.
4. Verify the signed copy/payload, register it for the current job user, read package identity/status, then uninstall. Do not launch the app, log in, activate hosting, test a peer, modify its settings or use owner credentials. Remove only the just-created trust/key entries. The disposable VM is discarded even on failure.
5. Emit bounded JSON to console only. No artifact upload, PFX/private-key export, signed-copy publication, paid runner or billing setting. Probe AppCert file presence, but do not run it or describe Server registration as WACK/Windows 11 qualification.

`Validate` and `test_store_msix_smoke.ps1` are safe local configuration/pure guard checks; Download/Install reject a local environment before mutation. Windows PowerShell 5.1 runs Install because it hosts the native Appx cmdlets. All CI changes are separately hashed in source-baseline ciInputs. Original archive hashes/source overlays and the one-workflow allowlist remain intact.

The draft token's actual visibility is established only by a real dispatched Download step, not the publisher's local gh credentials. If it fails, report that limitation and stop. No result should be called passed until the actual Get-AppxPackage and removal checks succeed.
