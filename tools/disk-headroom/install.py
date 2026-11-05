#!/usr/bin/env python3
"""Install the tracked controller, without deleting legacy scripts or disabling timers."""
import argparse
import fcntl
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import sys

spec = importlib.util.spec_from_file_location('headroom', Path(__file__).with_name('controller.py'))
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
UNITS = ('cel-disk-monitor', 'cel-disk-release-drain', 'cel-disk-drain', 'cel-disk-retire')


def unit_quote(value):
    # systemd expands % specifiers and $ environment syntax even inside quotes.
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def install(home, cel, hashes, retire_v1=False, docker=False, apply=False):
    if not apply:
        return install_quiescent(home, cel, hashes, retire_v1, docker, False)
    directory = Path(home) / '.local/state/cel-disk-headroom'
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / 'lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('controller invocation is active; migration refused')
        return install_quiescent(home, cel, hashes, retire_v1, docker, True)


def install_quiescent(home, cel, hashes, retire_v1=False, docker=False, apply=False):
    home = Path(home).resolve()
    cel = Path(cel).resolve()
    config = {'version': 1, 'cel': str(cel), 'handler_sha256': hashes,
              'retire_notification_version': 1 if retire_v1 else 0, 'docker_opt_in': docker}
    if not apply:
        print('Plan: preserve standalone scripts; install controller and monitor/handler service drop-ins; '
              'no timers stopped, disabled or enabled. Parent must stop existing disk timers and let services finish before --apply.')
        return
    # Deployment is explicit. No race with old, non-locking ExecStarts: parent must
    # first stop ALL four timers, then wait for ALL finite services to finish.
    for name in UNITS:
        for suffix in ('timer', 'service'):
            unit = name + '.' + suffix
            r = subprocess.run(['systemctl', '--user', 'show', unit, '--property=LoadState', '--property=ActiveState'],
                               capture_output=True, text=True, timeout=15)
            fields = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
            if r.returncode or fields.get('LoadState') != 'loaded' or fields.get('ActiveState') not in ('inactive', 'failed'):
                raise ValueError(f'{unit} must be loaded and inactive/failed before migration; parent must quiesce existing timers/services')
    if not cel.is_file() or not os.access(cel, os.X_OK):
        raise ValueError('cel executable missing')
    dest = home / '.local/lib/cel-disk-headroom/controller.py'
    wrapper = home / '.local/bin/cel-disk-headroom'
    units = home / '.config/systemd/user'
    mapping = {'cel-disk-monitor': 'run', 'cel-disk-release-drain': 'handler release-drain',
               'cel-disk-drain': 'handler ordinary-drain', 'cel-disk-retire': 'handler preservation-retire'}
    dropins = {}
    for name, verb in mapping.items():
        file = units / (name + '.service.d') / '50-headroom.conf'
        content = ('# Managed by Celestial disk-headroom installer. Standalone scripts remain unchanged.\n'
                   '[Unit]\nDescription=Celestial serialized disk headroom maintenance\n'
                   '[Service]\nExecStart=\nExecStart=' + unit_quote(wrapper) + ' ' + verb + '\n'
                   'TimeoutStartSec=2460\nKillMode=control-group\nUMask=0077\n'
                   'Environment="PATH=' + str(home) + '/.local/bin:' + str(cel.parent) + ':' + str(home) + '/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"\n')
        if file.is_symlink() or (file.exists() and file.read_text() != content):
            raise ValueError(f'conflicting existing drop-in: {file}')
        dropins[file] = content
    if dest.is_symlink() or wrapper.is_symlink():
        raise ValueError('refusing symlink controller/wrapper destination')
    # Preflight every conflict before replacing an installed config or program.
    dest.parent.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('controller.py').read_bytes()
    fd, temporary = controller.tempfile.mkstemp(prefix='controller.', dir=dest.parent)
    with os.fdopen(fd, 'wb') as f:
        f.write(source)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temporary, 0o755)
    os.replace(temporary, dest)
    controller.atomic(home / '.config/cel/disk-headroom.json', config)
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    wrapper.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(dest)) + ' "$@"\n')
    wrapper.chmod(0o755)
    for file, content in dropins.items():
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
    subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=30)
    print('Installed; no timers enabled/disabled or standalone scripts changed. '
          'Parent may start cel-disk-monitor.service, inspect durable status, then restart the existing timers.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--cel', required=True)
    p.add_argument('--handler-sha256', action='append', default=[], metavar='NAME=SHA256')
    p.add_argument('--retire-notification-v1', action='store_true')
    p.add_argument('--enable-safe-docker', action='store_true')
    a = p.parse_args()
    hashes = {}
    for entry in a.handler_sha256:
        name, sep, value = entry.partition('=')
        if not sep or name not in controller.DEFAULTS or len(value) != 64 or any(c not in '0123456789abcdef' for c in value) or name in hashes:
            p.error('handler pins require a known unique name and lowercase SHA256')
        hashes[name] = value
    try:
        install(Path.home(), a.cel, hashes, a.retire_notification_v1, a.enable_safe_docker, a.apply)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f'headroom installation refused: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
