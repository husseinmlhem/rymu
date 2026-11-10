[CmdletBinding()]
param(
    [ValidateSet('arm64-v8a','x86_64')][string]$Abi = 'arm64-v8a',
    [string]$Distro = 'RymuAndroidBuild',
    [string]$BridgeFiles = 'D:/rymu-local/generated-bridge',
    [string]$ToolchainRoot = '/opt/rymu/toolchains',
    [string]$StageRoot = '/opt/rymu/stages',
    [string]$DependencySource = '/opt/rymu/baseline',
    [string]$TargetCache = '',
    [ValidateSet('debug','release')][string]$BuildMode = 'debug',
    [string]$BuildNumber = '',
    [string]$ReleaseKeystore = '',
    [string]$ReleasePasswordFile = '',
    [switch]$Local
)

$ErrorActionPreference = 'Stop'
$Project = Split-Path $PSScriptRoot -Parent
$Native = Join-Path $Project 'apps/native'
$ToolDirectory = Join-Path $Native 'flutter/tool'
$OutputPath = Join-Path $Project 'artifacts/android'
$Logs = Join-Path $Project 'artifacts/logs'
New-Item -Path $OutputPath, $Logs -ItemType Directory -Force | Out-Null

function Convert-ToLinuxPath([string]$Path) {
    $absolute = (Resolve-Path -LiteralPath $Path).Path
    $converted = wsl.exe -d $Distro --exec wslpath -a $absolute
    if ($LASTEXITCODE -ne 0 -or !$converted) { throw "WSL cannot access $absolute" }
    return $converted.Trim()
}

$source = Convert-ToLinuxPath $Native
$tools = Convert-ToLinuxPath $ToolDirectory
$bridges = Convert-ToLinuxPath $BridgeFiles
$releaseEnvironment = @("RYMU_ANDROID_BUILD_MODE=$BuildMode")
if ($BuildNumber) {
    if ($BuildNumber -notmatch '^[1-9][0-9]*$') { throw 'BuildNumber must be a positive integer.' }
    $releaseEnvironment += "RYMU_ANDROID_BUILD_NUMBER=$BuildNumber"
}
if ($BuildMode -eq 'release') {
    if (!$ReleaseKeystore -or !$ReleasePasswordFile) { throw 'Release requires an existing private keystore and password file.' }
    $releaseEnvironment += "RYMU_ANDROID_KEYSTORE=$(Convert-ToLinuxPath $ReleaseKeystore)"
    $releaseEnvironment += "RYMU_ANDROID_STORE_PASSWORD_FILE=$(Convert-ToLinuxPath $ReleasePasswordFile)"
}
$out = Convert-ToLinuxPath $OutputPath
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = "$StageRoot/android-$stamp"
$log = Join-Path $Logs "android-$Abi-$stamp.log"

wsl.exe -d $Distro --exec bash "$tools/stage_rymu_android.sh" $source $bridges $stage
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$envArgs = @(
    "FLUTTER_ROOT=$ToolchainRoot/flutter-3.24.5/flutter",
    'JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64',
    "ANDROID_HOME=$ToolchainRoot/android-sdk",
    "ANDROID_NDK_HOME=$ToolchainRoot/android-ndk-r28c",
    "VCPKG_ROOT=$ToolchainRoot/vcpkg",
    "RYMU_ANDROID_DEPS_SOURCE=$DependencySource"
)
if ($Local) { $envArgs += 'RYMU_LOCAL_BUILD=1' }
$envArgs += $releaseEnvironment
if ($TargetCache) { $envArgs += "CARGO_TARGET_DIR=$TargetCache" }
foreach ($key in 'RYMU_API_BASE','RYMU_WEB_ORIGIN','RYMU_RENDEZVOUS_ENDPOINT','RYMU_RELAY_ENDPOINT','RYMU_SERVER_PUBLIC_KEY') {
    $value = [Environment]::GetEnvironmentVariable($key)
    if ($value) { $envArgs += "$key=$value" }
}
wsl.exe -d $Distro --exec bash -lc 'export PATH=/root/.cargo/bin:$PATH; exec env "$@"' rymu @envArgs bash "$tools/build_rymu_android.sh" $stage $out $Abi rymu 2>&1 |
    Tee-Object -LiteralPath $log
exit $LASTEXITCODE
