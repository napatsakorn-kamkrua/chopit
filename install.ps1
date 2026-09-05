$ErrorActionPreference = 'Stop'

$rawBase = 'https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main'
$appDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'chopit\app' } else { Join-Path $HOME '.chopit\app' }
if (-not (Test-Path -LiteralPath $appDir)) {
  New-Item -ItemType Directory -Path $appDir -Force | Out-Null
}

foreach ($file in @('chopit.ps1', 'chopit.cmd')) {
  $destination = Join-Path $appDir $file
  Invoke-WebRequest -UseBasicParsing -Uri ($rawBase + '/' + $file) -OutFile $destination
}

$hostCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $hostCommand) { $hostCommand = Get-Command powershell.exe -ErrorAction Stop }
& $hostCommand.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir 'chopit.ps1') install
Write-Output "Installed chopit from GitHub into $appDir."
