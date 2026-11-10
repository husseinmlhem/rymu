# Pure guard tests. No network, certificate, AppX or Rymu activation call.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot 'store-msix-smoke.ps1'
$null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ('PowerShell parse errors: ' + ($errors.Message -join '; ')) }
. $path -Stage Validate
$script:Cases = 0
function Expect-Rejected([scriptblock]$Body) {
    $failed = $false
    try { & $Body } catch { $failed = $true }
    if (!$failed) { throw 'A dangerous/invalid input was accepted.' }
    $script:Cases++
}
$context = @{ Actions='true'; Environment='github-hosted'; Repository='husseinmlhem/rymu'; Event='workflow_dispatch'; Image='win25'; RunId='123'; Attempt='1' }
Assert-HostedContext $context; $script:Cases++
$updatedImageContext = $context.Clone(); $updatedImageContext.Image = 'win25-vs2026'
Assert-HostedContext $updatedImageContext; $script:Cases++
foreach ($key in @('Actions','Environment','Repository','Event','Image','RunId','Attempt')) {
    $bad = $context.Clone(); $bad[$key] = 'invalid'
    Expect-Rejected { Assert-HostedContext $bad }
}
foreach ($id in @('', '0', '-1', '../12', '1;Write-Output x', '12345678901234567890')) {
    Expect-Rejected { Assert-NumericId $id }
}
Assert-NumericId '123'; $script:Cases++
$release = [pscustomobject]@{ id=123; draft=$true; published_at=$null; assets=@([pscustomobject]@{id=456;name='Rymu-Windows-x64-1.0.14.0-StoreCandidate-Unsigned.msix';state='uploaded';size=35727366;digest='sha256:e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4'}) }
Assert-DraftAsset $release '123' '456'; $script:Cases++
Expect-Rejected { Assert-DraftAsset $release '999' '456' }
Expect-Rejected { Assert-DraftAsset $release '123' '999' }
$release.draft=$false; Expect-Rejected { Assert-DraftAsset $release '123' '456' }; $release.draft=$true
$release.published_at='2026-11-10'; Expect-Rejected { Assert-DraftAsset $release '123' '456' }; $release.published_at=$null
$release.assets[0].digest='sha256:wrong'; Expect-Rejected { Assert-DraftAsset $release '123' '456' }
$release.assets[0].digest='sha256:e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4'
$release.assets[0].size=10; Expect-Rejected { Assert-DraftAsset $release '123' '456' }; $release.assets[0].size=35727366
$release.assets[0].name='other.msix'; Expect-Rejected { Assert-DraftAsset $release '123' '456' }
foreach ($uri in @('http://release-assets.githubusercontent.com/a', 'https://example.com/a', 'https://release-assets.githubusercontent.com.evil.test/a', 'https://user@release-assets.githubusercontent.com/a', 'https://release-assets.githubusercontent.com:8443/a', '/relative')) {
    Expect-Rejected { Assert-AssetRedirect $uri }
}
Assert-AssetRedirect 'https://release-assets.githubusercontent.com/example'; $script:Cases++
$expected = Read-PayloadExpectation
if (@($expected.payloadSha256.PSObject.Properties).Count -ne 100) { throw 'Wrong payload expectation.' }
$script:Cases++
$scriptText = Get-Content -LiteralPath $path -Raw
foreach ($forbidden in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root', 'Export-PfxCertificate', 'Add-AppxPackage -AllowUnsigned', 'Enable-WindowsOptionalFeature', 'Start-Process -FilePath Rymu', 'workflow_dispatch.*contents: write')) {
    if ($scriptText.Contains($forbidden)) { throw 'Forbidden installation/trust/permission shortcut.' }
}
$script:Cases++
[ordered]@{ status='passed'; tests=$script:Cases; scope='pure input/host/token-redirect guards and PowerShell syntax; no hosted download or installation executed' } | ConvertTo-Json
