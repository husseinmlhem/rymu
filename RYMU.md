# Rymu

Rymu is Hussein Mlhem's Windows and Android remote-access application, derived from [RustDesk](https://github.com/rustdesk/rustdesk) under AGPL-3.0. The upstream README, license and copyright notices are preserved. This is the Rymu fork, not an upstream RustDesk release.

## Current public release

[Download Windows 0.1.16 and Android 2077](https://github.com/husseinmlhem/rymu/releases/tag/windows-v0.1.16-android2077). Windows 0.1.16 adds an enabled Cancel sign-in action while the browser or account service is pending, safe retry, and rejection of late canceled enrollment responses. Android 1.5.1 build 2077 is unchanged and release-signed. The Windows MSI is **unsigned**. These are public preview downloads: account creation currently requires an invitation and managed internet access is enabled for the platform owner only. Microsoft Store approval is not established by this release.

The release includes its corresponding source ZIP and SHA-256 checksums. The ZIP embeds Android 2077's exact original source archive, because the Android binary was not rebuilt. [Source record](rymu-release/releases/0.1.16/SOURCE-RECORD.json), [build provenance and limitations](rymu-release/releases/0.1.16/PROVENANCE.json), [Arabic Windows build notes](rymu-release/releases/0.1.16/WINDOWS_RELEASE_AR.md).

The Windows MSI was built locally from the tested 0.1.16 Flutter/C++ source with the production HTTPS account API. Its frozen 0.1.14 Rust DLL was reused only after 393 Rust/TOML/lock inputs were verified unchanged. The 16 relevant Flutter tests, 110 MSI payload hashes, 12 installer Finish scenarios and 7 executable argument guards passed. This is not a new CI build, clean-machine installation, physical reboot, WACK certification or real-peer session claim.

## Source and builds

This branch descends from the previously published CI commit 78628b3 and upstream commit 23e5bb471a040d62f0a6ad52591fb30784265b73; hbb_common remains the gitlink fae47e024dd83cef6aaecde0aa7d11731df11649. All 1,193 native files were compared with the release source archive. The only native-root layout difference is the documented privacy test helper import; original upstream workflows are preserved under rymu-release/upstream-workflows.

The original 0.1.14 archive hash mapping stays immutable in the baseline verifier. Reviewed source overlays pin the publisher attribution, test-helper relocation and 0.1.16 sign-in fix with before/after/patch hashes. New test and release support files are explicitly allowlisted.

The [manual Windows workflow](.github/workflows/rymu-windows-ci.yml) builds from this native-root checkout. It only runs on explicit workflow_dispatch; nothing signs or publishes automatically. Its artifact upload remains disabled by default. No workflow was dispatched for this publication. The workflow now includes the new cancellation tests, but that updated workflow has not itself been executed. For the original workspace-layout local build helpers, use the attached corresponding source ZIP and its instructions.

Previous [engineering CI run 42812117630](https://github.com/husseinmlhem/rymu/actions/runs/42812117630) qualified the earlier 0.1.15 source; it must not be represented as a build of this new commit or of the attached local MSI. Third-party licensing and binary provenance limits remain documented. No signing certificate or sponsorship is claimed. No paid signing service is enabled.

- [Official website](https://rymu.iptvora-server.workers.dev/)
- [Downloads](https://rymu.iptvora-server.workers.dev/downloads)
- [Privacy policy](https://rymu.iptvora-server.workers.dev/privacy)
- [License](LICENCE)

Maintainer: Hussein Mlhem â€” [www.husseinmlhem.com](https://www.husseinmlhem.com), [h-m.agency](https://h-m.agency).
