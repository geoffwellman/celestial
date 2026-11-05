#!/usr/bin/env python3
"""Bounded orchestration of existing approved disk handlers; never deletes data."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time

GIB = 1 << 30
TARGET = 20 * GIB
CONTROL_RESERVE = 120
HANDLERS = ('release-drain', 'ordinary-drain', 'preservation-retire', 'docker-sweep')
DEFAULTS = {'release-drain': ('cel-disk-release-drain', []),
            'ordinary-drain': ('cel-disk-drain', []),
            'preservation-retire': ('cel-disk-retire', ['--apply'])}


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        d = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(d)
        finally:
            os.close(d)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, cap=16 * 1024 * 1024):
    with open(path, 'rb') as f:
        data = f.read(cap + 1)
    if len(data) > cap:
        raise ValueError('JSON exceeds size limit')
    return json.loads(data)


def reviewed_queue_issuer(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError('release queue issuer requires an explicit reviewed nonempty string')
    return value


def reviewed_follow_main_issuer(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 256 or any(ord(c) < 32 for c in value):
        raise ValueError('follow-main issuer requires an explicit reviewed nonempty string (at most 256 characters)')
    return value


def owned_read(home, relative, cap):
    """Read bounded regular metadata through owned, nonsymlink directories."""
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(p in ('.', '..') for p in parts):
        raise ValueError('invalid metadata path')
    directory = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            s = os.fstat(directory)
            if s.st_uid != os.getuid():
                raise ValueError('metadata directory is not owner owned')
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        s = os.fstat(directory)
        if s.st_uid != os.getuid():
            raise ValueError('metadata directory is not owner owned')
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as f:
            s = os.fstat(f.fileno())
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o022:
                raise ValueError('metadata must be an owner-controlled nonsymlink regular file')
            if s.st_size > cap:
                raise ValueError('metadata exceeds size limit')
            data = f.read(cap + 1)
            if len(data) > cap:
                raise ValueError('metadata exceeds size limit')
            return data
    finally:
        os.close(directory)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate manifest key')
        result[key] = value
    return result


def executable_digest(path):
    path = Path(path)
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
        raise ValueError('CLI source must be an owner-owned regular file')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def runtime_files(cel):
    root = Path(cel).parent.parent
    paths = [root / 'bin/cel', *sorted((root / 'lib').glob('*.sh'))]
    if Path(cel) != paths[0] or not all((root / 'lib' / name).is_file() for name in ('box.sh', 'common.sh', 'run.sh')):
        raise ValueError('Docker adapter needs a complete bin/cel and lib shell deployment')
    files = {}
    digest = hashlib.sha256()
    for path in paths:
        executable_digest(path)
        relative = str(path.relative_to(root))
        data = path.read_bytes()
        files[relative] = data
        digest.update(relative.encode() + b'\0' + str(len(data)).encode() + b'\0' + data)
    return files, digest.hexdigest()


class Controller:
    def __init__(self, home, config, pass_seconds=2400, handler_seconds=650, control_reserve=CONTROL_RESERVE):
        self.home = Path(home)
        self.directory = self.home / '.local/state/cel-disk-headroom'
        self.directory.mkdir(parents=True, exist_ok=True)
        self.config_path = Path(config)
        self.pass_seconds = pass_seconds
        self.handler_seconds = handler_seconds
        self.deadline = time.monotonic() + pass_seconds
        self.work_deadline = self.deadline - control_reserve
        self.lock_fd = None
        self.config = {}
        self.state = {}

    def free(self):
        s = os.statvfs('/')
        return s.f_bavail * s.f_frsize

    def receipt(self, **row):
        row['time'] = int(time.time())
        with open(self.directory / 'receipts.jsonl', 'a') as f:
            f.write(json.dumps(row, sort_keys=True) + '\n')
            f.flush()
            os.fsync(f.fileno())

    def save(self):
        atomic(self.directory / 'status.json', self.state)

    def command(self, argv, seconds, env=None, deadline=None):
        """Drain bounded output; handler deadlines preserve control-plane time."""
        limit = self.deadline if deadline is None else min(self.deadline, deadline)
        remaining = min(seconds, limit - time.monotonic())
        if remaining <= 0:
            return {'status': 'timeout', 'output': 'whole-pass deadline exhausted'}
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True, env=env,
                                 pass_fds=(() if self.lock_fd is None else (self.lock_fd,)))
        except OSError as e:
            return {'status': 'failed', 'output': str(e)}
        out = bytearray()
        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ)
        end = time.monotonic() + remaining
        timed_out = False
        try:
            while sel.get_map():
                if time.monotonic() >= end:
                    timed_out = True
                    break
                for key, _ in sel.select(min(.2, max(0, end - time.monotonic()))):
                    b = os.read(key.fileobj.fileno(), 8192)
                    if not b:
                        sel.unregister(key.fileobj)
                    else:
                        out.extend(b)
                        if len(out) > 65536:
                            del out[:-65536]
            if not timed_out:
                try:
                    p.wait(timeout=max(.001, end - time.monotonic()))
                except subprocess.TimeoutExpired:
                    timed_out = True
            if timed_out:
                # No unbounded TERM grace outside the whole-pass budget.
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait(timeout=5)
        finally:
            sel.close()
            p.stdout.close()
        return {'status': 'timeout' if timed_out else ('ok' if p.returncode == 0 else 'failed'),
                'exit_code': p.returncode, 'output': out.decode('utf-8', 'replace')}

    def load(self):
        s = self.config_path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o022:
            raise ValueError('configuration must be owner-controlled regular file')
        self.config = read_json(self.config_path, 65536)
        if not isinstance(self.config, dict) or type(self.config.get('version')) is not int or self.config.get('version') != 1 or set(self.config) - {
                'version', 'handler_sha256', 'retire_notification_version', 'docker_opt_in',
                'cel', 'cel_sha256', 'docker_runtime_sha256', 'release_queue_issuer', 'follow_main_issuer'}:
            raise ValueError('unknown configuration/version')
        reviewed_queue_issuer(self.config.get('release_queue_issuer'))
        if 'follow_main_issuer' in self.config:
            reviewed_follow_main_issuer(self.config['follow_main_issuer'])
        hashes = self.config.get('handler_sha256', {})
        if not isinstance(hashes, dict) or set(hashes) - set(DEFAULTS):
            raise ValueError('unknown handler')
        try:
            self.state = read_json(self.directory / 'status.json')
        except FileNotFoundError:
            self.state = {'version': 1, 'notifications': {}, 'producers': {}}
        if not isinstance(self.state, dict) or self.state.get('version') != 1 or not isinstance(self.state.get('notifications'), dict) or not isinstance(self.state.get('producers'), dict):
            raise ValueError('unknown durable state version')

    def cel_path(self):
        path = self.config.get('cel')
        if not isinstance(path, str) or not os.path.isabs(path):
            raise ValueError('missing absolute configured cel executable')
        if executable_digest(path) != self.config.get('cel_sha256'):
            raise ValueError('missing or changed reviewed cel executable SHA256')
        return path

    def docker_handler(self):
        if self.config.get('docker_opt_in') is not True:
            return {'status': 'blocked', 'output': 'safe Docker adapter requires explicit opt-in and deployed safety v1'}
        files, digest = runtime_files(self.cel_path())
        if digest != self.config.get('docker_runtime_sha256'):
            raise ValueError('missing or changed reviewed Docker CLI runtime SHA256')
        # The capability and mutation run from the SAME independently copied,
        # reviewed bytes. An installed checkout update cannot swap the callee.
        with tempfile.TemporaryDirectory(prefix='docker-runtime-', dir=self.directory) as directory:
            root = Path(directory)
            for relative, data in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(0o555 if relative == 'bin/cel' else 0o444)
            cel = str(root / 'bin/cel')
            env = dict(os.environ, CEL_ROOT=str(root))
            cap = self.command([cel, 'box', 'docker-safety'], 15, env,
                               deadline=self.work_deadline)
            if cap['status'] != 'ok':
                return cap
            safe = json.loads(cap['output'])
            if cap['status'] != 'ok' or not isinstance(safe, dict) or type(safe.get('version')) is not int or safe.get('version') != 1 or safe.get('keep_label') != 'cel.keep=true' or not isinstance(safe.get('lock_file'), str) or not os.path.isabs(safe['lock_file']):
                raise ValueError('missing safety v1 capability')
            # Validate the declared lock protocol; the callee acquires it once.
            # Acquiring it here too would deadlock/refuse the nonblocking callee.
            return self.command([cel, 'box', 'sweep-docker'], self.handler_seconds, env,
                                deadline=self.work_deadline)

    def handler(self, name):
        if name not in HANDLERS:
            return {'status': 'failed', 'output': 'unknown handler'}
        if name == 'docker-sweep':
            return self.docker_handler()
        binary, args = DEFAULTS[name]
        path = self.home / '.local/bin' / binary
        try:
            s = path.lstat()
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o022:
                raise ValueError('handler not owner-controlled regular file')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if self.config.get('handler_sha256', {}).get(name) != digest:
                raise ValueError('missing or changed reviewed handler SHA256')
            if name == 'preservation-retire' and (type(self.config.get('retire_notification_version')) is not int or self.config.get('retire_notification_version') != 1):
                raise ValueError('missing lane-notification adapter v1; legacy retirement sends root')
        except (OSError, ValueError) as e:
            return {'status': 'failed', 'output': str(e)}
        env = dict(os.environ, CEL_RETIRE_NOTIFY_RECIPIENT='celestial-disk-cleanup')
        # Production adapters must not inherit the standalone smoke-test hooks,
        # especially a lowered preservation reserve or an after-copy shell hook.
        for key in ('CEL_DRAIN_ROOT', 'CEL_DRAIN_STATE', 'CEL_RETIRE_HOME',
                    'CEL_RETIRE_MIN_FREE', 'CEL_RETIRE_HOOK_AFTER_COPY',
                    'CEL_RETIRE_FAIL_COPY_AFTER', 'CEL_RETIRE_FAIL_REMOVE'):
            env.pop(key, None)
        return self.command([str(path), *args], self.handler_seconds, env,
                            deadline=self.work_deadline)

    def phase(self, name):
        before = self.free()
        now = int(time.time())
        old = self.state['producers'].get(name, {})
        # Save intent before dispatch so interruption is distinguishable from success.
        pending = {'status': 'running', 'started_at': now, 'before_available_bytes': before,
                   'next_retry': now + 600, 'blocked_since': old.get('blocked_since', now)}
        self.state['producers'][name] = pending
        self.save()
        try:
            result = self.handler(name)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
            result = {'status': 'failed', 'output': str(e)}
        after = self.free()
        result.update(before_available_bytes=before, after_available_bytes=after,
                      observed_df_delta_bytes=after - before, observed_at=int(time.time()),
                      next_retry=int(time.time()) + 600)
        if result['status'] != 'ok':
            result['blocked_since'] = old.get('blocked_since', now)
            result['blocker_age_seconds'] = now - result['blocked_since']
        self.state['producers'][name] = result
        self.receipt(kind='handler', producer=name, **result)
        self.save()
        return result

    def follow_main_facts(self):
        relative = '.cache/slot-builder-iso/follow-main-manifest.json'
        fact = {'source': str(self.home / relative), 'authorization': 'none',
                'source_controlled_deletion_disabled': True,
                'scope': 'observed retention facts only; candidates are not closure or a cleanup grant'}
        if 'follow_main_issuer' not in self.config:
            return dict(fact, status='missing-adapter', blocker='follow-main issuer not configured; no retention facts trusted')
        try:
            data = json.loads(owned_read(self.home, relative, 65536), object_pairs_hook=unique_object)
            required = {'version', 'issuer', 'generated_at', 'live', 'rollback', 'base', 'worktree_candidates'}
            if not isinstance(data, dict) or not required <= set(data) or set(data) - required - {'retired_this_pass'}:
                raise ValueError('unknown follow-main manifest schema')
            if type(data['version']) is not int or data['version'] != 1 or data['issuer'] != self.config['follow_main_issuer']:
                raise ValueError('unknown follow-main version or issuer')
            if 'retired_this_pass' in data and data['retired_this_pass'] != []:
                raise ValueError('follow-main producer must publish nondeleting status')
            stamp = data['generated_at']
            if not isinstance(stamp, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)', stamp):
                raise ValueError('follow-main timestamp must be UTC')
            generated = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
            age = time.time() - generated.timestamp()
            if age < -60 or age > 600:
                raise ValueError('follow-main manifest stale or future dated')
            parent = self.home / 'code/slot-studio-wt'

            def worktree(value):
                if not isinstance(value, str) or str(Path(value)) != value or Path(value).parent != parent:
                    raise ValueError('unexpected follow-main worktree parent')
                match = re.fullmatch(r'local-([0-9a-f]{12}|[0-9a-f]{40})', Path(value).name)
                if not match:
                    raise ValueError('invalid follow-main worktree head name')
                return match[1]

            paths, retained_heads = set(), []
            for name in ('live', 'rollback'):
                row = data[name]
                if name == 'rollback' and row is None:
                    continue
                if not isinstance(row, dict) or set(row) != {'worktree', 'image'}:
                    raise ValueError('invalid follow-main retention ref')
                suffix = worktree(row['worktree'])
                if row['image'] != 'slot-studio-local/media-executor:' + suffix:
                    raise ValueError('follow-main image does not match worktree head')
                if any(suffix.startswith(old) or old.startswith(suffix) for old in retained_heads):
                    raise ValueError('duplicate follow-main retention ref')
                paths.add(row['worktree'])
                retained_heads.append(suffix)
            base = data['base']
            if not isinstance(base, dict) or set(base) != {'image', 'label'} or base != {
                    'image': 'slot-studio-media-executor-base:local', 'label': 'cel.keep=true'}:
                raise ValueError('invalid follow-main base retention ref')
            candidates = data['worktree_candidates']
            if not isinstance(candidates, list) or len(candidates) > 256:
                raise ValueError('invalid or oversized follow-main candidate list')
            heads = set()
            for row in candidates:
                if not isinstance(row, dict) or set(row) != {'path', 'head'}:
                    raise ValueError('invalid follow-main candidate')
                suffix = worktree(row['path'])
                head = row['head']
                if not isinstance(head, str) or not re.fullmatch(r'[0-9a-f]{40}', head) or not head.startswith(suffix):
                    raise ValueError('invalid follow-main candidate head')
                if row['path'] in paths or head in heads or any(head.startswith(old) for old in retained_heads):
                    raise ValueError('duplicate or retained follow-main candidate')
                paths.add(row['path'])
                heads.add(head)
                # Follow-main uses detached linked worktrees. Read only the small
                # Git metadata; never invoke Git, repair refs, or acquire its locks.
                pointer = owned_read(self.home, str(Path(row['path']).relative_to(self.home) / '.git'), 4096).decode().strip()
                prefix = 'gitdir: '
                gitdir = Path(pointer[len(prefix):]) if pointer.startswith(prefix) else None
                metadata = self.home / 'code/slot-studio/.git/worktrees'
                if gitdir is None or not gitdir.is_absolute() or str(gitdir) != pointer[len(prefix):] or gitdir.parent != metadata:
                    raise ValueError('unexpected follow-main Git metadata location')
                actual = owned_read(self.home, str(gitdir.relative_to(self.home) / 'HEAD'), 128).decode().strip()
                if actual != head:
                    raise ValueError('follow-main candidate HEAD metadata mismatch')
            fact.update(status='observed', live=data['live'], rollback=data['rollback'], base=base,
                        candidate_count=len(candidates), generated_at=stamp, publication_age_seconds=int(age))
        except (OSError, ValueError, TypeError, OverflowError, RecursionError) as e:
            fact.update(status='blocked', blocker=str(e))
        return fact

    def producer_facts(self):
        q = self.home / '.cache/slot-builder-iso/release-queue.json'
        try:
            data = read_json(q)
            if not isinstance(data, dict) or data.get('version') != 1 or data.get('issuer') != self.config['release_queue_issuer'] or not isinstance(data.get('entries'), list):
                raise ValueError('unknown release queue schema')
            stamp = data.get('generated_at')
            if not isinstance(stamp, str):
                raise ValueError('missing release queue timestamp')
            generated = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
            if generated.tzinfo is None:
                raise ValueError('release queue timestamp lacks timezone')
            age = int(time.time() - generated.timestamp())
            fact = {'status': 'blocked' if age < -60 or age > 3600 else 'observed',
                    'entries': len(data['entries']), 'queue_age_seconds': age,
                    'held_count': data.get('held_count'), 'generated_at': stamp,
                    'source': str(q), 'scope': 'published dependency targets only; not whole gate runs'}
            if fact['status'] == 'blocked':
                fact['blocker'] = 'release queue stale or future dated; handler remains authoritative'
        except (OSError, ValueError) as e:
            fact = {'status': 'missing-adapter', 'blocker': str(e), 'source': str(q)}
        facts = {'gate-runs': fact,
                 'follow-main-executor-images': self.follow_main_facts(),
                 'miniflare-tracing': {'status': 'missing-adapter', 'blocker': 'no exact closed-set producer adapter; no tracing files selected'},
                 'stale-worktrees': {'status': 'delegated', 'handler': 'preservation-retire', 'blocker': 'handler eligibility, preservation and minimum-free guards remain authoritative'}}
        now = int(time.time())
        for name, row in facts.items():
            old = self.state['producers'].get(name, {})
            row.update(observed_at=now, next_retry=now + 600)
            if row['status'] in ('missing-adapter', 'blocked') or row.get('held_count'):
                row['blocked_since'] = old.get('blocked_since', now)
                row['blocker_age_seconds'] = now - row['blocked_since']
            self.state['producers'][name] = row
        # Cheap daemon-provided totals, never a whole-filesystem du or prune.
        self.state['docker_facts'] = {
            'system_df': self.command(['docker', 'system', 'df', '--format', '{{json .}}'], 15),
            'container_writable': self.command(['docker', 'ps', '-a', '--size', '--format', '{{json .}}'], 15),
            'observed_at': now}
        self.save()

    def notify(self, recipient, key, message, repeat=1800):
        now = int(time.time())
        row = self.state['notifications'].get(recipient, {})
        if row.get('key') == key and row.get('acked_at') and now - row['acked_at'] < repeat and not row.get('debt'):
            return True
        if row.get('key') == key and row.get('debt') and now < row.get('next_retry', 0):
            return False
        debt = {'key': key, 'message': message, 'debt': True, 'next_retry': now + 600}
        self.state['notifications'][recipient] = debt
        self.save()
        try:
            cel = self.cel_path()
            env = dict(os.environ, CEL_ROOT=str(Path(cel).parent.parent))
            r = self.command([cel, 'inbox', 'send', recipient, message,
                              '--from', 'celestial-disk-cleanup', '--workspace', 'plane',
                              '--kind', 'escalation' if recipient == 'root' else 'info'], 30, env)
        except (OSError, ValueError, KeyError, TypeError) as e:
            r = {'status': 'failed', 'output': str(e)}
        if r['status'] == 'ok' and f'queued for {recipient} in plane' in r['output']:
            debt.update(debt=False, acked_at=now)
        else:
            debt['last_failure'] = r
        self.save()
        return not debt['debt']

    def run(self, only=None):
        self.lock_fd = os.open(self.directory / 'lock', os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock_fd)
            self.lock_fd = None
            print('disk maintenance already running', file=sys.stderr)
            return 75
        try:
            self.load()
            before = self.free()
            self.state.update(started_at=int(time.time()), before_available_bytes=before,
                              target_bytes=TARGET, pass_status='running')
            self.save()
            failed = False
            incomplete = []
            if only:
                if before < TARGET:
                    failed = self.phase(only)['status'] != 'ok'
            elif before < TARGET:
                for name in HANDLERS:
                    if self.free() >= TARGET:
                        break
                    if time.monotonic() >= self.work_deadline:
                        failed = True
                        incomplete.append(name)
                        skipped = {'status': 'skipped', 'output': 'handler budget exhausted; control-plane reserve retained',
                                   'observed_at': int(time.time()), 'next_retry': int(time.time()) + 600}
                        self.state['producers'][name] = skipped
                        self.receipt(kind='handler', producer=name, **skipped)
                        self.save()
                        continue
                    result = self.phase(name)
                    failed |= result['status'] != 'ok'
                    if result['status'] == 'timeout':
                        incomplete.append(name)
            after = self.free()
            deficit = max(0, TARGET - after)
            self.state.update(after_available_bytes=after, observed_df_delta_bytes=after - before,
                              capacity_deficit_bytes=deficit, completed_at=int(time.time()),
                              incomplete_handlers=incomplete,
                              root_capacity_decision_deferred=bool(deficit and (failed or incomplete)),
                              pass_status='failed' if failed else ('capacity-deficit' if deficit else 'target-met'))
            self.save()
            self.receipt(kind='pass', status=self.state['pass_status'], before_available_bytes=before,
                         after_available_bytes=after, observed_df_delta_bytes=after-before,
                         capacity_deficit_bytes=deficit)
            if only:
                return 1 if failed else 0
            if deficit:
                self.producer_facts()
                lane_ok = self.notify('celestial-disk-cleanup', 'maintenance',
                    f'[disk maintenance] available={after}B target={TARGET}B deficit={deficit}B. '
                    f'Observed window delta={after-before}B, not exclusive reclaimed bytes. '
                    f'Status/producer blockers: {self.directory}/status.json. Retry in 10min; approved classes only.')
                # Failed, skipped or timed-out cleanup is routine retry work,
                # not evidence that approved reclaim was exhausted. Emergency
                # remains an explicit independent decision for partial passes.
                root_ok = True
                if (not failed and not incomplete) or after < GIB:
                    key = 'emergency-capacity' if after < GIB else 'capacity'
                    basis = ('Maintenance is incomplete; emergency capacity decision required.' if failed or incomplete else
                             'All configured approved handlers completed successfully; target not reached.')
                    root_ok = self.notify('root', key,
                        f'[disk decision required: {key}] {basis} '
                        f'Available={after}B; measurable capacity deficit={deficit}B. '
                        'Decide additional capacity or a new explicit producer/class grant; no permission expansion applied. '
                        f'Handler failures, skipped work and missing producer adapters: {self.directory}/status.json.',
                        repeat=86400 if after < GIB else 10**12)
                return 3 if not lane_ok or not root_ok else (1 if failed else 2)
            self.state['notifications'].pop('root', None)
            self.state['notifications'].pop('celestial-disk-cleanup', None)
            self.save()
            return 1 if failed else 0
        finally:
            # Close, do not LOCK_UN: a surviving child retaining the fd retains exclusion.
            os.close(self.lock_fd)
            self.lock_fd = None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('verb', choices=('run', 'handler'), nargs='?', default='run')
    p.add_argument('name', choices=HANDLERS, nargs='?')
    p.add_argument('--config', default=str(Path.home() / '.config/cel/disk-headroom.json'))
    a = p.parse_args()
    if a.verb == 'handler' and not a.name:
        p.error('handler requires a name')
    try:
        return Controller(Path.home(), a.config).run(a.name if a.verb == 'handler' else None)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f'disk headroom FAILED CLOSED: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
