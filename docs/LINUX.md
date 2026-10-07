# chopit on Linux

`chopit.py` is the Linux version of chopit. It uses only the Python 3 standard
library and works in bash and zsh. Commands, menu keys, and the
`shortcuts.json` format match the Windows version (see [USAGE.md](USAGE.md)).
Shortcut commands are shell code, not PowerShell.

## Install

Run this one command. No cloning or copying is required:

```bash
curl -fsSL https://raw.githubusercontent.com/napatsakorn-kamkrua/chopit/main/install.sh | bash
```

It needs `python3` and `curl`. The installer:

- Downloads `chopit.py` into `~/.local/share/chopit/app`.
- Creates a managed `chopit` launcher in `~/.local/share/chopit/bin`.
- Creates launchers for existing shortcuts.
- Adds a managed loader block to `~/.bashrc`, and to `~/.zshrc` if it exists.
- Backs up each rc file before changing it.

Run it again at any time to update chopit. Then restart the shell, or run:

```bash
exec $SHELL
```

## Quick Start

```bash
chopit add gs 'git status' -Description 'Show Git status'
gs
gs --short          # extra arguments are appended
chopit              # interactive menu
```

GNU-style flags also work: `--description`/`-d` and `--force`/`-f`.

## How Shortcuts Run

The loader in your rc file runs `chopit init`. It defines:

- A shell function per shortcut. The command runs in your current shell, so
  `cd` and environment changes persist.
- A `chopit` function that refreshes these functions after every change. New
  shortcuts work at once, without a restart.
- Tab completion for actions and shortcut names (bash).

The launcher folder is appended to `PATH`. Scripts, cron jobs, and other
programs can run shortcuts as normal commands. Launchers run the command in a
new `bash`, so `cd` affects only that process. System commands win over
launchers with the same name; in your interactive shell the function wins.

If a command does not use `$@`, `$*`, or `$1`-`$9`, chopit appends `"$@"`:

```bash
chopit add say 'echo said:'
say hello            # said: hello
chopit add greet 'echo "Hello, $1!"'
greet Ana            # Hello, Ana!
```

A shortcut may wrap a command of the same name, for example
`chopit add ls 'ls -la'`. A shortcut that calls itself through other shortcuts
stops with an error instead of looping.

## Files

```text
~/.config/chopit/shortcuts.json        Your shortcuts
~/.config/chopit/shortcuts.json.bak.*  Automatic backups (ten newest kept)
~/.local/share/chopit/app/chopit.py    Downloaded application
~/.local/share/chopit/bin/             Generated launchers (chopit sync)
```

`$XDG_CONFIG_HOME` and `$XDG_DATA_HOME` are respected. Set
`$CHOPIT_SHORTCUTS_DIR` to use another store folder.

`chopit open` opens the store in `$VISUAL` or `$EDITOR`, otherwise with
`xdg-open`.

## Moving From Windows

Export on Windows, then import on Linux:

```bash
chopit import ~/shortcuts.json -Force
```

Both key styles (`command` and `Command`) and the old string format are
read. Rewrite PowerShell-only commands, such as `Set-Location`, as shell
commands with `chopit edit`.

## Uninstall

```bash
chopit uninstall
```

This removes the loader block from `~/.bashrc` and `~/.zshrc` and deletes the
generated launchers. It preserves `shortcuts.json`, its backups, and
`~/.local/share/chopit/app`.

## Security

The install command runs a script downloaded from GitHub. Review
`install.sh` first if you do not want to pipe remote code into bash.
Shortcuts run with your user permissions. Treat `shortcuts.json` and imported
files as executable code.
