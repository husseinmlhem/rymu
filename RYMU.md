# Rymu

Rymu is Hussein Mlhem's Windows and Android remote-access application, derived from [RustDesk](https://github.com/rustdesk/rustdesk) under AGPL-3.0. The upstream README and license notices are retained. This fork's qualification work is described here; it is not an upstream RustDesk release.

The imported application source is the already-published Windows 0.1.14 / Android 2077 source archive, SHA-256 `2a4fc09c72fd6760c99dedf9443d34800aabbbea58af46f7c4e56285d8d2cd3a`. Its upstream base is `23e5bb471a040d62f0a6ad52591fb30784265b73`, native tree `88a3f90f3e2bf4d7d684b7d43476f4b069307fb8`, and hbb_common submodule `fae47e024dd83cef6aaecde0aa7d11731df11649`. Git may normalize the archive's recorded CRLF text (including legacy text encodings) to LF; the verifier permits only that documented conversion.

- [Official application website](https://rymu.iptvora-server.workers.dev/)
- [Released Windows installer](https://rymu.iptvora-server.workers.dev/api/v1/releases/latest/windows-installer)
- [Released corresponding source](https://rymu.iptvora-server.workers.dev/api/v1/releases/latest/source)
- [License](LICENCE) and [published source record](rymu-release/SOURCE-RECORD.json)

The manual [Windows CI workflow](.github/workflows/rymu-windows-ci.yml) is a new qualification recipe. It bootstraps hash-locked tools, builds Rust/Flutter, runs focused tests and packages an unsigned MSI. Its default 0.1.15 version is an **unpublished qualification candidate**, not a claim that a new release exists. Follow actual workflow results; static validation is not a completed build or remote-session test. Existing application access restrictions and authentication remain in force.

No workflow signs or publishes a release. SignPath Foundation acceptance has not been granted, and no code-signing sponsorship or certificate is claimed. Publisher metadata, component provenance, upstream signing lineage and final runtime qualification remain review items before a signed release.

Only the Rymu workflow is active in the qualification branch. Original upstream workflows are preserved under `rymu-release/upstream-workflows/` for reference. Generated bridge files from the public archive are retained without unpinned code generation. The baseline verifier checks exact imported source bytes and reviewed CI files.

Use a public repository with the standard `windows-2022` runner. Uploading artifacts is off by default and must be enabled only after checking the account's included artifact-storage allowance; enabled artifacts expire after one day. No paid runner, cache service or signing subscription is configured.
