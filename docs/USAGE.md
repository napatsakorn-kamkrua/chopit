# chopit

`chopit` creates short names for long PowerShell commands. The PowerShell
script is the core. A small CMD launcher lets you manage and run shortcuts from
CMD as well.

It has no external dependencies and supports Windows PowerShell 5.1 and
PowerShell 7+.

## What It Does

```text
long PowerShell command  ->  short name
git status               ->  gs
```

Shortcuts are stored in a JSON file. In PowerShell, each shortcut becomes a
global function. In CMD, chopit creates a `.cmd` wrapper that starts PowerShell
and runs the same shortcut.

## Install

Run this one command in PowerShell. No cloning or copying is required:

```powershell
irm https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.ps1 | iex
```

From CMD, use this equivalent one-line command:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.ps1' | iex"
```

The bootstrap downloads the application into
`%LOCALAPPDATA%\chopit\app` and installs both PowerShell profiles by default.
It also:

- Creates a managed `chopit` launcher in `%LOCALAPPDATA%\chopit\bin`.
- Creates CMD wrappers for existing shortcuts.
- Adds `%LOCALAPPDATA%\chopit\bin` to your user PATH.
- Backs up an existing PowerShell profile before changing it.

Close and reopen PowerShell and CMD after installation. Then these work from
any folder:

```powershell
chopit
```

```cmd
chopit
```

The project folder does not need to be on PATH. The installed launcher stores
the absolute path to `chopit.ps1`.

### Where Files Live

After installation, the files are separated like this:

```text
C:\Users\<username>\AppData\
├── Roaming\chopit\                         # Shortcut data
│   ├── shortcuts.json                      # Your shortcuts and descriptions
│   └── shortcuts.json.bak.*                # Automatic store backups
└── Local\chopit\
    ├── app\                                 # Downloaded application files
    │   ├── chopit.ps1                        # Core PowerShell program
    │   └── chopit.cmd                        # Bootstrap launcher copy
    └── bin\                                 # Installed launchers on PATH
        ├── chopit.cmd                        # Managed manager launcher
        ├── gs.cmd                             # Generated wrapper for gs
        └── cavecode.cmd                       # Generated wrapper for cavecode
```

The `app` folder contains the local copy downloaded from GitHub. The JSON file
contains your personal shortcut data. The `bin` folder is generated from that
JSON file and can be recreated with `chopit sync`.

## First Shortcut

In PowerShell:

```powershell
chopit add gs 'git status' -Description 'Show Git status'
```

In CMD, use double quotes:

```cmd
chopit add gs "git status" -Description "Show Git status"
```

Run it in PowerShell or CMD:

```text
gs
```

The existing shortcut is automatically available in both shells. You do not
need to delete and recreate it after upgrading chopit.

## Interactive Menu

Run `chopit` with no action:

```powershell
chopit
```

The menu shows numbered shortcuts, commands, and descriptions. For edit,
delete, and test, enter either the shortcut number or its name.

| Key | Action |
| --- | --- |
| `a` | Add a shortcut |
| `e` | Edit or rename a shortcut |
| `d` | Delete a shortcut |
| `t` | Test a shortcut |
| `r` | Reload functions and synchronize CMD wrappers |
| `l` | Show the JSON store path |
| `o` | Open the JSON store |
| `x` | Export shortcuts |
| `i` | Import shortcuts |
| `?` | Show usage |
| `q` | Quit |

You can also run the menu explicitly:

```text
chopit menu
```

## Commands

### List shortcuts

```text
chopit list
```

### Add a shortcut

```powershell
chopit add gs 'git status' -Description 'Show Git status'
chopit add proj 'Set-Location C:\Projects\MyApp' -Description 'Open the project'
```

Names must start with a letter and may contain letters, numbers, `_`, and `-`.
Names such as `chopit`, `add`, `edit`, `list`, and `test` are reserved.

Quote commands containing spaces. The command is stored exactly as a
PowerShell command.

### Run and test

Run a registered shortcut directly:

```text
gs
```

Test it through the manager:

```text
chopit test gs
```

Extra arguments are forwarded:

```powershell
chopit add say 'Write-Output $args' -Description 'Print supplied words'
say hello world
chopit test say hello world
```

If a stored command does not contain `$args` or `@args`, chopit automatically
appends the extra arguments.

### Edit or rename

```powershell
chopit edit gs 'git status --short'
chopit edit gs 'git status' gitshort
chopit edit gitshort -Description 'Show short Git status'
```

The last command changes only the description.

### Delete

The normal command asks for confirmation:

```text
chopit remove gitshort
chopit delete gitshort
```

Use `-Force` for scripts or when no prompt is wanted:

```text
chopit remove gitshort -Force
```

### Open the store

```text
chopit open
```

This opens `shortcuts.json` using its default Windows application.

### Synchronize CMD wrappers

Regenerate the manager launcher and all shortcut wrappers:

```text
chopit sync
```

Use this after moving or updating `chopit.ps1`. Existing shortcuts are read
from the JSON store, so they do not need to be recreated.

### Export and import

Export shortcuts:

```text
chopit export "C:\Backup\shortcuts.json"
```

Use `-Force` to overwrite an existing export file:

```text
chopit export "C:\Backup\shortcuts.json" -Force
```

Import replaces the current store. A backup is created first. Use `-Force` if
the current store is not empty:

```text
chopit import "C:\Backup\shortcuts.json" -Force
```

### Help

```text
chopit help
```

## CMD Behavior

After installation, a shortcut such as `gs` has a wrapper here:

```text
%LOCALAPPDATA%\chopit\bin\gs.cmd
```

The wrapper calls PowerShell, which executes the command stored in
`shortcuts.json`. Therefore PowerShell syntax works even when the command is
started from CMD.

These work from CMD:

```cmd
gs
gs --short
chopit test gs
```

The following limitation is important:

```powershell
Set-Location C:\Projects
```

When launched from CMD, this changes the directory only in the temporary
PowerShell process. It cannot change the parent CMD window's directory.

PowerShell profile functions may also be unavailable from CMD because wrappers
start PowerShell with `-NoProfile`. External programs such as `git`, `npm`, and
`code` work normally.

## Tab Completion

In PowerShell, press Tab to complete:

```text
chopit <Tab>
chopit test <Tab>
chopit edit <Tab>
```

The first form completes actions. The other forms complete shortcut names.

## Storage and Backups

Default store:

```text
C:\Users\<username>\AppData\Roaming\chopit\shortcuts.json
```

Press `l` in the menu to show the exact path. To use another store folder,
set this before starting PowerShell:

```powershell
$env:CHOPIT_SHORTCUTS_DIR = 'C:\MyChopitData'
```

Every store change creates a timestamped backup named
`shortcuts.json.bak.*`. The ten newest backups are retained.

Old stores using this format remain compatible:

```json
{
  "gs": "git status"
}
```

When saved, they use this format and can include descriptions:

```json
{
  "gs": {
    "command": "git status",
    "description": "Show Git status"
  }
}
```

## Moving to Another PC

1. Run the same GitHub bootstrap command on the new PC.
2. Copy `shortcuts.json` to `%APPDATA%\chopit\shortcuts.json`, or use export/import.
3. Restart PowerShell and CMD.
4. Existing shortcuts will have their CMD wrappers generated automatically.

Generated wrappers do not need to be copied. `install` and `sync` regenerate
them.

## Troubleshooting

### `chopit` is not recognized in CMD

Run the GitHub bootstrap again:

```powershell
irm https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.ps1 | iex
```

Close CMD completely and open a new window. Then check:

```cmd
where chopit
```

It should show a path under:

```text
C:\Users\<username>\AppData\Local\chopit\bin\chopit.cmd
```

### A shortcut is not recognized in CMD

Synchronize the wrappers and restart CMD:

```cmd
chopit sync
```

Check whether the wrapper exists:

```cmd
dir "%LOCALAPPDATA%\chopit\bin\cavecode.cmd"
```

### `chopit` works in PowerShell but not after moving the script

Run the GitHub bootstrap again. It downloads the current local application
copy and updates the profile and CMD launcher paths:

```powershell
irm https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.ps1 | iex
```

### PowerShell says script execution is disabled

Use `-ExecutionPolicy Bypass` for the installation command shown above, or
review your organization's PowerShell execution policy.

### The store is reported as corrupt

Do not overwrite it. Check the JSON syntax and restore a recent
`shortcuts.json.bak.*` backup, or move the corrupt file aside and import a
known-good export.

## Uninstall

Run one command:

```text
chopit uninstall
```

This removes chopit's managed block from both PowerShell profiles, removes the
generated launchers, and removes the chopit bin folder from your user PATH. It
preserves `shortcuts.json` and all backups.

If `chopit` is not available, remove the managed block from each PowerShell
profile manually:

```powershell
# >>> chopit (managed) >>>
# <<< chopit (managed) <<<
```

The application files remain in `%LOCALAPPDATA%\chopit\app` so you can
reinstall without downloading again. Delete that folder manually if desired.
The shortcut store is separate at `%APPDATA%\chopit`; delete it only if you
also want to remove your shortcuts and backups.

## Security

Shortcuts execute PowerShell commands with your user permissions. Treat
`shortcuts.json` and imported files as executable code and import only files
you trust.
