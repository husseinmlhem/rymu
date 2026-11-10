param([Parameter(Mandatory)][string]$RunnerDir,
      [Parameter(Mandatory)][string]$WixRoot)
. "$PSScriptRoot/_common.ps1"
$runner = Require-RymuPath $RunnerDir 'The compiled Rymu runner directory is missing.'
$candle = Require-RymuPath (Join-Path $WixRoot 'candle.exe') 'WiX Candle executable is missing.'
$light = Require-RymuPath (Join-Path $WixRoot 'light.exe') 'WiX Light executable is missing.'
$uiExtension = Require-RymuPath (Join-Path $WixRoot 'WixUIExtension.dll') 'WiX UI extension is missing.'
$python = (Get-Command python -ErrorAction Stop).Source
$intermediate = Join-Path $RymuRoot '.local/msi'
$source = Join-Path $intermediate 'Rymu.wxs'
$object = Join-Path $intermediate 'Rymu.wixobj'
$output = Join-Path $RymuRoot 'artifacts/windows/Rymu-Windows-x64-Dev.msi'
New-Item -ItemType Directory -Force -Path $intermediate,(Split-Path -Parent $output) | Out-Null
Invoke-RymuCommand $python @((Join-Path $PSScriptRoot 'emit-windows-msi.py'),$runner,$source)
Invoke-RymuCommand $candle @('-nologo','-arch','x64','-out',$object,$source) 'windows-msi-candle.log'
Invoke-RymuCommand $light @('-nologo','-spdb','-ext',$uiExtension,'-cultures:en-us','-out',$output,$object) 'windows-msi-light.log'
Require-RymuPath $output 'MSI build did not emit an installer.'
