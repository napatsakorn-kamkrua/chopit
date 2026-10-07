#!/usr/bin/env python3
"""chopit - minimal shortcut manager for bash/zsh on Linux: type a short name, run a full command.

Single file, Python 3 standard library only. Linux counterpart of chopit.ps1.
Shortcuts are stored in shortcuts.json under ${XDG_CONFIG_HOME:-~/.config}/chopit
(override with $CHOPIT_SHORTCUTS_DIR). The JSON format is shared with the Windows
version, so exports move between platforms (the commands themselves are shell code).

`chopit install` adds a managed loader to ~/.bashrc (and ~/.zshrc if present).
The loader evaluates `chopit init`, which defines a shell function per shortcut,
a `chopit` function that refreshes them after every change, and puts the wrapper
folder on PATH so shortcuts also work from scripts and other programs.
Extra args typed after a shortcut are appended unless the command uses $@, $* or $1-$9.
Run with no arguments for an interactive menu.
"""

import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

HOME = os.path.expanduser('~')
CONFIG_HOME = os.environ.get('XDG_CONFIG_HOME') or os.path.join(HOME, '.config')
DATA_HOME = os.environ.get('XDG_DATA_HOME') or os.path.join(HOME, '.local', 'share')
STORE_DIR = os.environ.get('CHOPIT_SHORTCUTS_DIR') or os.path.join(CONFIG_HOME, 'chopit')
STORE_PATH = os.path.join(STORE_DIR, 'shortcuts.json')
BIN_DIR = os.path.join(DATA_HOME, 'chopit', 'bin')
SCRIPT_PATH = os.path.realpath(__file__)
BEGIN_MARK = '# >>> chopit (managed) >>>'
END_MARK = '# <<< chopit (managed) <<<'
RC_FILES = [os.path.join(HOME, '.bashrc'), os.path.join(HOME, '.zshrc')]
ACTIONS = ['list', 'add', 'edit', 'remove', 'delete', 'test', 'menu', 'install', 'uninstall',
           'sync', 'help', 'open', 'export', 'import']
RESERVED = set(ACTIONS) | {'chopit', 'init'}
# Shell keywords cannot be function names; defining one would break every new shell.
SHELL_KEYWORDS = {'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'select', 'while',
                  'until', 'do', 'done', 'in', 'function', 'time', 'coproc', 'foreach', 'end',
                  'repeat', 'nocorrect', 'noglob'}
NAME_RE = re.compile(r'^[A-Za-z][A-Za-z0-9_-]*$')
ARGS_RE = re.compile(r'\$[@*1-9]|\$\{[@*1-9]')
BACKUP_LIMIT = 10
USAGE = ('Use: list | add <name> <command> [-Description text] | edit <name> [new-command] [new-name] '
         '[-Description text] | remove|delete <name> [-Force] | test <name> [args...] | open | '
         'export <file> [-Force] | import <file> [-Force] | install | uninstall | sync | help | '
         'menu (or no args for menu). Quote multi-word commands.')


class ChopitError(Exception):
    pass


def warn(message):
    print('chopit: warning: ' + message, file=sys.stderr)


def timestamp():
    return datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')[:-3]


def backup_file(path):
    backup = path + '.bak.' + timestamp()
    suffix = 1
    while os.path.exists(backup):
        backup = path + '.bak.' + timestamp() + '-' + str(suffix)
        suffix += 1
    shutil.copy2(path, backup)
    return backup


def write_atomic(path, text, mode=None):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        handle.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


# ---------------------------------------------------------------- store

def read_store_file(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8-sig') as handle:
        raw = handle.read()
    if not raw.strip():
        return {}
    hint = 'leaving it untouched: %s. Fix or move it aside.' % path
    try:
        obj = json.loads(raw)
    except ValueError as exc:
        raise ChopitError('Shortcut store is corrupt (not valid JSON), %s %s' % (hint, exc))
    if not isinstance(obj, dict):
        raise ChopitError('Shortcut store is corrupt (expected a JSON object of name -> shortcut), ' + hint)
    store = {}
    for name, value in obj.items():
        if isinstance(value, str):
            store[name] = {'command': value, 'description': ''}
            continue
        # The Windows version may write "Command"/"Description"; keys are case-insensitive.
        fields = {k.lower(): v for k, v in value.items()} if isinstance(value, dict) else {}
        if 'command' not in fields:
            raise ChopitError("Shortcut store is corrupt (entry '%s' must be a command string or object), %s"
                              % (name, hint))
        store[name] = {'command': str(fields['command'] or ''),
                       'description': str(fields.get('description') or '')}
    return store


def get_store():
    return read_store_file(STORE_PATH)


def save_store(store):
    os.makedirs(STORE_DIR, exist_ok=True)
    if os.path.exists(STORE_PATH):
        backup_file(STORE_PATH)
        prefix = 'shortcuts.json.bak.'
        backups = [os.path.join(STORE_DIR, f) for f in os.listdir(STORE_DIR) if f.startswith(prefix)]
        backups.sort(key=os.path.getmtime, reverse=True)
        for old in backups[BACKUP_LIMIT:]:
            try:
                os.remove(old)
            except OSError:
                pass
    write_atomic(STORE_PATH, json.dumps(store, indent=2, ensure_ascii=False) + '\n')


def valid_name(name):
    return (NAME_RE.match(name) is not None and len(name) <= 60
            and name.lower() not in RESERVED and name not in SHELL_KEYWORDS)


def check_name(name):
    if name == '':
        raise ChopitError('Name is empty.')
    if len(name) > 60 or not NAME_RE.match(name):
        raise ChopitError("Bad name '%s'. Start with a letter; letters/digits/_/- only; max 60 chars." % name)
    if name.lower() in RESERVED or name in SHELL_KEYWORDS:
        raise ChopitError("Name '%s' is reserved." % name)


def check_command(command):
    if command == '':
        raise ChopitError('Command is empty.')
    if len(command) > 4000:
        raise ChopitError('Command too long (max 4000 chars).')


def shell_source(command):
    """Return the shell code to run, appending "$@" when the command does not use its arguments."""
    src = command.rstrip()
    if not ARGS_RE.search(src):
        src = src.rstrip('; \t') + ' "$@"'
    return src


# ---------------------------------------------------------------- wrappers and shell init

def is_managed(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            return BEGIN_MARK in handle.read()
    except OSError:
        return False


def write_launcher(path, arguments):
    if os.path.lexists(path) and not is_managed(path):
        raise ChopitError('Cannot create managed launcher because an unmanaged file already exists: ' + path)
    content = '\n'.join([
        '#!/bin/sh',
        BEGIN_MARK,
        'exec python3 %s %s"$@"' % (shlex.quote(SCRIPT_PATH), arguments),
        END_MARK,
        '',
    ])
    write_atomic(path, content, 0o755)


def sync_wrappers(store):
    os.makedirs(BIN_DIR, exist_ok=True)
    write_launcher(os.path.join(BIN_DIR, 'chopit'), '')
    active = set()
    for name in store:
        if not valid_name(name):
            continue
        active.add(name)
        write_launcher(os.path.join(BIN_DIR, name), 'test %s ' % shlex.quote(name))
    for entry in os.listdir(BIN_DIR):
        path = os.path.join(BIN_DIR, entry)
        if entry != 'chopit' and entry not in active and os.path.isfile(path) and is_managed(path):
            os.remove(path)


def shell_init():
    """Shell code for `eval "$(chopit init)"` in bash or zsh."""
    try:
        store = get_store()
    except ChopitError as exc:
        warn('%s (shortcuts unavailable this session)' % exc)
        store = {}
    names = [n for n in store if valid_name(n)]
    launcher = shlex.quote(os.path.join(BIN_DIR, 'chopit'))
    lines = [
        'case ":$PATH:" in *:%s:*) ;; *) export PATH="$PATH:%s" ;; esac' % (BIN_DIR, BIN_DIR),
        '[ -n "${__CHOPIT_FUNCS:-}" ] && eval "unset -f $__CHOPIT_FUNCS" 2>/dev/null',
        'chopit() { command %s "$@"; local __chopit_rc=$?; eval "$(command %s init)"; return $__chopit_rc; }'
        % (launcher, launcher),
    ]
    for name in names:
        src = shell_source(store[name]['command'])
        # A shortcut that calls a command of the same name (ls -> ls -la) must not recurse.
        try:
            first = shlex.split(src)[0]
        except (ValueError, IndexError):
            first = ''
        if first == name:
            src = 'command ' + src
        # Dynamic scoping makes the local stack visible to nested shortcuts, so loops fail fast.
        lines.append('%s() { case " ${__CHOPIT_STACK:-} " in *" %s "*) echo "chopit: shortcut \'%s\' calls itself" >&2; '
                     'return 1;; esac; local __CHOPIT_STACK="${__CHOPIT_STACK:-} %s"; eval -- %s; }'
                     % (name, name, name, name, shlex.quote(src)))
    lines.append('__CHOPIT_FUNCS=%s' % shlex.quote(' '.join(names)))
    lines.append('if [ -n "${BASH_VERSION:-}" ]; then')
    lines.append('  _chopit_complete() {')
    lines.append('    local cur=${COMP_WORDS[COMP_CWORD]}')
    lines.append('    if [ "$COMP_CWORD" -eq 1 ]; then COMPREPLY=($(compgen -W %s -- "$cur"))'
                 % shlex.quote(' '.join(ACTIONS)))
    lines.append('    elif [ "$COMP_CWORD" -eq 2 ] && case ${COMP_WORDS[1]} in edit|remove|delete|test) true;; '
                 '*) false;; esac; then COMPREPLY=($(compgen -W %s -- "$cur"))' % shlex.quote(' '.join(names)))
    lines.append('    fi')
    lines.append('  }')
    lines.append('  complete -F _chopit_complete chopit')
    lines.append('fi')
    return '\n'.join(lines)


# ---------------------------------------------------------------- shortcut operations

def run_shortcut(name, extra_args):
    store = get_store()
    if name not in store:
        raise ChopitError("Unknown shortcut '%s'." % name)
    command = store[name]['command']
    if not command.strip():
        raise ChopitError("Shortcut '%s' is empty." % name)
    active = os.environ.get('CHOPIT_ACTIVE', '').split()
    if name in active:
        raise ChopitError("Shortcut '%s' calls itself (%s)." % (name, ' -> '.join(active + [name])))
    env = dict(os.environ, CHOPIT_ACTIVE=' '.join(active + [name]))
    return subprocess.call(['bash', '-c', shell_source(command), name] + list(extra_args), env=env)


def add_shortcut(name, command, description):
    name = name.strip() if name else input('Shortcut name (e.g. mytool): ').strip()
    command = command.strip() if command else input('Full command: ').strip()
    check_name(name)
    check_command(command)
    store = get_store()
    if name in store:
        raise ChopitError("Shortcut '%s' already exists. Use edit." % name)
    if shutil.which(name):
        warn("A command named '%s' already exists; the shortcut will shadow it in new shells." % name)
    store[name] = {'command': command, 'description': (description or '').strip()}
    save_store(store)
    sync_wrappers(store)
    print("Added '%s'." % name)


def edit_shortcut(name, command, new_name, description):
    name = name.strip() if name else input('Shortcut to edit: ').strip()
    command, new_name, description = (command or '').strip(), (new_name or '').strip(), (description or '').strip()
    if not (command or new_name or description):
        raise ChopitError('Nothing to change. Give a new command and/or a new name.')
    store = get_store()
    if name not in store:
        raise ChopitError("Unknown shortcut '%s'." % name)
    target = name
    if new_name:
        check_name(new_name)
        if new_name != name and new_name in store:
            raise ChopitError("Shortcut '%s' already exists." % new_name)
        target = new_name
    value = dict(store[name])
    if command:
        value['command'] = command
    if description:
        value['description'] = description
    check_command(value['command'])
    if target != name:
        del store[name]
    store[target] = value
    save_store(store)
    sync_wrappers(store)
    print("Updated '%s'." % target)


def remove_shortcut(name, force):
    name = name.strip() if name else input('Shortcut to delete: ').strip()
    store = get_store()
    if name not in store:
        raise ChopitError("Unknown shortcut '%s'." % name)
    if not force and input("Delete '%s'? [y/N] " % name).strip().lower() not in ('y', 'yes'):
        print('Cancelled.')
        return
    del store[name]
    save_store(store)
    sync_wrappers(store)
    print("Deleted '%s'." % name)


def expand_path(path):
    return os.path.abspath(os.path.expanduser(os.path.expandvars(path.strip())))


def export_store(path, force):
    path = path if path else input('Export file path: ')
    if not path.strip():
        raise ChopitError('Export path is empty.')
    path = expand_path(path)
    if os.path.exists(path) and not force:
        raise ChopitError('File already exists: %s. Use -Force to overwrite it.' % path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_atomic(path, json.dumps(get_store(), indent=2, ensure_ascii=False) + '\n')
    print('Exported shortcuts to %s.' % path)


def import_store(path, force):
    path = expand_path(path if path else input('Import file path: '))
    if not os.path.exists(path):
        raise ChopitError('Import file not found: ' + path)
    incoming = read_store_file(path)
    if get_store() and not force:
        raise ChopitError('Import replaces the current shortcuts. Use -Force to continue; a backup will be created.')
    save_store(incoming)
    sync_wrappers(incoming)
    skipped = [n for n in incoming if not valid_name(n)]
    if skipped:
        warn('Not runnable on Linux (invalid or reserved name): ' + ', '.join(skipped))
    print('Imported shortcuts from %s.' % path)


def open_store():
    if not os.path.exists(STORE_PATH):
        print('Store does not exist yet: ' + STORE_PATH)
        return
    editor = os.environ.get('VISUAL') or os.environ.get('EDITOR')
    if editor:
        subprocess.call(shlex.split(editor) + [STORE_PATH])
    elif shutil.which('xdg-open'):
        subprocess.call(['xdg-open', STORE_PATH])
    else:
        print(STORE_PATH)


def list_shortcuts():
    store = get_store()
    for name, entry in store.items():
        suffix = ' - ' + entry['description'] if entry['description'].strip() else ''
        print('%s = %s%s' % (name, entry['command'], suffix))


# ---------------------------------------------------------------- install / uninstall

def strip_block(lines):
    """Return (kept_lines, found, complete) with the managed block removed."""
    kept, in_block, found, closed = [], False, False, False
    for line in lines:
        if line == BEGIN_MARK:
            in_block, found = True, True
            continue
        if line == END_MARK:
            if in_block:
                in_block, closed = False, True
            continue
        if not in_block:
            kept.append(line)
    return kept, found, found and closed and not in_block


def read_lines(path):
    with open(path, encoding='utf-8', errors='surrogateescape') as handle:
        return handle.read().splitlines()


def write_lines(path, lines):
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as handle:
        handle.write('\n'.join(lines) + '\n')


def install():
    loader = 'eval "$(%s init)"' % shlex.quote(os.path.join(BIN_DIR, 'chopit'))
    os.makedirs(STORE_DIR, exist_ok=True)
    sync_wrappers(get_store())
    targets = [p for p in RC_FILES if os.path.exists(p)] or [RC_FILES[0]]
    for rc in targets:
        lines = []
        if os.path.exists(rc):
            backup_file(rc)
            lines, found, complete = strip_block(read_lines(rc))
            if found and not complete:
                raise ChopitError('Incomplete chopit block in %s; fix it manually first.' % rc)
            while lines and lines[-1] == '':
                lines.pop()
        write_lines(rc, lines + ['', BEGIN_MARK, loader, END_MARK])
        print('Installed loader in %s.' % rc)
    print("Restart the shell (or run: exec $SHELL), then run 'chopit' from anywhere.")


def uninstall():
    for rc in RC_FILES:
        if not os.path.exists(rc):
            continue
        lines, found, complete = strip_block(read_lines(rc))
        if not found:
            continue
        if not complete:
            warn('Cannot remove an incomplete chopit block from %s.' % rc)
            continue
        while lines and lines[-1] == '':
            lines.pop()
        backup_file(rc)
        write_lines(rc, lines)
        print('Removed chopit from %s.' % rc)
    if os.path.isdir(BIN_DIR):
        for entry in os.listdir(BIN_DIR):
            path = os.path.join(BIN_DIR, entry)
            if os.path.isfile(path) and is_managed(path):
                os.remove(path)
        if not os.listdir(BIN_DIR):
            os.rmdir(BIN_DIR)
    print('Uninstalled chopit. Your shortcut store and backups were preserved.')


# ---------------------------------------------------------------- menu

def color(code, text):
    return '\033[%sm%s\033[0m' % (code, text) if sys.stdout.isatty() else text


def resolve_menu_name(value, keys):
    value = value.strip()
    if value.isdigit() and 0 < int(value) <= len(keys):
        return keys[int(value) - 1]
    return value


def show_menu():
    inner, width = 60, 56
    border = color('36', '+' + '-' * inner + '+')

    def row(text, code='37'):
        line = re.sub(r'[\r\n]+', ' ', text)
        if len(line) > width:
            line = line[:width - 3] + '...'
        print(color(code, '|  ' + line.ljust(width) + '  |'))

    while True:
        if sys.stdout.isatty():
            print('\033[H\033[2J', end='')
        store = get_store()
        keys = list(store)
        print(border)
        row('CHOPIT COMMAND CENTER', '1;36')
        row('1 shortcut available' if len(keys) == 1 else '%d shortcuts available' % len(keys), '90')
        print(border)
        if not keys:
            row('(none yet - press A to add)', '90')
        for i, key in enumerate(keys):
            row('%2d  %-14s %s' % (i + 1, key, store[key]['description'] or 'No description'), '1;37')
            row('     ' + store[key]['command'], '90')
        print(border)
        row('[A] Add [E] Edit [D] Delete [T] Test [R] Reload [L] Path', '33')
        row('[O] Open [X] Export [I] Import [?] Help [Q] Quit', '33')
        print(border)
        try:
            choice = input('Select an action or shortcut number: ').strip().lower()
            if choice == 'q':
                return
            try:
                if choice == 'a':
                    add_shortcut(input('Shortcut name (e.g. mytool): '), input('Full command: '),
                                 input('Description (optional): '))
                elif choice == 'e':
                    name = resolve_menu_name(input('Shortcut number or name: '), keys)
                    if name in store:
                        print('Current command: ' + store[name]['command'])
                        print('Current description: ' + store[name]['description'])
                    edit_shortcut(name, input('New command (empty keeps): '), input('New name (empty keeps): '),
                                  input('New description (empty keeps): '))
                elif choice == 'd':
                    remove_shortcut(resolve_menu_name(input('Shortcut number or name: '), keys), False)
                elif choice == 't':
                    name = resolve_menu_name(input('Shortcut number or name: '), keys)
                    if name:
                        run_shortcut(name, [])
                elif choice == 'r':
                    sync_wrappers(get_store())
                    print('Reloaded.')
                elif choice == 'l':
                    print(STORE_PATH)
                elif choice == 'o':
                    open_store()
                elif choice == 'x':
                    export_store(input('Export file path: '), False)
                elif choice == 'i':
                    path = input('Import file path: ')
                    confirm = input('Replace current shortcuts? [y/N] ').strip().lower()
                    import_store(path, confirm in ('y', 'yes'))
                elif choice == '?':
                    print(USAGE)
                elif choice.isdigit() and 0 < int(choice) <= len(keys):
                    run_shortcut(keys[int(choice) - 1], [])
                else:
                    print('Unknown choice. Enter a shortcut number or a menu key.')
            except ChopitError as exc:
                print('chopit: ' + str(exc), file=sys.stderr)
            input('Enter to continue')
        except (EOFError, KeyboardInterrupt):
            print()
            return


# ---------------------------------------------------------------- command line

def parse_args(argv):
    """Split PowerShell-style (-Force, -Description x) or GNU-style flags from positionals."""
    positionals, description, force = [], None, False
    i = 0
    while i < len(argv):
        arg = argv[i]
        low = arg.lower()
        if low in ('-description', '--description', '-d'):
            if i + 1 >= len(argv):
                raise ChopitError('Missing value for ' + arg + '.')
            description = argv[i + 1]
            i += 2
            continue
        if low.startswith('--description='):
            description = arg.split('=', 1)[1]
        elif low in ('-force', '--force', '-f'):
            force = True
        else:
            positionals.append(arg)
        i += 1
    return positionals, description, force


def main(argv):
    action = argv[0].strip().lower() if argv else ''
    rest = argv[1:]
    if action == 'test':
        # Everything after the name belongs to the shortcut, flags included.
        if not rest:
            raise ChopitError('Usage: chopit test <name> [args...]')
        return run_shortcut(rest[0], rest[1:])
    if action == 'init':
        print(shell_init())
        return 0
    pos, description, force = parse_args(rest)
    arg = lambda i: pos[i] if len(pos) > i else ''
    if action in ('', 'menu'):
        show_menu()
    elif action == 'help':
        print(USAGE)
    elif action == 'list':
        list_shortcuts()
    elif action == 'add':
        add_shortcut(arg(0), ' '.join(pos[1:]), description)
    elif action == 'edit':
        if len(pos) > 3:
            raise ChopitError('Too many arguments. Quote a multi-word new command, e.g. edit <name> "new command" [new-name].')
        edit_shortcut(arg(0), arg(1), arg(2), description)
    elif action in ('remove', 'delete'):
        remove_shortcut(arg(0), force)
    elif action == 'open':
        open_store()
    elif action == 'export':
        export_store(arg(0), force)
    elif action == 'import':
        import_store(arg(0), force)
    elif action == 'sync':
        sync_wrappers(get_store())
        print('Synchronized launchers in %s.' % BIN_DIR)
    elif action == 'install':
        install()
    elif action == 'uninstall':
        uninstall()
    else:
        raise ChopitError("Unknown action '%s'. %s" % (argv[0], USAGE))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except ChopitError as exc:
        print('chopit: ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        print(file=sys.stderr)
        sys.exit(130)
