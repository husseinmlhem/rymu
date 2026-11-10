$ErrorActionPreference = 'Stop'
$RymuRoot = Split-Path -Parent $PSScriptRoot
$RymuLog = Join-Path $RymuRoot 'artifacts/logs'
New-Item -ItemType Directory -Force -Path $RymuLog | Out-Null

function Invoke-RymuCommand {
    param([Parameter(Mandatory)][string]$File,
          [string[]]$Arguments = @(),
          [string]$Log)
    $PSNativeCommandUseErrorActionPreference = $false
    if ($Log) {
        & $File @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $RymuLog $Log)
    } else {
        & $File @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($File)) exited with code $LASTEXITCODE."
    }
}

function Require-RymuPath {
    param([string]$Path, [string]$Explanation)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw $Explanation }
    return (Resolve-Path -LiteralPath $Path).Path
}
