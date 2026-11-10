# Privacy build reproduction

The corresponding source archive contains native tree `906210220daba608be842f78793d2deedfe0c71d`, pinned upstream/submodule, the generated bridge, Windows build tools and the privacy qualification scripts. Follow `WINDOWS.md`, `ANDROID.md` and their pinned toolchain prerequisites; no generated bridge regeneration is needed. Build scripts expect the repository on C: with local SDKs as documented.

Use `python scripts/windows-native.py build --hosted` for the final Windows library and `python scripts/windows-native.py test --hosted` for the focused native suite. Set `RYMU_ACCOUNT_API_BASE` to the already authorized account API before `node scripts/windows-flutter.mjs build`. The hosted API in these owner packages is `https://rymu.iptvora-server.workers.dev/api/v1`.

The installer recipe is `python scripts/emit-windows-msi.py <verified-runner-directory> <output.wxs> --version 0.1.10`, followed by WiX 3.14.1 `candle.exe` and `light.exe` with the generated source. Use `scripts/test-windows-msi.py` to compare the extracted payload with the runner. Preserve the upgrade identity and do not add a service or custom action. The root build/verification manifests record exact runner, library, AOT and installer hashes; an unsigned development MSI is not a signed public release.

For Android, use the pinned ARM64 native/Flutter/SDK/NDK versions in `ANDROID.md`, version name 1.5.1 and version code 2076. The old and new APKs share the development signer for owner-test upgrade only. Do not treat that signer as public release signing.

Run `flutter test test/rymu_screen_privacy_test.dart test/rymu_mobile_viewport_test.dart test/rymu_remote_keyboard_test.dart` in `apps/native/flutter` for the changed Flutter behavior. The native client acknowledgement regression is selected separately by `rymu_privacy_is_acknowledged_without_replaying_a_saved_preference` in the compiled native test executable.

`python scripts/qa/privacy-native-tests.py --executable <native-test-exe>` verifies test discovery only. Append `--run-desktop` only when brief fullscreen cover tests on the active workstation are authorized. The wrapper embeds the same production Windows compatibility manifest into a separate test-owned copy, checks unchanged machine code and exact manifest readback, and supervises each component test. It does not install a driver or change the screen layout. The component test source includes `scripts/qa/privacy-capture.rs` relative to the repository root; retain that archive layout.

Raw injected-button delivery failed even on the uncovered synthetic baseline in the recorded environment. Do not convert that diagnostic to a pass or conflate component capture/cleanup with an authenticated phone session. See `PRIVACY_VALIDATION_2026-11-06.md`.
