# Screen privacy qualification — November 6, 2026

Scope: same-process physical-screen covers for an authenticated Rymu control session. Do not conflate source implementation, local backend tests and an actual phone-to-PC session. The final three production-backend desktop component tests passed on November 6 at 14:51 Dubai time; packaging and publication are recorded separately by the release owner.

## Platform evidence

Microsoft supports `WDA_EXCLUDEFROMCAPTURE` from Windows 10 version 2004 (build 19041), on top-level windows owned by the calling process while DWM is composing. Earlier Windows versions behave differently. The API does not establish a security boundary against every capture mechanism. [SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)

The host uses the pinned `scrap::Capturer` DXGI implementation, which can fall back to GDI. GPU duplication returns the composed desktop image; rotation is handled per monitor. Qualify the exact capture path instead of assuming that successful window affinity means the controller can still see its image. [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)

## Completed preliminary workstation probe

`scripts/qa/privacy-capture.py --run --capture-only` builds with the pinned Rust 1.75 toolchain and the same cached `scrap` library as the Windows host. It displays only small synthetic marker windows, covers each with an opaque topmost layered, click-through, capture-excluded window, changes the marker behind that window and checks the exact marker pixels through DXGI. It then destroys the cover and checks a new marker frame. No desktop screenshot or unrelated screen pixels are saved or printed.

The actual three attached displays passed this capture/opaque-window probe, including the rotated display. This was a real local GPU capture of synthetic content, not a remote session or proof of the production lifecycle.

- `artifacts/logs/privacy-capture-synthetic.log`
- `artifacts/logs/privacy-capture-build.json`

## Input-delivery diagnostic

An initial synthetic input probe failed even without any privacy overlay. `WindowFromPoint` resolved the intended test HWND, the transformed point was in `HTCLIENT`, the target was enabled, direct callback delivery worked, and the cursor moved, but injected button messages did not reach the marker. Separate down/up events, per-monitor DPI awareness and the native Enigo input tag did not change that result. A Computer Use click on the observed green client area also returned without a recorded marker click. A final bounded `AttachThreadInput` diagnostic obtained the target foreground window and then restored the previous foreground/attachment, but button injection still failed. No unrelated application settings, security settings or global hooks were changed.

This result does not establish an overlay regression, because the baseline fails, but it must not be described as a successful real pointer test. The failure record is preserved in `artifacts/logs/privacy-capture-input-probe.log`. Full mouse delivery to a genuine remote peer remains a separate qualification.

## Exact production-backend component tests

`apps/native/src/rymu/privacy_tests.rs` is compiled only in the native test target. `scripts/qa/privacy-native-tests.py` accepts an exact built test executable and requires `--run-desktop`; it never starts fullscreen checks implicitly. Each test is supervised with a fixed timeout. The helper process used for crash testing has its own 20-second cleanup fallback. All generated windows and input targets belong to the test process.

Completed checks on the actual production backend compiled into the native test executable:

1. Actual `PrivacyModeImpl` covers every monitor with its exact physical bounds, opaque paint and expected affinity. DXGI captures changing synthetic markers underneath. Wrong-session removal fails; correct-session removal and object destruction restore the screen and capture.
2. The emergency shortcut is registered, and dispatching its actual Windows hotkey message executes production stop/cleanup. Ownership stays with the session until explicit connection cleanup; the final assertion verifies that behavior. This is component message dispatch, not a claim that a physical keyboard or real authenticated session was exercised.
3. Terminating the process that owns the production covers removes every cover HWND, without changing monitor topology, installing a driver or depending on another cleanup process.

The local overlay does not cover the Windows secure desktop. Stable unlocked desktop and monitor layout are the supported scope. Hotplug, UAC/lock transitions and pre-logon access require their own qualification; no promise that every privileged or independently topmost window can never surface is made from this probe.

The first bare Rust test EXE correctly failed the Windows-version requirement before showing a cover, because it did not have the Flutter runner's Windows10 compatibility manifest. The wrapper now embeds the exact existing `runner.exe.manifest` into a separate copy of that test EXE, verifies its `.text` machine-code digest remains unchanged and reads the manifest resource back byte-for-byte. This matches the actual application manifest without changing the production capability check. The SDK manifest tool timed out before testing; the wrapper uses Windows' resource-update API on the test-owned copy.

The initial two-case production run is preserved in `artifacts/history/privacy-native-physical-initial.log` and `.json`. The final run used native test executable SHA-256 `f22b3349d6b74cc7ec04387050fe602744e0038e51814a08366bb00a0087fd59`; its unchanged machine-code section SHA-256 is `1d67abbe5e4f48c14457d151cbd83a5f51861cb24de2bbece23595a44cd567d6` after embedding the app manifest.

All final cases passed: three-monitor capture/coverage/off/Drop in 1.26 seconds, emergency hotkey dispatch in 0.09 seconds, and process-termination cleanup in 0.09 seconds. No lingering cover windows or test helper processes remained. See `artifacts/logs/privacy-native-physical.log` and `.json`. These exercise the real Windows backend with synthetic targets and component session identifiers; they do not assert that network disconnect/revocation or phone input was exercised against an authenticated peer.
