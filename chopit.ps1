<#
.SYNOPSIS
  chopit — minimal shortcut manager for PowerShell on Windows: type a short name, run a full command.
.DESCRIPTION
  Single file, no dependencies, Windows PowerShell 5.1 and PowerShell 7+.
  Shortcuts are stored in shortcuts.json under
  %APPDATA%\chopit (override with $env:CHOPIT_SHORTCUTS_DIR).
  Dotsource this file from $PROFILE (run `chopit.ps1 install`) and each
  shortcut becomes a global function in new shells. Extra args typed after
  the shortcut are appended to the stored command.
  Dotsourcing also defines a global `chopit` function, so after install +
  restart you can run `chopit`, `chopit add ...`, etc. from anywhere.
  Install also puts the companion chopit.cmd launcher folder on the user PATH,
  so `chopit` works from CMD as well.
  Run with no arguments for an interactive menu (add / edit incl. rename / delete / test).
.EXAMPLE
  pwsh chopit.ps1 install
  chopit add mytool 'Write-Output hello'
  mytool
  chopit
#>
param(
  [string]$Action,
  [string]$Name,
  [string]$Command,
  [string]$NewName,
  [string]$Description,
  [Parameter(ValueFromRemainingArguments = $true)][object[]]$ExtraArgs,
  [switch]$Force,
  [switch]$AllProfiles,
  [switch]$CurrentProfileOnly
)

$ChopitDir = if ($env:CHOPIT_SHORTCUTS_DIR) { $env:CHOPIT_SHORTCUTS_DIR } else {
  if ($env:APPDATA) { Join-Path $env:APPDATA 'chopit' }
  else { Join-Path $HOME '.chopit' }
}
$ChopitStorePath = Join-Path $ChopitDir 'shortcuts.json'
$ChopitBinDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'chopit\bin' } else { Join-Path $ChopitDir 'bin' }
$ChopitBeginMark = '# >>> chopit (managed) >>>'
$ChopitEndMark = '# <<< chopit (managed) <<<'
$ChopitCmdBeginMark = '@rem >>> chopit (managed) >>>'
$ChopitCmdEndMark = '@rem <<< chopit (managed) <<<'
$ChopitReserved = @('chopit', 'add', 'edit', 'remove', 'delete', 'list', 'test', 'menu', 'install', 'uninstall', 'help', 'open', 'export', 'import', 'sync')
$ChopitBackupLimit = 10
$ChopitUsage = 'Use: list | add <name> <command> [-Description text] | edit <name> [new-command] [new-name] [-Description text] | remove|delete <name> [-Force] | test <name> [args...] | open | export <file> [-Force] | import <file> [-Force] | install [-CurrentProfileOnly] | uninstall | sync | help | menu (or no args for menu). Quote multi-word commands.'

if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $global:ChopitScriptPath = $PSCommandPath }
function global:chopit { & $global:ChopitScriptPath @args }

function ConvertTo-ChopitStore {
  param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
  $store = [ordered]@{}
  if ($null -eq $Object -or $Object.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
    throw "Shortcut store is corrupt (expected a JSON object of name -> shortcut), leaving it untouched: $Path. Fix or move it aside."
  }
  foreach ($prop in $Object.PSObject.Properties) {
    $value = $prop.Value
    if ($value -is [string]) {
      $command = [string]$value
      $description = ''
    }
    elseif ($null -ne $value -and $null -ne $value.PSObject.Properties['command']) {
      $command = [string]$value.Command
      $description = if ($null -ne $value.PSObject.Properties['description']) { [string]$value.Description } else { '' }
    }
    else {
      throw "Shortcut store is corrupt (entry '$($prop.Name)' must be a command string or object), leaving it untouched: $Path. Fix or move it aside."
    }
    $store[$prop.Name] = [pscustomobject]@{ Command = $command; Description = $description }
  }
  return $store
}

function Read-ChopitStoreFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{} }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
  try { $obj = $raw | ConvertFrom-Json }
  catch { throw "Shortcut store is corrupt (not valid JSON), leaving it untouched: $Path. Fix or move it aside. $_" }
  return ConvertTo-ChopitStore -Object $obj -Path $Path
}

function Get-ChopitStore { return Read-ChopitStoreFile -Path $ChopitStorePath }

function Save-ChopitStore {
  param([Parameter(Mandatory = $true)]$Store)
  if (-not (Test-Path -LiteralPath $ChopitDir)) {
    New-Item -ItemType Directory -Path $ChopitDir -Force | Out-Null
  }
  if (Test-Path -LiteralPath $ChopitStorePath) {
    $backup = "$ChopitStorePath.bak." + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $suffix = 1
    while (Test-Path -LiteralPath $backup) {
      $backup = "$ChopitStorePath.bak." + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$suffix"
      $suffix++
    }
    Copy-Item -LiteralPath $ChopitStorePath -Destination $backup -Force
    $backups = @(Get-ChildItem -LiteralPath $ChopitDir -Filter 'shortcuts.json.bak.*' -File | Sort-Object LastWriteTime -Descending)
    for ($i = $ChopitBackupLimit; $i -lt $backups.Count; $i++) {
      Remove-Item -LiteralPath $backups[$i].FullName -Force -ErrorAction SilentlyContinue
    }
  }
  $tmp = "$ChopitStorePath.tmp"
  Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject $Store -Depth 3) -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $ChopitStorePath -Force
}

function Write-ChopitCmdLauncher {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$ScriptPath, [string]$ShortcutName)
  $scriptValue = $ScriptPath -replace '%', '%%'
  $arguments = if ([string]::IsNullOrWhiteSpace($ShortcutName)) { '%*' } else { 'test "' + $ShortcutName + '" %*' }
  $content = @'
@echo off
setlocal
@rem >>> chopit (managed) >>>
set "CHOPIT_SCRIPT=__SCRIPT__"
where.exe pwsh.exe >nul 2>nul
if not errorlevel 1 goto use_pwsh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CHOPIT_SCRIPT%" __ARGUMENTS__
exit /b %errorlevel%
:use_pwsh
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CHOPIT_SCRIPT%" __ARGUMENTS__
exit /b %errorlevel%
@rem <<< chopit (managed) <<<
'@
  $content = $content.Replace('__SCRIPT__', $scriptValue).Replace('__ARGUMENTS__', $arguments)
  if (Test-Path -LiteralPath $Path) {
    $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($existing -notmatch [regex]::Escape($ChopitCmdBeginMark)) {
      throw "Cannot create managed launcher because an unmanaged file already exists: $Path"
    }
  }
  Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function Sync-ChopitCmdWrappers {
  param([Parameter(Mandatory = $true)]$Store)
  if (-not (Test-Path -LiteralPath $ChopitBinDir)) {
    New-Item -ItemType Directory -Path $ChopitBinDir -Force | Out-Null
  }
  $scriptPath = $global:ChopitScriptPath
  if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw 'Cannot determine script path for CMD launchers.' }
  Write-ChopitCmdLauncher -Path (Join-Path $ChopitBinDir 'chopit.cmd') -ScriptPath $scriptPath
  $active = @{}
  foreach ($key in $Store.Keys) {
    $keyText = '' + $key
    if ($keyText -notmatch '^[A-Za-z][A-Za-z0-9_-]*$' -or $keyText.Length -gt 60 -or $ChopitReserved -contains $keyText.ToLowerInvariant()) { continue }
    $active[$keyText.ToLowerInvariant()] = $true
    Write-ChopitCmdLauncher -Path (Join-Path $ChopitBinDir ($keyText + '.cmd')) -ScriptPath $scriptPath -ShortcutName $keyText
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $ChopitBinDir -Filter '*.cmd' -File)) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    if ($raw -match [regex]::Escape($ChopitCmdBeginMark) -and $file.BaseName.ToLowerInvariant() -ne 'chopit' -and -not $active.ContainsKey($file.BaseName.ToLowerInvariant())) {
      Remove-Item -LiteralPath $file.FullName -Force
    }
  }
}

function Test-ChopitName {
  param([string]$Value)
  $v = ('' + $Value).Trim()
  if ($v -eq '') { Write-Error 'Name is empty.'; return $false }
  if ($v.Length -gt 60 -or $v -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
    Write-Error "Bad name '$v'. Start with a letter; letters/digits/_/- only; max 60 chars."
    return $false
  }
  if ($ChopitReserved -contains $v.ToLowerInvariant()) { Write-Error "Name '$v' is reserved."; return $false }
  return $true
}

function Test-ChopitCommand {
  param([string]$Value)
  $v = ('' + $Value).Trim()
  if ($v -eq '') { Write-Error 'Command is empty.'; return $false }
  if ($v.Length -gt 4000) { Write-Error 'Command too long (max 4000 chars).'; return $false }
  return $true
}

function Register-ChopitFunction {
  param([Parameter(Mandatory = $true)][string]$Name)
  $body = {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ShortcutArgs)
    Invoke-ChopitShortcut -Name $MyInvocation.MyCommand.Name -ExtraArgs $ShortcutArgs
  }
  Set-Item -Path ('function:global:' + $Name) -Value $body -Force
}

function Register-ChopitAll {
  $store = Get-ChopitStore
  foreach ($key in $store.Keys) {
    if ($ChopitReserved -contains ('' + $key).ToLowerInvariant()) { continue }
    Register-ChopitFunction -Name $key
  }
}

function Invoke-ChopitShortcut {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$ExtraArgs
  )
  $store = Get-ChopitStore
  if (-not $store.Contains($Name)) { Write-Error "Unknown shortcut '$Name'."; return }
  $cmd = $store[$Name].Command
  if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Error "Shortcut '$Name' is empty."; return }
  $src = $cmd.TrimEnd()
  if ($src -notmatch '@args\b|\$args\b') {
    $src = $src.TrimEnd(';', ' ', "`t") + ' @args'
  }
  & ([scriptblock]::Create($src)) @ExtraArgs
}

function Add-ChopitShortcut {
  param([string]$Name, [string]$Command, [string]$Description)
  if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-Host 'Shortcut name (e.g. mytool)' }
  if ([string]::IsNullOrWhiteSpace($Command)) { $Command = Read-Host 'Full command' }
  $Name = ('' + $Name).Trim()
  $Command = ('' + $Command).Trim()
  if (-not (Test-ChopitName $Name)) { return }
  if (-not (Test-ChopitCommand $Command)) { return }
  $store = Get-ChopitStore
  if ($store.Contains($Name)) { Write-Error "Shortcut '$Name' already exists. Use edit."; return }
  if ($null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    Write-Warning "A command named '$Name' already exists; the shortcut will shadow it in new shells."
  }
  $store[$Name] = [pscustomobject]@{ Command = $Command; Description = (('' + $Description).Trim()) }
  Save-ChopitStore -Store $store
  Register-ChopitFunction -Name $Name
  Sync-ChopitCmdWrappers -Store $store
  Write-Output "Added '$Name'."
}

function Set-ChopitShortcut {
  param([string]$Name, [string]$Command, [string]$NewName, [string]$Description)
  if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-Host 'Shortcut to edit' }
  $Name = ('' + $Name).Trim()
  if ([string]::IsNullOrWhiteSpace($Command) -and [string]::IsNullOrWhiteSpace($NewName) -and [string]::IsNullOrWhiteSpace($Description)) {
    Write-Error 'Nothing to change. Give a new command and/or a new name.'
    return
  }
  $store = Get-ChopitStore
  if (-not $store.Contains($Name)) { Write-Error "Unknown shortcut '$Name'."; return }
  $target = $Name
  if (-not [string]::IsNullOrWhiteSpace($NewName)) {
    $NewName = ('' + $NewName).Trim()
    if (-not (Test-ChopitName $NewName)) { return }
    if (($NewName -ne $Name) -and $store.Contains($NewName)) {
      Write-Error "Shortcut '$NewName' already exists."
      return
    }
    $target = $NewName
  }
  $value = $store[$Name]
  if (-not [string]::IsNullOrWhiteSpace($Command)) { $value = ('' + $Command).Trim() }
  if ($value -is [string]) {
    $value = [pscustomobject]@{ Command = $value; Description = $store[$Name].Description }
  }
  if (-not [string]::IsNullOrWhiteSpace($Description)) { $value.Description = ('' + $Description).Trim() }
  if (-not (Test-ChopitCommand $value.Command)) { return }
  if ($target -ne $Name) { $store.Remove($Name) }
  $store[$target] = $value
  Save-ChopitStore -Store $store
  if ($target -ne $Name) { Remove-Item -Path ('function:global:' + $Name) -ErrorAction SilentlyContinue }
  Register-ChopitFunction -Name $target
  Sync-ChopitCmdWrappers -Store $store
  Write-Output "Updated '$target'."
}

function Remove-ChopitShortcut {
  param([string]$Name, [switch]$Force)
  if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-Host 'Shortcut to delete' }
  $Name = ('' + $Name).Trim()
  $store = Get-ChopitStore
  if (-not $store.Contains($Name)) { Write-Error "Unknown shortcut '$Name'."; return }
  if (-not $Force) {
    $yn = (('' + (Read-Host "Delete '$Name'? [y/N]")).Trim().ToLowerInvariant())
    if ($yn -ne 'y' -and $yn -ne 'yes') { Write-Output 'Cancelled.'; return }
  }
  $store.Remove($Name)
  Save-ChopitStore -Store $store
  Remove-Item -Path ('function:global:' + $Name) -ErrorAction SilentlyContinue
  Sync-ChopitCmdWrappers -Store $store
  Write-Output "Deleted '$Name'."
}

function Export-ChopitStore {
  param([string]$Path, [switch]$Force)
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Read-Host 'Export file path' }
  $Path = [Environment]::ExpandEnvironmentVariables(('' + $Path).Trim())
  if ([string]::IsNullOrWhiteSpace($Path)) { Write-Error 'Export path is empty.'; return }
  if ((Test-Path -LiteralPath $Path) -and -not $Force) {
    Write-Error "File already exists: $Path. Use -Force to overwrite it."
    return
  }
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject (Get-ChopitStore) -Depth 3) -Encoding UTF8
  Write-Output "Exported shortcuts to $Path."
}

function Import-ChopitStore {
  param([string]$Path, [switch]$Force)
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Read-Host 'Import file path' }
  $Path = [Environment]::ExpandEnvironmentVariables(('' + $Path).Trim())
  if (-not (Test-Path -LiteralPath $Path)) { Write-Error "Import file not found: $Path"; return }
  $incoming = Read-ChopitStoreFile -Path $Path
  $current = Get-ChopitStore
  if ($current.Count -gt 0 -and -not $Force) {
    Write-Error 'Import replaces the current shortcuts. Use -Force to continue; a backup will be created.'
    return
  }
  Save-ChopitStore -Store $incoming
  Register-ChopitAll
  Sync-ChopitCmdWrappers -Store $incoming
  Write-Output "Imported shortcuts from $Path."
}

function Resolve-ChopitMenuName {
  param([string]$Value, [object[]]$Keys)
  $value = ('' + $Value).Trim()
  if ($value -match '^\d+$') {
    $index = [int]$value - 1
    if ($index -ge 0 -and $index -lt $Keys.Count) { return [string]$Keys[$index] }
  }
  return $value
}

function Register-ChopitCompletion {
  if ($null -eq (Get-Command Register-ArgumentCompleter -ErrorAction SilentlyContinue)) { return }
  Register-ArgumentCompleter -CommandName chopit -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $elements = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })
    $actions = @('list', 'add', 'edit', 'remove', 'delete', 'test', 'menu', 'install', 'uninstall', 'sync', 'help', 'open', 'export', 'import')
    if ($elements.Count -le 2) {
      foreach ($action in $actions) {
        if ($action -like ($wordToComplete + '*')) {
          [System.Management.Automation.CompletionResult]::new($action, $action, 'ParameterValue', $action)
        }
      }
      return
    }
    $action = $elements[1].ToLowerInvariant()
    if ($elements.Count -eq 3 -and @('edit', 'remove', 'delete', 'test') -contains $action) {
      $store = Get-ChopitStore
      foreach ($key in $store.Keys) {
        if ($key -like ($wordToComplete + '*')) {
          [System.Management.Automation.CompletionResult]::new($key, $key, 'ParameterValue', $store[$key].Description)
        }
      }
    }
  }
}

function Install-ChopitLoaderAtPath {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)
  $self = $global:ChopitScriptPath
  if ([string]::IsNullOrWhiteSpace($self)) { throw 'Cannot determine script path.' }
  $loader = ". '" + ($self -replace "'", "''") + "'"
  $dir = Split-Path -Parent $ProfilePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $ProfilePath) {
    $profileBackup = $ProfilePath + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $suffix = 1
    while (Test-Path -LiteralPath $profileBackup) {
      $profileBackup = $ProfilePath + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$suffix"
      $suffix++
    }
    Copy-Item -LiteralPath $ProfilePath -Destination $profileBackup -Force
    $lines = @(Get-Content -LiteralPath $ProfilePath -Encoding UTF8)
  }
  else {
    $lines = @()
  }
  $kept = @()
  $inBlock = $false
  foreach ($line in $lines) {
    if ($line -eq $ChopitBeginMark) { $inBlock = $true; continue }
    if ($line -eq $ChopitEndMark) { $inBlock = $false; continue }
    if (-not $inBlock) { $kept += $line }
  }
  $kept += @('', $ChopitBeginMark, $loader, $ChopitEndMark)
  Set-Content -LiteralPath $ProfilePath -Value ($kept -join [Environment]::NewLine) -Encoding UTF8
  if (-not (Test-Path -LiteralPath $ChopitDir)) { New-Item -ItemType Directory -Path $ChopitDir -Force | Out-Null }
  Register-ChopitAll
  Write-Output "Installed loader in $ProfilePath."
}

function Install-ChopitLoader {
  param([string]$ProfilePath = $PROFILE, [switch]$AllProfiles, [switch]$CurrentProfileOnly)
  $paths = @($ProfilePath)
  if ($AllProfiles -or -not $CurrentProfileOnly) {
    $paths += @(
      (Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
      (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    )
  }
  foreach ($path in @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
    Install-ChopitLoaderAtPath -ProfilePath $path
  }
  $store = Get-ChopitStore
  Sync-ChopitCmdWrappers -Store $store
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $pathEntries = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) { $pathEntries = @($userPath -split ';' | Where-Object { $_ -ne '' }) }
  $alreadyOnPath = $false
  foreach ($entry in $pathEntries) {
    if ([string]::Equals($entry.TrimEnd('\'), $ChopitBinDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
      $alreadyOnPath = $true
      break
    }
  }
  if (-not $alreadyOnPath) {
    $pathEntries += $ChopitBinDir
    [Environment]::SetEnvironmentVariable('Path', ($pathEntries -join ';'), 'User')
    Write-Output "Added $ChopitBinDir to the user PATH."
  }
  Write-Output "Restart the shell, then run 'chopit' from anywhere."
}

function Remove-ChopitProfileBlock {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)
  if (-not (Test-Path -LiteralPath $ProfilePath)) { return }
  $lines = @(Get-Content -LiteralPath $ProfilePath -Encoding UTF8)
  $kept = @()
  $inBlock = $false
  $foundBlock = $false
  $closedBlock = $false
  foreach ($line in $lines) {
    if ($line -eq $ChopitBeginMark) { $inBlock = $true; $foundBlock = $true; continue }
    if ($line -eq $ChopitEndMark) {
      if ($inBlock) { $inBlock = $false; $closedBlock = $true }
      continue
    }
    if (-not $inBlock) { $kept += $line }
  }
  if (-not $foundBlock) { return }
  if (-not $closedBlock -or $inBlock) {
    Write-Warning "Cannot remove an incomplete chopit profile block from $ProfilePath."
    return
  }
  $profileBackup = $ProfilePath + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
  $suffix = 1
  while (Test-Path -LiteralPath $profileBackup) {
    $profileBackup = $ProfilePath + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$suffix"
    $suffix++
  }
  Copy-Item -LiteralPath $ProfilePath -Destination $profileBackup -Force
  Set-Content -LiteralPath $ProfilePath -Value ($kept -join [Environment]::NewLine) -Encoding UTF8
  Write-Output "Removed chopit from $ProfilePath."
}

function Uninstall-Chopit {
  param([switch]$CurrentProfileOnly)
  $paths = @($PROFILE)
  if (-not $CurrentProfileOnly) {
    $paths += @(
      (Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
      (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    )
  }
  foreach ($path in @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
    Remove-ChopitProfileBlock -ProfilePath $path
  }
  if (Test-Path -LiteralPath $ChopitBinDir) {
    foreach ($file in @(Get-ChildItem -LiteralPath $ChopitBinDir -Filter '*.cmd' -File)) {
      $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
      if ($raw -match [regex]::Escape($ChopitCmdBeginMark)) {
        Remove-Item -LiteralPath $file.FullName -Force
      }
    }
    $remaining = @(Get-ChildItem -LiteralPath $ChopitBinDir -Force)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $ChopitBinDir -Force }
  }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $pathEntries = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) { $pathEntries = @($userPath -split ';' | Where-Object { $_ -ne '' }) }
  $keptPathEntries = @($pathEntries | Where-Object {
    -not [string]::Equals($_.TrimEnd('\'), $ChopitBinDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
  })
  if ($keptPathEntries.Count -ne $pathEntries.Count) {
    [Environment]::SetEnvironmentVariable('Path', ($keptPathEntries -join ';'), 'User')
    Write-Output "Removed $ChopitBinDir from the user PATH."
  }
  Write-Output 'Uninstalled chopit. Your shortcut store and backups were preserved.'
}

function Show-ChopitMenu {
  $innerWidth = 60
  $contentWidth = $innerWidth - 4
  $border = '+' + ('-' * $innerWidth) + '+'
  function Write-ChopitMenuRow {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $line = ('' + $Text) -replace '[\r\n]+', ' '
    if ($line.Length -gt $contentWidth) { $line = $line.Substring(0, $contentWidth - 3) + '...' }
    Write-Host ('|  ' + $line.PadRight($contentWidth) + '  |') -ForegroundColor $Color
  }
  while ($true) {
    Clear-Host
    $store = Get-ChopitStore
    $keys = @($store.Keys)
    Write-Host $border -ForegroundColor DarkCyan
    Write-ChopitMenuRow 'CHOPIT COMMAND CENTER' Cyan
    $countLabel = if ($store.Count -eq 1) { '1 shortcut available' } else { "$($store.Count) shortcuts available" }
    Write-ChopitMenuRow $countLabel DarkGray
    Write-Host $border -ForegroundColor DarkCyan
    if ($store.Count -eq 0) {
      Write-ChopitMenuRow '(none yet - press A to add)' DarkGray
    }
    else {
      for ($i = 0; $i -lt $keys.Count; $i++) {
        $entry = $store[$keys[$i]]
        $description = if ([string]::IsNullOrWhiteSpace($entry.Description)) { 'No description' } else { $entry.Description }
        Write-ChopitMenuRow ("{0,2}  {1,-14} {2}" -f ($i + 1), $keys[$i], $description) White
        Write-ChopitMenuRow ("     $($entry.Command)") DarkGray
      }
    }
    Write-Host $border -ForegroundColor DarkCyan
    Write-ChopitMenuRow '[A] Add [E] Edit [D] Delete [T] Test [R] Reload [L] Path' Yellow
    Write-ChopitMenuRow '[O] Open [X] Export [I] Import [?] Help [Q] Quit' Yellow
    Write-Host $border -ForegroundColor DarkCyan
    $choice = (('' + (Read-Host 'Select an action or shortcut number')).Trim().ToLowerInvariant())
    switch ($choice) {
      'a' {
        Add-ChopitShortcut -Name (Read-Host 'Shortcut name (e.g. mytool)') -Command (Read-Host 'Full command') -Description (Read-Host 'Description (optional)')
      }
      'e' {
        $n = Resolve-ChopitMenuName -Value (Read-Host 'Shortcut number or name') -Keys $keys
        $cur = (Get-ChopitStore)[$n]
        if ($null -ne $cur) { Write-Output "Current command: $($cur.Command)"; Write-Output "Current description: $($cur.Description)" }
        Set-ChopitShortcut -Name $n -Command (Read-Host 'New command (empty keeps)') -NewName (Read-Host 'New name (empty keeps)') -Description (Read-Host 'New description (empty keeps)')
      }
      'd' { Remove-ChopitShortcut -Name (Resolve-ChopitMenuName -Value (Read-Host 'Shortcut number or name') -Keys $keys) }
      't' {
        $n = Resolve-ChopitMenuName -Value (Read-Host 'Shortcut number or name') -Keys $keys
        if ($n -ne '') { Invoke-ChopitShortcut -Name $n }
      }
      'r' { Register-ChopitAll; Sync-ChopitCmdWrappers -Store (Get-ChopitStore); Write-Output 'Reloaded.' }
      'l' { Write-Output $ChopitStorePath }
      'o' { if (Test-Path -LiteralPath $ChopitStorePath) { Invoke-Item -LiteralPath $ChopitStorePath } else { Write-Output "Store does not exist yet: $ChopitStorePath" } }
      'x' { Export-ChopitStore -Path (Read-Host 'Export file path') }
      'i' {
        $path = Read-Host 'Import file path'
        $confirm = (('' + (Read-Host 'Replace current shortcuts? [y/N]')).Trim().ToLowerInvariant())
        Import-ChopitStore -Path $path -Force:($confirm -eq 'y' -or $confirm -eq 'yes')
      }
      '?' { Write-Output $ChopitUsage }
      'q' { return }
      default {
        if ($choice -match '^\d+$' -and [int]$choice -gt 0 -and [int]$choice -le $keys.Count) {
          Invoke-ChopitShortcut -Name $keys[[int]$choice - 1]
        }
        else { Write-Output 'Unknown choice. Enter a shortcut number or a menu key.' }
      }
    }
    Read-Host 'Enter to continue' | Out-Null
  }
}

Register-ChopitCompletion

try { Register-ChopitAll }
catch { Write-Warning "chopit: $_ (shortcuts unavailable this session)" }

if ($MyInvocation.InvocationName -ne '.') {
  $a = ('' + $Action).Trim().ToLowerInvariant()
  switch ($a) {
    '' { Show-ChopitMenu }
    'menu' { Show-ChopitMenu }
    'help' { Write-Output $ChopitUsage }
    'list' {
      $s = Get-ChopitStore
      foreach ($k in $s.Keys) {
        $suffix = if ([string]::IsNullOrWhiteSpace($s[$k].Description)) { '' } else { ' - ' + $s[$k].Description }
        Write-Output ($k + ' = ' + $s[$k].Command + $suffix)
      }
    }
    'add' {
      $parts = @()
      if (-not [string]::IsNullOrWhiteSpace($Command)) { $parts += $Command }
      if (-not [string]::IsNullOrWhiteSpace($NewName)) { $parts += $NewName }
      if ($ExtraArgs) { $parts += @($ExtraArgs | ForEach-Object { '' + $_ }) }
      Add-ChopitShortcut -Name $Name -Command ($parts -join ' ') -Description $Description
    }
    'edit' {
      if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
        Write-Error 'Too many arguments. Quote a multi-word new command, e.g. edit <name> "new command" [new-name].'
        exit 1
      }
      Set-ChopitShortcut -Name $Name -Command $Command -NewName $NewName -Description $Description
    }
    'remove' { Remove-ChopitShortcut -Name $Name -Force:$Force }
    'delete' { Remove-ChopitShortcut -Name $Name -Force:$Force }
    'test' {
      $testArgs = @()
      if (-not [string]::IsNullOrWhiteSpace($Command)) { $testArgs += $Command }
      if (-not [string]::IsNullOrWhiteSpace($NewName)) { $testArgs += $NewName }
      if ($ExtraArgs) { $testArgs += $ExtraArgs }
      Invoke-ChopitShortcut -Name $Name -ExtraArgs $testArgs
    }
    'open' {
      if (Test-Path -LiteralPath $ChopitStorePath) { Invoke-Item -LiteralPath $ChopitStorePath }
      else { Write-Output "Store does not exist yet: $ChopitStorePath" }
    }
    'export' { Export-ChopitStore -Path $Name -Force:$Force }
    'import' { Import-ChopitStore -Path $Name -Force:$Force }
    'sync' {
      $s = Get-ChopitStore
      Sync-ChopitCmdWrappers -Store $s
      Write-Output "Synchronized CMD launchers in $ChopitBinDir."
    }
    'install' { Install-ChopitLoader -AllProfiles:$AllProfiles -CurrentProfileOnly:$CurrentProfileOnly }
    'uninstall' { Uninstall-Chopit -CurrentProfileOnly:$CurrentProfileOnly }
    default {
      Write-Error "Unknown action '$Action'. $ChopitUsage"
      exit 1
    }
  }
}
