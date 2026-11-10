[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Bootstrap', 'Build', 'Test', 'Package', 'Evidence')]
    [string]$Stage = 'Validate',
    [ValidatePattern('^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,5}$')][string]$Version = '0.1.15'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$native = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$release = Join-Path $native 'rymu-release'
$out = Join-Path $release 'out'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain-lock.json') -Raw | ConvertFrom-Json
$parts = $Version.Split('.')
if ([int]$parts[0] -gt 255 -or [int]$parts[1] -gt 255 -or [int]$parts[2] -gt 65535) { throw 'MSI version is outside its supported range.' }
foreach ($item in $lock.downloads.PSObject.Properties.Value) {
    if ($item.sha256 -notmatch '^[a-f0-9]{64}$' -or ([Uri]$item.url).Scheme -ne 'https') { throw 'Invalid hash-locked tool input.' }
}
foreach ($file in @('Cargo.lock', 'Cargo.toml', 'vcpkg.json', 'src/bridge_generated.rs', 'src/bridge_generated.io.rs', 'flutter/lib/generated_bridge.dart', 'flutter/lib/generated_bridge.freezed.dart', 'libs/hbb_common/Cargo.toml', 'rymu-release/scripts/emit-windows-msi.py', 'rymu-release/scripts/test-windows-msi.py', 'rymu-release/design/installer/rymu-ui.wxi')) {
    if (!(Test-Path -LiteralPath (Join-Path $native $file) -PathType Leaf)) { throw "Required published source is missing: $file" }
}
$vcpkgManifest = Get-Content -LiteralPath (Join-Path $native 'vcpkg.json') -Raw | ConvertFrom-Json
if ($vcpkgManifest.'vcpkg-configuration'.'default-registry'.baseline -ne $lock.vcpkgCommit) { throw 'vcpkg baseline differs from the reviewed toolchain lock.' }
if ($Stage -eq 'Validate') {
    [ordered]@{ status = 'preflight-passed'; source = $native; version = $Version; toolInputs = 4; buildExecuted = $false } | ConvertTo-Json
    return
}

# Mutating stages are for the disposable standard GitHub runner, never the owner's PC.
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or !$env:RUNNER_TEMP) { throw 'Build stages require a GitHub-hosted Windows runner.' }
if ($env:RYMU_LOCAL_BUILD -eq '1') { throw 'Local account-transport mode is forbidden in this qualification build.' }
$toolsRoot = Join-Path $env:RUNNER_TEMP "rymu-tools-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$flutterRoot = Join-Path $toolsRoot 'flutter'
$flutter = Join-Path $flutterRoot 'bin/flutter.bat'
$wix = Join-Path $toolsRoot 'wix'
$vcpkg = Join-Path $toolsRoot 'vcpkg'
$runner = Join-Path $native 'flutter/build/windows/x64/runner/Release'
$env:CARGO_HOME = Join-Path $toolsRoot 'cargo-home'
$env:RUSTUP_HOME = Join-Path $toolsRoot 'rustup-home'
$env:RUSTUP_TOOLCHAIN = $lock.rust
$env:CARGO_TARGET_DIR = Join-Path $native 'target'
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
$env:CARGO_INCREMENTAL = '0'
$env:LIBCLANG_PATH = Join-Path $toolsRoot 'libclang/libclang-15.0.6.data/platlib/clang/native'
$env:PUB_CACHE = Join-Path $toolsRoot 'pub-cache'
$env:VCPKG_ROOT = $vcpkg
$env:VCPKG_INSTALLED_ROOT = Join-Path $vcpkg 'installed'
$env:VCPKG_DOWNLOADS = Join-Path $toolsRoot 'vcpkg-downloads'
$env:VCPKG_DEFAULT_BINARY_CACHE = Join-Path $toolsRoot 'vcpkg-cache'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:VCPKG_DISABLE_METRICS = '1'
$env:VCPKG_BINARY_SOURCES = 'clear'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$env:PATH = (Join-Path $flutterRoot 'bin') + [IO.Path]::PathSeparator + $env:PATH
New-Item -ItemType Directory -Path (Join-Path $out 'logs') -Force | Out-Null

function Invoke-Checked([string]$File, [string[]]$ArgumentList) {
    & $File @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" }
}
function Download-Locked([string]$Name) {
    $item = $lock.downloads.$Name
    $target = Join-Path $toolsRoot $item.filename
    Invoke-WebRequest -Uri $item.url -OutFile $target -TimeoutSec 900
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) { throw "$Name archive hash differs; refusing to execute it." }
    return $target
}
function Require-Passed([string]$Previous) {
    $record = Join-Path $out "$Previous.passed.json"
    if (!(Test-Path -LiteralPath $record)) { throw "Required stage has not passed: $Previous" }
    $value = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if ($value.version -ne $Version -or $value.runId -ne $env:GITHUB_RUN_ID) { throw 'A prerequisite belongs to another qualification build.' }
}
function Write-DiskState([string]$Label, [double]$MinimumGiB = 0) {
    $drives = @([IO.Path]::GetPathRoot($native), [IO.Path]::GetPathRoot($toolsRoot)) | Select-Object -Unique
    foreach ($drive in $drives) {
        $free = (Get-PSDrive -Name $drive.TrimEnd('\').TrimEnd(':')).Free / 1GB
        [ordered]@{ checkpoint = $Label; drive = $drive; freeGiB = [Math]::Round($free, 2); minimumGiB = $MinimumGiB } | ConvertTo-Json -Compress | Write-Output
        if ($free -lt $MinimumGiB) { throw "Insufficient free disk at $Label; preserve logs and review the standard-runner recipe." }
    }
}
function Remove-VerifiedToolArchive([string]$ArchivePath) {
    $resolved = (Resolve-Path -LiteralPath $ArchivePath).Path
    $expectedParent = [IO.Path]::GetFullPath($toolsRoot).TrimEnd('\')
    $item = Get-Item -LiteralPath $resolved -Force
    $allowedNames = @($lock.downloads.PSObject.Properties.Value | ForEach-Object filename)
    if (![String]::Equals([IO.Path]::GetDirectoryName($resolved), $expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        ((Get-Item -LiteralPath $expectedParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Name -notin $allowedNames) {
        throw 'Refusing cleanup outside a named archive in this job tool directory.'
    }
    Remove-Item -LiteralPath $resolved -Force
    Write-Output "Removed extracted, hash-verified tool archive: $($item.Name)"
}
function Verify-VcpkgPortInputs {
    $promisor = & git -C $vcpkg config --local --get remote.origin.promisor
    if ($LASTEXITCODE -notin 0, 1 -or $promisor -eq 'true') { throw 'Versioned ports require a complete local vcpkg Git object store.' }
    foreach ($override in $vcpkgManifest.overrides) {
        $name = $override.name
        $versionsPath = Join-Path $vcpkg "versions/$($name.Substring(0, 1))-/$name.json"
        $registry = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json
        $portVersions = @($registry.versions | Where-Object { $_.version -eq $override.version -and $_.'port-version' -eq 0 })
        if ($portVersions.Count -ne 1 -or $portVersions[0].'git-tree' -notmatch '^[a-f0-9]{40}$') { throw "Ambiguous pinned port input: $name" }
        $tree = $portVersions[0].'git-tree'
        $proof = Join-Path $toolsRoot "verified-port-$name.tar"
        Invoke-Checked 'git' @('-C', $vcpkg, 'archive', '--format=tar', "--output=$proof", $tree)
        Write-Output "Verified local versioned port tree: $name@$($override.version) $tree"
    }
}
function Invoke-IsolatedFlutterTests([string[]]$Tests) {
    $previous = @{
        LOCALAPPDATA = $env:LOCALAPPDATA; APPDATA = $env:APPDATA
        RYMU_WINDOWS_TEST_PROFILE = $env:RYMU_WINDOWS_TEST_PROFILE; PATH = $env:PATH
    }
    $testProfile = Join-Path $toolsRoot ('rymu-win-qa-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $testProfile 'Roaming') | Out-Null
    try {
        $env:LOCALAPPDATA = $testProfile
        $env:APPDATA = Join-Path $testProfile 'Roaming'
        $env:RYMU_WINDOWS_TEST_PROFILE = $testProfile
        # RymuNative opens librustdesk.dll by name; use this build's runner.
        $env:PATH = $runner + [IO.Path]::PathSeparator + $previous.PATH
        Invoke-Checked $flutter (@('test', '--no-pub') + $Tests)
    } finally {
        foreach ($name in $previous.Keys) {
            if ($null -eq $previous[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
            }
        }
    }
}
$releaseFlags = @('--config', 'profile.release.opt-level=1', '--config', 'profile.release.lto=false', '--config', 'profile.release.codegen-units=8')
$features = @('--locked', '--offline', '--features', 'hwcodec,vram,flutter', '--lib', '--release', '--jobs', '4') + $releaseFlags

Start-Transcript -LiteralPath (Join-Path $out "logs/$Stage.log") | Out-Null
try {
    Push-Location $native
    try {
        Write-DiskState "$Stage-start"
        switch ($Stage) {
            'Bootstrap' {
                Write-DiskState 'before-tool-bootstrap' 10
                if (Test-Path -LiteralPath $toolsRoot) { throw 'Preserve prior tool state; rerun on a fresh GitHub job.' }
                New-Item -ItemType Directory -Path $toolsRoot | Out-Null
                # vcpkg validates its default cache before applying VCPKG_BINARY_SOURCES=clear.
                # Create every private tool home/cache before any consumer starts.
                foreach ($cacheDirectory in @($env:CARGO_HOME, $env:RUSTUP_HOME, $env:PUB_CACHE, $env:VCPKG_DOWNLOADS, $env:VCPKG_DEFAULT_BINARY_CACHE)) {
                    New-Item -ItemType Directory -Path $cacheDirectory | Out-Null
                }
                $sdkZip = Download-Locked 'flutter'
                Expand-Archive -LiteralPath $sdkZip -DestinationPath $toolsRoot
                Remove-VerifiedToolArchive $sdkZip
                $revision = (& git -C $flutterRoot rev-parse HEAD).Trim()
                if ($LASTEXITCODE -ne 0 -or $revision -ne $lock.flutterCommit) { throw 'Unexpected Flutter source revision.' }
                Invoke-Checked $flutter @('config', '--no-analytics')
                Invoke-Checked $flutter @('precache', '--windows')
                $engineZip = Download-Locked 'engine'
                $engineRoot = Join-Path $toolsRoot 'engine'
                Expand-Archive -LiteralPath $engineZip -DestinationPath $engineRoot
                if (!(Test-Path -LiteralPath (Join-Path $engineRoot 'flutter_windows.dll'))) { throw 'Unexpected custom engine archive layout.' }
                $sdkEngine = Join-Path $flutterRoot 'bin/cache/artifacts/engine/windows-x64-release'
                Get-ChildItem -LiteralPath $engineRoot -Force | Copy-Item -Destination $sdkEngine -Recurse -Force
                Remove-VerifiedToolArchive $engineZip
                $patch = Join-Path $native '.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff'
                Invoke-Checked 'git' @('-C', $flutterRoot, 'apply', '--check', $patch)
                Invoke-Checked 'git' @('-C', $flutterRoot, 'apply', $patch)
                $clangZip = Download-Locked 'libclang'
                Expand-Archive -LiteralPath $clangZip -DestinationPath (Join-Path $toolsRoot 'libclang')
                if (!(Test-Path -LiteralPath (Join-Path $env:LIBCLANG_PATH 'libclang.dll'))) { throw 'Expected libclang.dll is missing.' }
                Remove-VerifiedToolArchive $clangZip
                $wixZip = Download-Locked 'wix'
                Expand-Archive -LiteralPath $wixZip -DestinationPath $wix
                Remove-VerifiedToolArchive $wixZip
                Invoke-Checked 'rustup' @('toolchain', 'install', $lock.rust, '--profile', 'minimal')
                Invoke-Checked 'rustc' @('--version')
                Invoke-Checked 'git' @('init', $vcpkg)
                Invoke-Checked 'git' @('-C', $vcpkg, 'remote', 'add', 'origin', 'https://github.com/microsoft/vcpkg.git')
                # vcpkg version resolution needs registry history, not a shallow source snapshot.
                # Full objects avoid lazy promisor fetches inside vcpkg's child environment.
                Invoke-Checked 'git' @('-C', $vcpkg, 'fetch', 'origin', $lock.vcpkgCommit)
                Invoke-Checked 'git' @('-C', $vcpkg, 'checkout', '--detach', $lock.vcpkgCommit)
                Verify-VcpkgPortInputs
                Invoke-Checked (Join-Path $vcpkg 'bootstrap-vcpkg.bat') @('-disableMetrics')
                Write-DiskState 'before-vcpkg' 4
                Invoke-Checked (Join-Path $vcpkg 'vcpkg.exe') @('install', '--triplet', 'x64-windows-static', "--x-install-root=$env:VCPKG_INSTALLED_ROOT", '--clean-after-build')
                Write-DiskState 'after-vcpkg'
                Invoke-Checked 'cargo' @('fetch', '--locked')
                Push-Location (Join-Path $native 'flutter')
                try { Invoke-Checked $flutter @('pub', 'get', '--enforce-lockfile') } finally { Pop-Location }
            }
            'Build' {
                Require-Passed 'Bootstrap'
                Write-DiskState 'before-rust' 4
                Invoke-Checked 'cargo' (@('rustc') + $features + @('--crate-type', 'cdylib'))
                if (!(Test-Path -LiteralPath (Join-Path $native 'target/release/librustdesk.dll'))) { throw 'Rust did not emit its native library.' }
                Push-Location (Join-Path $native 'flutter')
                try {
                    Write-DiskState 'before-flutter' 2
                    Invoke-Checked $flutter @('build', 'windows', '--release', '--no-pub', "--build-name=$Version", '--build-number=0', '--dart-define=RYMU_ACCOUNT_API_BASE=https://rymu.iptvora-server.workers.dev/api/v1')
                } finally { Pop-Location }
                if (!(Test-Path -LiteralPath (Join-Path $runner 'Rymu.exe'))) { throw 'Flutter did not emit the Windows runner.' }
                Copy-Item -LiteralPath (Join-Path $native 'LICENCE') -Destination (Join-Path $runner 'RUSTDESK-AGPL.txt')
            }
            'Test' {
                Require-Passed 'Build'
                Write-DiskState 'before-tests' 1.5
                Invoke-Checked 'cargo' (@('test') + $features + @('rymu::', '--', '--nocapture'))
                Invoke-Checked 'python' @((Join-Path $release 'scripts/test-windows-bridge.py'), (Join-Path $runner 'librustdesk.dll'))
                Invoke-Checked 'python' @('-c', 'import subprocess,sys; result = subprocess.run([sys.argv[1], "--service-control"], check=False, timeout=15); assert result.returncode == 5, result.returncode', (Join-Path $runner 'Rymu.exe'))
                Push-Location (Join-Path $native 'flutter')
                try {
                    Invoke-IsolatedFlutterTests @('test/rymu_windows_lifecycle_test.dart', 'test/rymu_account_callback_page_test.dart', 'test/rymu_file_locations_test.dart', 'test/rymu_receiving_folder_test.dart')
                } finally { Pop-Location }
            }
            'Package' {
                Require-Passed 'Test'
                Invoke-Checked 'python' @((Join-Path $PSScriptRoot 'collect_vcpkg_notices.py'), '--installed-root', $env:VCPKG_INSTALLED_ROOT, '--runner', $runner)
                $wxs = Join-Path $out "Rymu-$Version.wxs"
                $object = Join-Path $out "Rymu-$Version.wixobj"
                $msi = Join-Path $out "Rymu-Windows-x64-$Version-CI-Unsigned.msi"
                if (Test-Path -LiteralPath $msi) { throw 'Do not overwrite a prior qualification installer.' }
                Invoke-Checked 'python' @((Join-Path $release 'scripts/emit-windows-msi.py'), $runner, $wxs, '--version', $Version, '--public-release')
                Invoke-Checked (Join-Path $wix 'candle.exe') @('-nologo', '-arch', 'x64', '-out', $object, $wxs)
                Invoke-Checked (Join-Path $wix 'light.exe') @('-nologo', '-spdb', '-ext', (Join-Path $wix 'WixUIExtension.dll'), '-cultures:en-us', '-out', $msi, $object)
                Invoke-Checked 'python' @((Join-Path $release 'scripts/test-windows-msi.py'), $msi, $runner, '--log-dir', (Join-Path $out 'logs/msi-payload'))
            }
            'Evidence' {
                Require-Passed 'Package'
                Invoke-Checked 'python' @((Join-Path $PSScriptRoot 'verify_candidate.py'))
                Invoke-Checked 'python' @((Join-Path $PSScriptRoot 'emit_evidence.py'), '--version', $Version)
                $metadata = @(Get-ChildItem -LiteralPath $runner -File | Where-Object Extension -In '.exe', '.dll' | ForEach-Object {
                    [ordered]@{ name = $_.Name; product = $_.VersionInfo.ProductName; version = $_.VersionInfo.ProductVersion; company = $_.VersionInfo.CompanyName; signature = (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status.ToString() }
                })
                $metadata | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $out 'pe-metadata.json') -Encoding utf8
                $metadataJson = $metadata | ConvertTo-Json -Depth 3
                Write-Output $metadataJson
                if ($env:GITHUB_STEP_SUMMARY) {
                    ('### PE metadata (unsigned qualification)' + "`n`n" + '```json' + "`n" + $metadataJson + "`n" + '```') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
                }
                $dependencyInventory = & cargo metadata --locked --offline --features 'hwcodec,vram,flutter' --format-version 1 --filter-platform x86_64-pc-windows-msvc
                if ($LASTEXITCODE -ne 0) { throw 'Cargo dependency inventory failed.' }
                $dependencyInventory | Set-Content -LiteralPath (Join-Path $out 'cargo-dependency-inventory.json') -Encoding utf8
            }
        }
        Write-DiskState "$Stage-complete"
        [ordered]@{ stage = $Stage; status = 'passed'; version = $Version; runId = $env:GITHUB_RUN_ID; completedAt = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out "$Stage.passed.json") -Encoding utf8
    } finally { Pop-Location }
} finally { Stop-Transcript | Out-Null }
