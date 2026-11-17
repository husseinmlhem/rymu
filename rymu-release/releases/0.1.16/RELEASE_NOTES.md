Windows 0.1.16 fixes cancellation of browser sign-in: Cancel remains available during pending requests and device enrollment, retry is offered, and late canceled responses cannot replace saved credentials. Android 1.5.1 build 2077 is the unchanged release-signed ARM64 APK.

**Public preview:** the Windows MSI is unsigned and may trigger SmartScreen. Account creation currently requires an invitation; managed internet connections remain owner-only. This release does not establish Microsoft Store approval. No internal review APK or Store MSIX is included.

Assets:
- Windows x64 MSI 0.1.16 (unsigned).
- Android ARM64 APK 1.5.1 (2077), release-signed.
- Corresponding source ZIP, including the exact original source for unchanged Android 2077.
- SHA256SUMS.txt for all three files.

Validation: 3 new cancellation tests + 13 existing Windows lifecycle tests passed, with the final guards retested; analyzer clean. All 110 MSI payload hashes, 12 installer Finish scenarios and 7 executable argument guards passed. Flutter/C++ was built locally; the exact frozen native DLL was reused after 393 unchanged Rust/TOML/lock input checks. No new CI run, real-peer session, clean-machine installation, reboot or WACK certification is claimed.

[Build provenance](https://github.com/husseinmlhem/rymu/blob/codex/public-0.1.16-android2077/rymu-release/releases/0.1.16/PROVENANCE.json) · [Arabic build notes](https://github.com/husseinmlhem/rymu/blob/codex/public-0.1.16-android2077/rymu-release/releases/0.1.16/WINDOWS_RELEASE_AR.md) · [Website](https://rymu.iptvora-server.workers.dev/)

العربية: إصدار ويندوز 0.1.16 يضيف إلغاء تسجيل الدخول أثناء الانتظار وإعادة المحاولة بأمان؛ أندرويد 2077 لم يتغير. مثبت ويندوز غير موقّع. التنزيل عام، لكن التسجيل بالدعوة والاتصال الخارجي المُدار لحساب المالك حالياً. لا ندّعي اعتماد المتجر أو نجاح جلسة تحكم حقيقية جديدة بهذا الإصدار.
