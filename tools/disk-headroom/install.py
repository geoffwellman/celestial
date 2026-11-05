#!/usr/bin/env python3
"""Install the tracked controller, without deleting legacy scripts or disabling timers."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('headroom', Path(__file__).with_name('controller.py'))
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
UNITS = ('cel-disk-monitor', 'cel-disk-release-drain', 'cel-disk-drain', 'cel-disk-retire')
HEADER = '# Managed by Celestial disk-headroom installer. Standalone scripts remain unchanged.\n'


def unit_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def replace_bytes(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            os.fchmod(f.fileno(), mode)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        d = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(d)
        finally:
            os.close(d)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(home, cel, hashes, retire_v1=False, docker=False, apply=False,
            cel_sha256=None, docker_runtime_sha256=None, release_queue_issuer=None, follow_main_issuer=None):
    if follow_main_issuer is not None:
        controller.reviewed_follow_main_issuer(follow_main_issuer)
    if not apply:
        print('Plan: preserve standalone scripts; back up and transactionally install controller/service drop-ins; '
              'no timers stopped, disabled or enabled. Parent must quiesce existing timers/services before --apply.')
        return
    controller.reviewed_queue_issuer(release_queue_issuer)
    directory = Path(home) / '.local/state/cel-disk-headroom'
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / 'lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('controller invocation is active; migration refused')
        return install_quiescent(Path(home).resolve(), Path(cel).resolve(), hashes, retire_v1, docker,
                                 directory, cel_sha256, docker_runtime_sha256, release_queue_issuer, follow_main_issuer)


def install_quiescent(home, cel, hashes, retire_v1, docker, directory, cel_sha256, docker_runtime_sha256,
                      release_queue_issuer, follow_main_issuer):
    units = home / '.config/systemd/user'
    existing_dropins = {}
    for name in UNITS:
        for suffix in ('timer', 'service'):
            unit = name + '.' + suffix
            r = subprocess.run(['systemctl', '--user', 'show', unit, '--property=LoadState',
                                '--property=ActiveState', '--property=DropInPaths'],
                               capture_output=True, text=True, timeout=15)
            fields = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
            if r.returncode or fields.get('LoadState') != 'loaded' or fields.get('ActiveState') not in ('inactive', 'failed'):
                raise ValueError(f'{unit} must be loaded and inactive/failed; parent must quiesce existing timers/services')
            if suffix == 'service':
                existing_dropins[name] = [Path(p) for p in shlex.split(fields.get('DropInPaths', ''))]
    if not os.access(cel, os.X_OK) or controller.executable_digest(cel) != cel_sha256:
        raise ValueError('missing or changed reviewed cel executable SHA256')
    runtime_files, runtime_digest = controller.runtime_files(cel)
    if runtime_digest != docker_runtime_sha256:
        raise ValueError('missing or changed reviewed CLI runtime SHA256')
    # The maintenance application owns its reviewed dependency packet. A normal
    # update of the general-purpose CLI must not invalidate cleanup/notification
    # pins or silently swap the code used by an unattended maintenance pass.
    runtime = home / '.local/lib/cel-disk-headroom/approved-runtime' / runtime_digest
    parent = runtime
    while parent != home:
        if parent.is_symlink() or (parent.exists() and
                (not parent.is_dir() or parent.stat().st_uid != os.getuid())):
            raise ValueError(f'unsafe approved runtime directory: {parent}')
        parent = parent.parent
    config = {'version': 1, 'cel': str(runtime / 'bin/cel'), 'cel_sha256': cel_sha256,
              'docker_runtime_sha256': runtime_digest, 'handler_sha256': hashes,
              'retire_notification_version': 1 if retire_v1 else 0, 'docker_opt_in': docker,
              'release_queue_issuer': release_queue_issuer}
    if follow_main_issuer is not None:
        config['follow_main_issuer'] = follow_main_issuer
    dest = home / '.local/lib/cel-disk-headroom/controller.py'
    wrapper = home / '.local/bin/cel-disk-headroom'
    payloads = {}
    for relative, data in runtime_files.items():
        path = runtime / relative
        mode = 0o700 if relative == 'bin/cel' else 0o600
        if path.is_symlink():
            raise ValueError(f'changed immutable approved runtime: {path}')
        if path.exists():
            if (not path.is_file() or path.stat().st_uid != os.getuid() or
                    path.read_bytes() != data or stat.S_IMODE(path.stat().st_mode) != mode):
                raise ValueError(f'changed immutable approved runtime: {path}')
            continue
        payloads[path] = (data, mode)
    payloads.update({
        dest: (Path(__file__).with_name('controller.py').read_bytes(), 0o755),
        wrapper: (('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(dest)) + ' "$@"\n').encode(), 0o755),
        home / '.config/cel/disk-headroom.json': ((json.dumps(config, sort_keys=True) + '\n').encode(), 0o600)})
    mapping = {'cel-disk-monitor': 'run', 'cel-disk-release-drain': 'handler release-drain',
               'cel-disk-drain': 'handler ordinary-drain', 'cel-disk-retire': 'handler preservation-retire'}
    for name, verb in mapping.items():
        parent = units / (name + '.service.d')
        file = parent / '50-headroom.conf'
        content = (HEADER + '[Unit]\nDescription=Celestial serialized disk headroom maintenance\n'
                   '[Service]\nExecStart=\nExecStart=' + unit_quote(wrapper) + ' ' + verb + '\n'
                   'TimeoutStartSec=2460\nKillMode=control-group\nSuccessExitStatus=75\nUMask=0077\n'
                   'Environment="PATH=' + str(home) + '/.local/bin:' + str(cel.parent) + ':' + str(home) + '/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"\n')
        if file.is_symlink() or (file.exists() and file.read_text() != content):
            raise ValueError(f'conflicting existing drop-in: {file}')
        # Include both manager-loaded paths and not-yet-reloaded local drop-ins.
        for later in set(existing_dropins[name]) | set(parent.glob('*.conf')):
            if later.name > file.name and any(line.strip().partition('=')[0].strip() == 'ExecStart'
                                               for line in later.read_text().splitlines()
                                               if not line.lstrip().startswith(('#', ';'))):
                raise ValueError(f'later drop-in overrides controller ExecStart: {later}')
        payloads[file] = (content.encode(), 0o644)
    originals = {}
    for path in payloads:
        if path.is_symlink():
            raise ValueError(f'refusing symlink installation destination: {path}')
        if path.exists():
            s = path.stat()
            if not stat.S_ISREG(s.st_mode):
                raise ValueError(f'nonregular installation destination: {path}')
            originals[path] = (path.read_bytes(), stat.S_IMODE(s.st_mode))
        else:
            originals[path] = None
    # Durable independent preimages survive even a failed rollback. Never use
    # hardlinks: later edits must not mutate the rollback evidence.
    backups = directory / 'install-backups'
    backups.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='transaction-', dir=backups))
    manifest = []
    for index, (path, original) in enumerate(originals.items()):
        row = {'path': str(path), 'existed': original is not None}
        if original is not None:
            saved = backup / str(index)
            replace_bytes(saved, original[0], 0o600)
            row.update(backup=str(saved), mode=original[1])
        manifest.append(row)
    controller.atomic(backup / 'manifest.json', {'version': 1, 'files': manifest})
    changed = []
    try:
        for path, (data, mode) in payloads.items():
            # Include the current path before replacement in case fsync raises
            # after replace succeeded.
            changed.append(path)
            replace_bytes(path, data, mode)
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=30)
    except BaseException as error:
        failures = []
        for path in reversed(changed):
            try:
                original = originals[path]
                if original is None:
                    path.unlink(missing_ok=True)
                    d = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(d)
                    finally:
                        os.close(d)
                else:
                    replace_bytes(path, *original)
            except OSError as e:
                failures.append(f'{path}: {e}')
        try:
            subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as e:
            failures.append(f'rollback daemon-reload: {e}')
        outcome = 'preimages restored' if not failures else 'rollback incomplete; keep timers stopped'
        raise ValueError(f'installation failed; {outcome}; backup={backup}; '
                         f'rollback failures={failures}; original error={error}') from error
    print(f'Installed transaction; backups={backup}. No timers toggled or standalone scripts changed. '
          'Parent may supervise cel-disk-monitor.service, then restart the existing timers.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--cel', required=True)
    p.add_argument('--cel-sha256')
    p.add_argument('--docker-runtime-sha256')
    p.add_argument('--release-queue-issuer', help='exact reviewed producer identity; required for apply')
    p.add_argument('--follow-main-issuer', help='optional exact reviewed observer identity; never a cleanup grant')
    p.add_argument('--describe-cel', action='store_true', help='print candidate digests for review; never install')
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
        if a.describe_cel:
            cel = Path(a.cel).resolve()
            print(json.dumps({'cel': str(cel), 'cel_sha256': controller.executable_digest(cel),
                              'docker_runtime_sha256': controller.runtime_files(cel)[1]}, sort_keys=True))
            return 0
        install(Path.home(), a.cel, hashes, a.retire_notification_v1, a.enable_safe_docker, a.apply,
                a.cel_sha256, a.docker_runtime_sha256, a.release_queue_issuer, a.follow_main_issuer)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f'headroom installation refused: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
