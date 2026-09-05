# chopit

PowerShell shortcuts with a CMD launcher.

Turn long commands into short names:

```text
git status  ->  gs
```

## Install

Run this once in PowerShell. No clone or file copying is required:

```powershell
irm https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.ps1 | iex
```

Restart PowerShell and CMD. Then `chopit` and your shortcuts work from any
folder.

## Quick Start

```powershell
chopit add gs 'git status' -Description 'Show Git status'  # create shortcut
gs                                                         # use shortcut
chopit                                                     # optional: open menu
```

From CMD, use double quotes:

```cmd
chopit add gs "git status" -Description "Show Git status"
gs
```

The final `chopit` in the PowerShell example is optional. It opens the
interactive menu; it is not needed to run `gs`.

## Common Commands

```text
chopit                    Open the interactive menu
chopit list               List shortcuts
chopit add NAME COMMAND   Add a shortcut
chopit edit NAME          Edit or rename a shortcut
chopit test NAME          Test a shortcut
chopit remove NAME        Delete a shortcut
chopit sync               Regenerate CMD wrappers
chopit export FILE       Export shortcuts
chopit import FILE       Import shortcuts
chopit uninstall          Uninstall chopit, preserving shortcuts
```

## Files

```text
%APPDATA%\chopit\shortcuts.json       Your shortcuts
%LOCALAPPDATA%\chopit\app\            Downloaded application
%LOCALAPPDATA%\chopit\bin\            PATH launchers and shortcut wrappers
```

## Full Documentation

See the [full usage guide](docs/USAGE.md) for installation details, the menu,
all options, CMD behavior, backups, moving to another PC, troubleshooting, and
security notes.

## Security

The install command executes a script downloaded from GitHub. Review the
source first if you do not want to pipe remote code into PowerShell. Shortcuts
also execute PowerShell commands with your user permissions.
