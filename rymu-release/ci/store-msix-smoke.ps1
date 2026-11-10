#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Download', 'Reconstruct', 'Install')][string]$Stage = 'Validate',
    [ValidateSet('draft-msix', 'public-msi-payload')][string]$PackageInput = 'draft-msix',
    [string]$ReleaseId = '',
    [string]$AssetId = ''
)
$ErrorActionPreference = 'Stop'
$script:ExpectedHash = 'e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4'
$script:ExpectedBytes = 35727366
$script:Repository = 'husseinmlhem/rymu'
$script:PackageName = 'HusseinMlhem.Rymu'
$script:Publisher = 'CN=F9C1B031-E95E-4F61-9D33-FEFE22907F92'
$script:Family = 'HusseinMlhem.Rymu_fqz8v1xeapywr'
$script:AssetName = 'Rymu-Windows-x64-1.0.14.0-StoreCandidate-Unsigned.msix'

function Assert-NumericId([string]$Value) {
    if ($Value -notmatch '^[1-9][0-9]{0,18}$') { throw 'A positive GitHub numeric ID is required.' }
}
function Assert-HostedContext($Context) {
    if ($Context.Actions -ne 'true' -or $Context.Environment -ne 'github-hosted' -or
        $Context.Repository -cne $script:Repository -or $Context.Event -ne 'workflow_dispatch' -or
        $Context.Image -notin @('win25', 'win25-vs2026') -or $Context.RunId -notmatch '^[1-9][0-9]*$' -or
        $Context.Attempt -notmatch '^[1-9][0-9]*$') {
        throw 'Only the manually dispatched standard Windows Server 2025 GitHub job is allowed.'
    }
}
function Assert-DraftAsset($Release, [string]$ExpectedReleaseId, [string]$ExpectedAssetId) {
    Assert-NumericId $ExpectedReleaseId; Assert-NumericId $ExpectedAssetId
    if ([string]$Release.id -ne $ExpectedReleaseId -or $Release.draft -ne $true -or $null -ne $Release.published_at) {
        throw 'The input must remain an unpublished draft release.'
    }
    $matches = @($Release.assets | Where-Object { [string]$_.id -eq $ExpectedAssetId })
    if ($matches.Count -ne 1) { throw 'The exact asset must belong to the verified draft.' }
    $asset = $matches[0]
    if ($asset.name -cne $script:AssetName -or $asset.state -ne 'uploaded' -or [long]$asset.size -ne $script:ExpectedBytes) {
        throw 'Draft asset metadata differs from the submitted package.'
    }
    if ($asset.digest -and $asset.digest -cne ('sha256:' + $script:ExpectedHash)) { throw 'Draft asset digest differs.' }
}
function Assert-AssetRedirect([string]$Address) {
    $uri = [Uri]$Address
    if (!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        $uri.Host -notin @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
        throw 'Asset redirect destination is not an approved GitHub HTTPS asset host.'
    }
}
function Read-PayloadExpectation {
    $value = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'store-msix-1.0.14.0-payload.json') -Raw | ConvertFrom-Json
    if ($value.sha256 -cne $script:ExpectedHash -or $value.bytes -ne $script:ExpectedBytes -or
        @($value.payloadSha256.PSObject.Properties).Count -ne 100) { throw 'Unexpected submitted package expectation.' }
    foreach ($item in $value.payloadSha256.PSObject.Properties) {
        if ($item.Name -match '(^|/)\.\.(/|$)|[:\\]' -or $item.Name.StartsWith('/') -or
            $item.Value -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid payload path or hash.' }
    }
    return $value
}
function Assert-Payload([string]$Directory, $Expected, [switch]$AllowSignatureFootprint) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
    $seen = @()
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse -Force) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected payload link.' }
        $name = $file.FullName.Substring($root.Length).Replace('\', '/')
        # MakeAppx unpack emits its generated block map outside the 100 payload files.
        if ($name -ceq 'AppxBlockMap.xml') { continue }
        if ($AllowSignatureFootprint -and $name -ceq 'AppxSignature.p7x') { continue }
        $wanted = $Expected.payloadSha256.PSObject.Properties[$name]
        $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if (!$wanted) { throw ('Public payload check: unexpected-entry; path=' + $name + '; actualSHA256=' + $actual + '; expected=absent-from-100-payload-files') }
        if ($actual -cne $wanted.Value) { throw ('Public payload check: hash-mismatch; path=' + $name + '; expectedSHA256=' + $wanted.Value + '; actualSHA256=' + $actual) }
        $seen += $name
    }
    if ($seen.Count -ne 100) { throw 'Expected exactly 100 unpacked payload files.' }
}
function Assert-PinnedPackage([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne $script:ExpectedBytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:ExpectedHash) {
        throw 'Input is not the exact submitted unsigned MSIX.'
    }
}
function Assert-PreparedPackage([string]$Path, $Proof, [string]$InputKind) {
    if ($InputKind -eq 'draft-msix') {
        if ($Proof.status -ne 'read-only-draft-download-verified') { throw 'Expected verified original draft transfer.' }
        Assert-PinnedPackage $Path
    } elseif ($InputKind -eq 'public-msi-payload') {
        if ($Proof.status -ne 'payload-identical-reconstruction-verified' -or $Proof.exactSubmittedArchiveTested -ne $false -or
            $Proof.publicMsiSha256 -cne 'bd7a1ce138be3adf6f54fce8d9ba989f56eac8cfa5efe5f7b4e03deb15b41174') { throw 'Expected public MSI reconstruction proof.' }
    } else { throw 'Unsupported package input.' }
    $item = Get-Item -LiteralPath $Path -Force
    if ($Proof.sha256 -cnotmatch '^[a-f0-9]{64}$' -or [long]$Proof.bytes -le 0 -or
        $item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne [long]$Proof.bytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Proof.sha256) {
        throw 'Prepared package envelope changed or has invalid evidence.'
    }
}
function Invoke-BoundedTool([string]$Tool, [string[]]$Arguments, [string]$LogPrefix, [int]$Seconds = 120) {
    foreach ($arg in $Arguments) { if ($arg.Contains('"') -or $arg.EndsWith('\')) { throw 'Unexpected native argument shape.' } }
    $quoted = @($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath $Tool -ArgumentList $quoted -PassThru -WindowStyle Hidden -RedirectStandardOutput ($LogPrefix + '.out') -RedirectStandardError ($LogPrefix + '.err')
    $null = $process.Handle
    if (!$process.WaitForExit($Seconds * 1000)) { $process.Kill(); throw 'A bounded SDK command timed out.' }
    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        # Only SDK/public-input tools use this helper; never HTTP tokens or signed URLs.
        foreach ($path in @(($LogPrefix + '.out'), ($LogPrefix + '.err'))) {
            $tail = (Get-Content -LiteralPath $path -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
            if ($tail) { Write-Output $tail.Substring(0, [Math]::Min(3000, $tail.Length)) }
        }
        throw ('Bounded preparation/SDK command failed; exit ' + $process.ExitCode + '. Local job log: ' + [IO.Path]::GetFileName($LogPrefix))
    }
}
function Invoke-PrivateAssetDownload([string]$Url, [string]$Destination, [string]$Token) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $cancel = New-Object System.Threading.CancellationTokenSource
    $cancel.CancelAfter(180000)
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    $request.Headers.Accept.ParseAdd('application/octet-stream')
    $request.Headers.UserAgent.ParseAdd('Rymu-Store-Smoke/1')
    $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 302) {
            $address = $response.Headers.Location.AbsoluteUri
            Assert-AssetRedirect $address
            $response.Dispose(); $request.Dispose()
            # Never forward the GitHub token to a redirected storage host.
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $address)
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        }
        if ([int]$response.StatusCode -ne 200) { throw 'Read-only draft asset download is unavailable; stop without a permission fallback.' }
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
        $buffer = New-Object byte[] 65536; $total = 0L
        while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            $total += $read
            if ($total -gt $script:ExpectedBytes) { throw 'Asset exceeds the expected submitted package size.' }
            $outputStream.Write($buffer, 0, $read)
        }
        if ($total -ne $script:ExpectedBytes) { throw 'Asset length differs from the submitted package.' }
    } catch { throw 'Read-only draft download failed; no token, signed URL or permission escalation is exposed.' }
    finally {
        if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }; $request.Dispose(); $client.Dispose(); $handler.Dispose(); $cancel.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$expected = Read-PayloadExpectation
if ($Stage -eq 'Validate') {
    [ordered]@{ status = 'configuration-validated-only'; payloadFiles = 100; packageSha256 = $script:ExpectedHash; installed = $false } | ConvertTo-Json
    return
}
$hostContext = @{ Actions = $env:GITHUB_ACTIONS; Environment = $env:RUNNER_ENVIRONMENT; Repository = $env:GITHUB_REPOSITORY; Event = $env:GITHUB_EVENT_NAME; Image = $env:ImageOS; RunId = $env:GITHUB_RUN_ID; Attempt = $env:GITHUB_RUN_ATTEMPT }
$hostContext | ConvertTo-Json -Compress
Assert-HostedContext $hostContext
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or !$env:RUNNER_TEMP) { throw 'A disposable Windows runner is required.' }
$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 26100 -or [int]$os.ProductType -notin @(2, 3) -or $os.Caption -notmatch 'Windows Server 2025') { throw 'Only the declared Server 2025 test scope is allowed.' }
$temporaryRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
if ((Get-Item -LiteralPath $temporaryRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runner temporary directory must not be a link.' }
$scratch = Join-Path $temporaryRoot ('rymu-store-msix-' + $env:GITHUB_RUN_ID + '-' + $env:GITHUB_RUN_ATTEMPT)
$original = Join-Path $scratch $(if ($PackageInput -eq 'public-msi-payload') { 'payload-identical-reconstructed.msix' } else { 'submitted-original.msix' })
$proofPath = Join-Path $scratch 'prepared-package.json'

if ($Stage -eq 'Download') {
    if ($PackageInput -ne 'draft-msix') { throw 'Draft Download cannot use reconstruction mode.' }
    Assert-NumericId $ReleaseId; Assert-NumericId $AssetId
    if (!$env:GH_TOKEN) { throw 'The step requires the read-only job token.' }
    if (Test-Path -LiteralPath $scratch) { throw 'Preserve existing job scratch state; rerun as a fresh attempt.' }
    $headers = @{ Authorization = 'Bearer ' + $env:GH_TOKEN; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    try {
        $repo = Invoke-RestMethod -Method Get -Uri ('https://api.github.com/repos/' + $script:Repository) -Headers $headers -TimeoutSec 30
        if ($repo.private -ne $false) { throw 'Only the existing public repository and free standard runner are allowed.' }
        $release = Invoke-RestMethod -Method Get -Uri ('https://api.github.com/repos/' + $script:Repository + '/releases/' + $ReleaseId) -Headers $headers -TimeoutSec 30
    } catch { throw 'Read-only draft metadata is unavailable; stop without broadening permissions or publishing.' }
    Assert-DraftAsset $release $ReleaseId $AssetId
    New-Item -ItemType Directory -Path $scratch | Out-Null
    Invoke-PrivateAssetDownload ('https://api.github.com/repos/' + $script:Repository + '/releases/assets/' + $AssetId) $original $env:GH_TOKEN
    Assert-PinnedPackage $original
    $proof = [ordered]@{ status = 'read-only-draft-download-verified'; runId = $env:GITHUB_RUN_ID; attempt = $env:GITHUB_RUN_ATTEMPT; releaseId = $ReleaseId; assetId = $AssetId; draft = $true; sha256 = $script:ExpectedHash; bytes = $script:ExpectedBytes; exactSubmittedArchiveTested = $true; installed = $false }
    $proof | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding UTF8
    $proof | ConvertTo-Json
    return
}

if ($Stage -eq 'Reconstruct') {
    if ($PackageInput -ne 'public-msi-payload' -or $env:GH_TOKEN) { throw 'Reconstruction requires anonymous public input, without a token.' }
    if (Test-Path -LiteralPath $scratch) { throw 'Preserve prior job scratch; use a fresh run.' }
    $repo = Invoke-RestMethod -Method Get -Uri ('https://api.github.com/repos/' + $script:Repository) -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 30
    if ($repo.private -ne $false) { throw 'Only the existing public repository and free standard runner are allowed.' }
    $makeappx = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin\10.0.26100.0\x64\MakeAppx.exe'
    if (!(Test-Path -LiteralPath $makeappx)) { throw 'Expected Windows SDK package tool is unavailable.' }
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $reconstruction = Join-Path $scratch 'reconstruction'
    Invoke-BoundedTool (Get-Command python -ErrorAction Stop).Source @((Join-Path $PSScriptRoot 'reconstruct_store_payload.py'), '--output', $reconstruction) (Join-Path $scratch 'reconstruct-public-payload') 300
    $payload = Join-Path $reconstruction 'payload'
    Assert-Payload $payload $expected
    Invoke-BoundedTool $makeappx @('pack', '/d', $payload, '/p', $original, '/h', 'SHA256', '/no') (Join-Path $scratch 'pack-reconstructed')
    $roundtrip = Join-Path $scratch 'reconstruction-roundtrip'
    Invoke-BoundedTool $makeappx @('unpack', '/p', $original, '/d', $roundtrip, '/no') (Join-Path $scratch 'unpack-reconstructed')
    Assert-Payload $roundtrip $expected
    Invoke-BoundedTool (Get-Command python -ErrorAction Stop).Source @((Join-Path $PSScriptRoot 'reconstruct_store_payload.py'), '--verify-blockmap', $roundtrip) (Join-Path $scratch 'verify-reconstructed-blockmap')
    $proof = [ordered]@{ status = 'payload-identical-reconstruction-verified'; runId = $env:GITHUB_RUN_ID; attempt = $env:GITHUB_RUN_ATTEMPT; exactSubmittedArchiveTested = $false; submittedPackageSha256ForReference = $script:ExpectedHash; publicMsiSha256 = 'bd7a1ce138be3adf6f54fce8d9ba989f56eac8cfa5efe5f7b4e03deb15b41174'; publicMsiBytes = 36651008; payloadFiles = 100; sha256 = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $original).Length; installed = $false }
    $proof | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding UTF8
    Assert-PreparedPackage $original $proof $PackageInput
    $proof | ConvertTo-Json
    return
}

# Install runs in Windows PowerShell 5.1 for the native Appx module; no token is supplied.
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Use Windows PowerShell 5.1 for the Appx installation stage.' }
if (!(Test-Path -LiteralPath $proofPath -PathType Leaf)) { throw 'Successful validated input preparation must precede installation.' }
$proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
if ($proof.runId -ne $env:GITHUB_RUN_ID -or $proof.attempt -ne $env:GITHUB_RUN_ATTEMPT) { throw 'Input proof belongs to another job.' }
Assert-PreparedPackage $original $proof $PackageInput
Import-Module Appx -ErrorAction Stop
if (Get-AppxPackage -Name $script:PackageName) { throw 'An existing package is present; do not replace it.' }
if (Get-Process -Name Rymu -ErrorAction SilentlyContinue) { throw 'Do not run alongside an existing Rymu process.' }
$sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin\10.0.26100.0\x64'
$makeappx = Join-Path $sdk 'MakeAppx.exe'; $signtool = Join-Path $sdk 'signtool.exe'
if (!(Test-Path -LiteralPath $makeappx) -or !(Test-Path -LiteralPath $signtool)) { throw 'Expected Windows SDK package tools are unavailable.' }
$unpacked = Join-Path $scratch 'original-payload'
Invoke-BoundedTool $makeappx @('unpack', '/p', $original, '/d', $unpacked, '/no') (Join-Path $scratch 'unpack-original')
Assert-Payload $unpacked $expected
Invoke-BoundedTool (Get-Command python -ErrorAction Stop).Source @((Join-Path $PSScriptRoot 'reconstruct_store_payload.py'), '--verify-blockmap', $unpacked) (Join-Path $scratch 'verify-prepared-blockmap')
$signed = Join-Path $scratch 'ephemeral-test-signed.msix'
Copy-Item -LiteralPath $original -Destination $signed
$certificate = $null; $failure = $null; $createdTrust = $false
$report = [ordered]@{ scope = 'disposable Windows Server 2025 package registration/uninstall only'; submittedVersion = '1.0.14.0'; packageInput = $PackageInput; exactSubmittedArchiveTested = [bool]$proof.exactSubmittedArchiveTested; submittedPackageSha256ForReference = $script:ExpectedHash; inputSha256 = $proof.sha256; inputBytes = $proof.bytes; payloadFilesVerified = 100; actualOS = $os.Caption; build = $os.BuildNumber; runtimeActivated = $false; peerTested = $false; windows11Qualified = $false; wackRun = $false; appCertPresent = (Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\App Certification Kit\appcert.exe')); wackReason = 'Server test scope; no WACK execution or client qualification inferred'; trustedPeopleScope = 'disposable VM LocalMachine only'; registered = $false; uninstalled = $false; certificateRemoved = $false; testSignedCopyUploaded = $false; status = 'failed' }
try {
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $script:Publisher -KeyUsage DigitalSignature -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable -HashAlgorithm SHA256 -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddHours(4) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}CA=false')
    if ($certificate.Subject -cne $script:Publisher -or $certificate.Thumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Unexpected ephemeral signing identity.' }
    $trustPath = 'Cert:\LocalMachine\TrustedPeople\' + $certificate.Thumbprint
    if (Test-Path -LiteralPath $trustPath) { throw 'Do not replace an existing trust entry.' }
    $publicCertificate = Join-Path $scratch 'ephemeral-public.cer'
    Export-Certificate -Cert $certificate -FilePath $publicCertificate -Type CERT | Out-Null
    Import-Certificate -FilePath $publicCertificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
    $createdTrust = $true
    Invoke-BoundedTool $signtool @('sign', '/fd', 'SHA256', '/sha1', $certificate.Thumbprint, '/s', 'My', $signed) (Join-Path $scratch 'sign-test-copy')
    Invoke-BoundedTool $signtool @('verify', '/pa', $signed) (Join-Path $scratch 'verify-test-copy')
    $signedPayload = Join-Path $scratch 'test-signed-payload'
    Invoke-BoundedTool $makeappx @('unpack', '/p', $signed, '/d', $signedPayload, '/no') (Join-Path $scratch 'unpack-test-copy')
    Assert-Payload $signedPayload $expected -AllowSignatureFootprint
    Invoke-BoundedTool (Get-Command python -ErrorAction Stop).Source @((Join-Path $PSScriptRoot 'reconstruct_store_payload.py'), '--verify-blockmap', $signedPayload) (Join-Path $scratch 'verify-signed-blockmap')
    Assert-PreparedPackage $original $proof $PackageInput
    $report.signedCopyPayloadIdentical = $true
    Add-AppxPackage -Path $signed -ErrorAction Stop
    $registered = @(Get-AppxPackage -Name $script:PackageName)
    if ($registered.Count -ne 1 -or $registered[0].PackageFamilyName -cne $script:Family -or
        $registered[0].Publisher -cne $script:Publisher -or [string]$registered[0].Version -ne '1.0.14.0' -or
        [string]$registered[0].Architecture -ne 'X64' -or [string]$registered[0].Status -ne 'Ok') { throw 'Registered package identity or status differs.' }
    $report.registered = $true; $report.packageFullName = $registered[0].PackageFullName
    if (Get-Process -Name Rymu -ErrorAction SilentlyContinue) { throw 'Unexpected Rymu process after registration; no UI activation was requested.' }
} catch { $failure = $_.Exception.Message }
finally {
    try {
        foreach ($package in @(Get-AppxPackage -Name $script:PackageName)) {
            if ($package.PackageFamilyName -cne $script:Family -or $package.Publisher -cne $script:Publisher) { throw 'Refuse cleanup of an unexpected package identity.' }
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
        }
        $report.uninstalled = -not [bool](Get-AppxPackage -Name $script:PackageName)
    } catch { $failure = 'Package cleanup failed; disposable VM must be discarded.' }
    try {
        if ($certificate) {
            if ($createdTrust) { Remove-Item -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $certificate.Thumbprint) -Force -ErrorAction Stop }
            Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $certificate.Thumbprint) -DeleteKey -Force -ErrorAction Stop
            $report.certificateRemoved = !(Test-Path -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $certificate.Thumbprint)) -and !(Test-Path -LiteralPath ('Cert:\CurrentUser\My\' + $certificate.Thumbprint))
        }
    } catch { $failure = 'Ephemeral certificate cleanup failed; disposable VM must be discarded.' }
    Assert-PreparedPackage $original $proof $PackageInput
    $report.preparedArchiveUnchanged = $true
    if (!$failure -and $report.registered -and $report.uninstalled -and $report.certificateRemoved) { $report.status = 'passed' }
    if ($failure) { $report.failure = $failure }
    $report | ConvertTo-Json -Depth 4
}
if ($report.status -ne 'passed') { throw 'Server package smoke did not pass; inspect the bounded console report.' }
