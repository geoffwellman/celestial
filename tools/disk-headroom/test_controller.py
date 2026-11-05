#!/usr/bin/env python3
"""Real child-command smoke in private fake HOME; never invoke host cleanup."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('controller', HERE / 'controller.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
spec = importlib.util.spec_from_file_location('installer', HERE / 'install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

FIXTURE = '''#!/usr/bin/python3
import json, os, pathlib, sys, time
h=pathlib.Path(os.environ['FIXTURE_HOME'])
name=pathlib.Path(sys.argv[0]).name
with open(h/'commands','a') as f: f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='cel':
 with open(h/'cli-roots','a') as f: f.write(os.environ.get('CEL_ROOT','')+'\\n')
 inherited=pathlib.Path(os.environ.get('CEL_ROOT',''))/'intruder.py'
 if inherited.is_file(): exec(inherited.read_text())
 if sys.argv[1:3]==['box','docker-safety']:
  if (h/'mutate-cli').exists(): (h/'.local/bin/cel').write_text('#!/usr/bin/python3\\nraise SystemExit(42)\\n')
  print(json.dumps({'version':int((h/'docker-version').read_text()),'keep_label':'cel.keep=true','lock_file':str(h/'docker.lock')}));sys.exit(0)
 if sys.argv[1:3]==['inbox','send']:
  recipient=sys.argv[3]
  if (h/'fail-mail').exists():sys.exit(1)
  if not (h/'false-ack').exists(): print('queued for '+recipient+' in plane')
  sys.exit(0)
 if sys.argv[1:3]==['box','sweep-docker']:name='docker-sweep'
if name=='docker':
 print('{}');sys.exit(0)
config=json.loads((h/'effects').read_text()).get(name,{})
if config.get('sleep'):time.sleep(config['sleep'])
if config.get('delta'):
 marker=h/(name+'.handled')
 if not marker.exists():
  (h/'free').write_text(str(int((h/'free').read_text())+config['delta']));marker.touch()
print(json.dumps({'result':'fixture','name':name}))
sys.exit(config.get('rc',0))
'''


class FakeFree(m.Controller):
    def free(self):
        return int((self.home / 'free').read_text())


class HeadroomTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cel-headroom-test-')
        self.addCleanup(self.tmp.cleanup)
        self.h = Path(self.tmp.name)
        self.bin = self.h / '.local/bin'
        self.bin.mkdir(parents=True)
        for name in ('cel', 'docker', 'cel-disk-release-drain', 'cel-disk-drain', 'cel-disk-retire'):
            p = self.bin / name
            p.write_text(FIXTURE)
            p.chmod(0o700)
        library = self.h / '.local/lib'
        library.mkdir(parents=True)
        for name in ('box.sh', 'common.sh', 'run.sh'):
            (library / name).write_text('# private fixture library\n')
            (library / name).chmod(0o600)
        self.env = patch.dict(os.environ, {'FIXTURE_HOME': str(self.h), 'PATH': str(self.bin) + ':/usr/bin:/bin'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.config = self.h / 'config.json'
        self.data = {'version': 1, 'cel': str(self.bin / 'cel'), 'docker_opt_in': True,
                     'retire_notification_version': 1, 'handler_sha256': {
                         name: hashlib.sha256((self.bin / binary).read_bytes()).hexdigest()
                         for name, (binary, _) in m.DEFAULTS.items()}}
        self.data['release_queue_issuer'] = 'fixture-producer'
        self.data['cel_sha256'] = m.executable_digest(self.bin / 'cel')
        self.data['docker_runtime_sha256'] = m.runtime_files(self.bin / 'cel')[1]
        self.configure()
        self.effects({})
        (self.h / 'docker-version').write_text('1')
        self.free(15 * m.GIB)

    def configure(self):
        self.config.write_text(json.dumps(self.data))
        self.config.chmod(0o600)

    def effects(self, value):
        (self.h / 'effects').write_text(json.dumps(value))

    def free(self, value):
        (self.h / 'free').write_text(str(value))

    def controller(self, **kwargs):
        return FakeFree(self.h, self.config, **kwargs)

    def state(self):
        return json.loads((self.h / '.local/state/cel-disk-headroom/status.json').read_text())

    def commands(self):
        p = self.h / 'commands'
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def mail(self, recipient):
        return [x for x in self.commands() if x[:4] == ['cel', 'inbox', 'send', recipient]]
    def retry_due(self):
        state = self.state()
        for row in state['notifications'].values():
            row['next_retry'] = 0
        m.atomic(self.h / '.local/state/cel-disk-headroom/status.json', state)

    def install(self):
        return installer.install(self.h, self.bin / 'cel', self.data['handler_sha256'],
                                 True, True, True, self.data['cel_sha256'], self.data['docker_runtime_sha256'],
                                 self.data['release_queue_issuer'])

    def follow_manifest(self):
        self.data['follow_main_issuer'] = 'fixture-follow-main'
        self.configure()
        parent = self.h / 'code/slot-studio-wt'
        candidate = parent / ('local-' + 'c' * 12)
        candidate.mkdir(parents=True)
        metadata = self.h / 'code/slot-studio/.git/worktrees' / candidate.name
        metadata.mkdir(parents=True)
        (candidate / '.git').write_text('gitdir: ' + str(metadata) + '\n')
        (metadata / 'HEAD').write_text('c' * 40 + '\n')
        (candidate / '.git').chmod(0o600)
        (metadata / 'HEAD').chmod(0o600)
        manifest = {
            'version': 1, 'issuer': self.data['follow_main_issuer'],
            'generated_at': m.datetime.datetime.now(m.datetime.timezone.utc).isoformat(),
            'live': {'worktree': str(parent / ('local-' + 'a' * 12)),
                     'image': 'slot-studio-local/media-executor:' + 'a' * 12},
            'rollback': {'worktree': str(parent / ('local-' + 'b' * 12)),
                         'image': 'slot-studio-local/media-executor:' + 'b' * 12},
            'base': {'image': 'slot-studio-media-executor-base:local', 'label': 'cel.keep=true'},
            'worktree_candidates': [{'path': str(candidate), 'head': 'c' * 40}],
            'retired_this_pass': []}
        path = self.h / '.cache/slot-builder-iso/follow-main-manifest.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(manifest))
        path.chmod(0o600)
        return path, manifest, metadata

    def observe_follow(self):
        c = self.controller()
        c.load()
        return c.follow_main_facts()


    def test_threshold_stops_after_each_phase(self):
        self.effects({'cel-disk-release-drain': {'delta': 5 * m.GIB}})
        self.assertEqual(self.controller().run(), 0)
        self.assertEqual([x[0] for x in self.commands()], ['cel-disk-release-drain'])
        p = self.state()['producers']['release-drain']
        self.assertEqual(p['observed_df_delta_bytes'], 5 * m.GIB)
        self.assertEqual(p['after_available_bytes'], m.TARGET)
        self.assertEqual(self.controller().run(), 0)
        self.assertEqual(len(self.commands()), 1)

    def test_threshold_after_ordinary_stops_retirement_and_docker(self):
        self.effects({'cel-disk-drain': {'delta': 5 * m.GIB}})
        self.assertEqual(self.controller().run(), 0)
        self.assertEqual([x[0] for x in self.commands()], ['cel-disk-release-drain', 'cel-disk-drain'])
        self.assertEqual(self.state()['producers']['ordinary-drain']['after_available_bytes'], m.TARGET)

    def test_threshold_after_retirement_stops_docker(self):
        self.effects({'cel-disk-retire': {'delta': 5 * m.GIB}})
        self.assertEqual(self.controller().run(), 0)
        self.assertEqual([x[0] for x in self.commands()], ['cel-disk-release-drain', 'cel-disk-drain', 'cel-disk-retire'])
        self.assertEqual(self.state()['producers']['preservation-retire']['after_available_bytes'], m.TARGET)

    def test_threshold_after_docker_records_measured_recovery(self):
        self.effects({'docker-sweep': {'delta': 5 * m.GIB}})
        self.assertEqual(self.controller().run(), 0)
        self.assertEqual(self.state()['producers']['docker-sweep']['after_available_bytes'], m.TARGET)
        self.assertEqual(self.mail('root'), [])

    def test_already_at_threshold_never_invokes_handler_units(self):
        self.free(m.TARGET)
        self.assertEqual(self.controller().run('ordinary-drain'), 0)
        self.assertEqual(self.commands(), [])

    def test_partial_failure_continues_measures_and_reports(self):
        self.effects({'cel-disk-release-drain': {'delta': m.GIB, 'rc': 1},
                      'cel-disk-drain': {'delta': m.GIB}})
        self.assertEqual(self.controller().run(), 1)
        s = self.state()
        self.assertEqual(s['capacity_deficit_bytes'], 3 * m.GIB)
        self.assertEqual(s['producers']['release-drain']['status'], 'failed')
        self.assertEqual(s['producers']['release-drain']['observed_df_delta_bytes'], m.GIB)
        self.assertEqual(s['producers']['ordinary-drain']['before_available_bytes'], 16 * m.GIB)
        self.assertEqual(self.mail('root'), [])
        self.assertEqual(len(self.mail('celestial-disk-cleanup')), 1)
        self.assertTrue(s['root_capacity_decision_deferred'])

    def test_idempotent_handlers_and_root_capacity_dedupe(self):
        self.effects({'cel-disk-release-drain': {'delta': m.GIB}})
        self.assertEqual(self.controller().run(), 2)
        self.assertEqual(self.controller().run(), 2)
        self.assertEqual(self.state()['after_available_bytes'], 16 * m.GIB)
        self.assertEqual(len(self.mail('root')), 1)
        self.assertEqual(len(self.mail('celestial-disk-cleanup')), 1)
        self.assertEqual(self.state()['observed_df_delta_bytes'], 0)

    def test_delivery_failure_and_false_ack_remain_debt(self):
        (self.h / 'fail-mail').touch()
        self.assertEqual(self.controller().run(), 3)
        self.assertTrue(self.state()['notifications']['root']['debt'])
        (self.h / 'fail-mail').unlink()
        (self.h / 'false-ack').touch()
        self.assertEqual(self.controller().run(), 3)
        self.assertTrue(self.state()['notifications']['root']['debt'])
        self.assertEqual(len(self.mail('root')), 1)  # future next_retry prevents resend
        self.retry_due()
        self.assertEqual(self.controller().run(), 3)
        self.assertEqual(len(self.mail('root')), 2)
        (self.h / 'false-ack').unlink()
        self.retry_due()
        self.assertEqual(self.controller().run(), 2)
        self.assertFalse(self.state()['notifications']['root']['debt'])
        self.assertEqual(len(self.mail('root')), 3)
        self.assertEqual(self.controller().run(), 2)
        self.assertEqual(len(self.mail('root')), 3)

    def test_emergency_is_new_capacity_decision(self):
        self.controller().run()
        self.free(m.GIB // 2)
        self.controller().run()
        self.assertEqual(len(self.mail('root')), 2)
        self.assertEqual(self.state()['notifications']['root']['key'], 'emergency-capacity')
        self.controller().run()
        self.assertEqual(len(self.mail('root')), 2)

    def test_timeout_is_real_failure_and_bounded(self):
        self.effects({'cel-disk-release-drain': {'sleep': 10}})
        start = time.monotonic()
        self.assertEqual(self.controller(handler_seconds=.15).run(), 1)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(self.state()['producers']['release-drain']['status'], 'timeout')
        self.assertEqual(self.state()['producers']['release-drain']['observed_df_delta_bytes'], 0)

    def test_whole_pass_budget_and_lock(self):
        c = self.controller(pass_seconds=.2)
        start = time.monotonic()
        self.assertIn(c.run(), (1, 3))  # timeout is failure; mail may finish within .2s
        self.assertLess(time.monotonic() - start, 2)
        self.assertFalse(any(x[0].startswith('cel-disk-') for x in self.commands()))
        self.assertEqual(self.state()['incomplete_handlers'], list(m.HANDLERS))
        self.assertTrue(all(self.state()['producers'][name]['status'] == 'skipped' for name in m.HANDLERS))
        self.assertEqual(self.mail('root'), [])
        lock = self.h / '.local/state/cel-disk-headroom/lock'
        with open(lock, 'a') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.controller().run(), 75)

    def test_missing_unknown_and_changed_handlers_fail_closed(self):
        (self.bin / 'cel-disk-release-drain').unlink()
        self.data['handler_sha256']['ordinary-drain'] = '0' * 64
        self.data['retire_notification_version'] = 0
        self.configure()
        self.assertEqual(self.controller().run(), 1)
        s = self.state()['producers']
        for name in m.DEFAULTS:
            self.assertEqual(s[name]['status'], 'failed')
        self.assertFalse(any(x[0].startswith('cel-disk-') for x in self.commands()))
        self.assertEqual(self.controller().handler('unknown')['status'], 'failed')

    def test_docker_requires_opt_in_and_live_safety_version(self):
        self.data['docker_opt_in'] = False
        self.configure()
        self.assertEqual(self.controller().run(), 1)
        self.assertFalse(any(x[1:3] == ['box', 'sweep-docker'] for x in self.commands()))
        self.assertEqual(self.mail('root'), [])
        self.assertEqual(len(self.mail('celestial-disk-cleanup')), 1)
        self.assertTrue(self.state()['root_capacity_decision_deferred'])
        self.data['docker_opt_in'] = True
        self.configure()
        (self.h / 'docker-version').write_text('0')
        self.assertEqual(self.controller().run(), 1)
        self.assertEqual(self.state()['producers']['docker-sweep']['status'], 'failed')
        self.assertFalse(any(x[1:3] == ['box', 'sweep-docker'] for x in self.commands()))
        (self.h / 'docker-version').write_text('1')
        self.assertEqual(self.controller().run(), 2)
        self.assertTrue(any(x[1:3] == ['box', 'sweep-docker'] for x in self.commands()))
        self.assertFalse(any(x in ('prune', 'rm') for cmd in self.commands() for x in cmd))

    def test_producer_gaps_are_status_not_deletion_authority(self):
        self.controller().run()
        s = self.state()
        for name in ('gate-runs', 'follow-main-executor-images', 'miniflare-tracing'):
            self.assertEqual(s['producers'][name]['status'], 'missing-adapter')
            self.assertIn('blocked_since', s['producers'][name])
            self.assertIn('next_retry', s['producers'][name])
        self.assertEqual(s['producers']['stale-worktrees']['handler'], 'preservation-retire')
        self.assertEqual(s['docker_facts']['container_writable']['status'], 'ok')
        self.assertEqual(s['docker_facts']['system_df']['status'], 'ok')

    def test_queue_staleness_is_explicit_status_not_authority(self):
        q = self.h / '.cache/slot-builder-iso/release-queue.json'
        q.parent.mkdir(parents=True)
        q.write_text(json.dumps({'version': 1, 'issuer': 'fixture-producer',
                                 'generated_at': '2020-01-01T00:00:00Z', 'entries': [], 'held_count': 3}))
        self.controller().run()
        row = self.state()['producers']['gate-runs']
        self.assertEqual(row['status'], 'blocked')
        self.assertGreater(row['queue_age_seconds'], 3600)
        self.assertEqual(row['held_count'], 3)
        q.write_text('[]')
        self.controller().run()
        self.assertEqual(self.state()['producers']['gate-runs']['status'], 'missing-adapter')

    def test_conflicting_dropin_does_not_replace_config_or_controller(self):
        file = self.h / '.config/systemd/user/cel-disk-retire.service.d/50-headroom.conf'
        file.parent.mkdir(parents=True)
        file.write_text('operator owned\n')
        config = self.h / '.config/cel/disk-headroom.json'
        config.parent.mkdir(parents=True)
        config.write_text('original config')
        with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=inactive\n', '')):
            with self.assertRaises(ValueError):
                self.install()
        self.assertEqual(config.read_text(), 'original config')
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())
        self.assertEqual(file.read_text(), 'operator owned\n')

    def test_installer_preserves_scripts_and_does_not_toggle_timers(self):
        originals = {p: p.read_bytes() for p in self.bin.iterdir()}
        calls = []
        def systemctl(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, 'LoadState=loaded\nActiveState=inactive\n', '')
        with patch.object(installer.subprocess, 'run', systemctl):
            self.install()
            self.install()
        for p, b in originals.items():
            self.assertEqual(p.read_bytes(), b)
        self.assertFalse(any(x in ('stop', 'disable', 'enable', 'start') for cmd in calls for x in cmd))
        for name in installer.UNITS:
            text = (self.h / '.config/systemd/user' / (name + '.service.d/50-headroom.conf')).read_text()
            self.assertIn('ExecStart=\nExecStart=', text)
            self.assertIn('KillMode=control-group', text)
            self.assertIn('SuccessExitStatus=75', text)
            self.assertIn('cel-disk-headroom', text)
        monitor = (self.h / '.config/systemd/user/cel-disk-monitor.service.d/50-headroom.conf').read_text()
        self.assertIn(' run\n', monitor)
        installed_config = json.loads((self.h / '.config/cel/disk-headroom.json').read_text())
        self.assertEqual(installed_config['release_queue_issuer'], self.data['release_queue_issuer'])

    def test_installer_refuses_active_or_unknown_units(self):
        for output in ('LoadState=loaded\nActiveState=active\n', 'LoadState=not-found\nActiveState=inactive\n'):
            with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises(ValueError):
                    installer.install(self.h, self.bin / 'cel', {}, apply=True,
                                      release_queue_issuer=self.data['release_queue_issuer'])
            self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())

    def test_migration_respects_direct_controller_lock(self):
        c = self.controller()
        with open(c.directory / 'lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(ValueError):
                installer.install(self.h, self.bin / 'cel', {}, apply=True,
                                  release_queue_issuer=self.data['release_queue_issuer'])

    def test_production_adapter_strips_unsafe_standalone_test_hooks(self):
        c = self.controller()
        c.load()
        with patch.dict(os.environ, {'CEL_RETIRE_MIN_FREE': '0',
                                     'CEL_RETIRE_HOOK_AFTER_COPY': 'unsafe', 'CEL_DRAIN_ROOT': '/elsewhere'}):
            with patch.object(c, 'command', return_value={'status': 'ok'}) as command:
                self.assertEqual(c.handler('preservation-retire')['status'], 'ok')
        environment = command.call_args.args[2]
        for key in ('CEL_RETIRE_MIN_FREE', 'CEL_RETIRE_HOOK_AFTER_COPY', 'CEL_DRAIN_ROOT'):
            self.assertNotIn(key, environment)
        self.assertEqual(environment['CEL_RETIRE_NOTIFY_RECIPIENT'], 'celestial-disk-cleanup')

    def test_last_handler_cannot_consume_notification_reserve(self):
        self.effects({'docker-sweep': {'sleep': 10}})
        start = time.monotonic()
        self.assertEqual(self.controller(pass_seconds=1.5, handler_seconds=10, control_reserve=1).run(), 1)
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(self.state()['producers']['docker-sweep']['status'], 'timeout')
        self.assertEqual(len(self.mail('celestial-disk-cleanup')), 1)
        self.assertEqual(self.mail('root'), [])

    def test_skipped_handlers_defer_root_but_emergency_is_explicit(self):
        self.assertEqual(self.controller(pass_seconds=2, control_reserve=3).run(), 1)
        self.assertEqual(self.state()['incomplete_handlers'], list(m.HANDLERS))
        self.assertEqual(len(self.mail('celestial-disk-cleanup')), 1)
        self.assertEqual(self.mail('root'), [])
        self.free(m.GIB // 2)
        self.assertEqual(self.controller(pass_seconds=2, control_reserve=3).run(), 1)
        self.assertEqual(len(self.mail('root')), 1)
        self.assertIn('Maintenance is incomplete', self.mail('root')[0][4])

    def test_debt_retry_occurs_at_due_boundary_not_before(self):
        c = self.controller()
        c.load()
        c.state['notifications']['root'] = {'key': 'capacity', 'debt': True, 'next_retry': 1234}
        with patch.object(m.time, 'time', return_value=1233):
            self.assertFalse(c.notify('root', 'capacity', 'decision'))
        self.assertEqual(self.mail('root'), [])
        with patch.object(m.time, 'time', return_value=1234):
            self.assertTrue(c.notify('root', 'capacity', 'decision'))
        self.assertEqual(len(self.mail('root')), 1)

    def test_missing_cel_configuration_finishes_failed_phase(self):
        self.data.pop('cel')
        self.configure()
        self.assertEqual(self.controller().run('docker-sweep'), 1)
        self.assertEqual(self.state()['producers']['docker-sweep']['status'], 'failed')
        self.assertNotEqual(self.state()['pass_status'], 'running')

    def test_installed_cli_change_between_capability_and_sweep_cannot_swap_runtime(self):
        (self.h / 'mutate-cli').touch()
        self.assertEqual(self.controller().run('docker-sweep'), 0)
        self.assertEqual(self.state()['producers']['docker-sweep']['status'], 'ok')
        self.assertNotEqual(m.executable_digest(self.bin / 'cel'), self.data['cel_sha256'])
        self.assertTrue(any(cmd[1:3] == ['box', 'sweep-docker'] for cmd in self.commands()))

    def test_changed_sourced_cli_library_fails_before_dispatch(self):
        (self.h / '.local/lib/box.sh').write_text('# changed after review\n')
        self.assertEqual(self.controller().run('docker-sweep'), 1)
        self.assertEqual(self.commands(), [])
        self.assertIn('runtime SHA256', self.state()['producers']['docker-sweep']['output'])

    def test_later_execstart_override_is_refused_before_install(self):
        path = self.h / '.config/systemd/user/cel-disk-monitor.service.d/90-override.conf'
        path.parent.mkdir(parents=True)
        path.write_text('[Service]\nExecStart=\nExecStart=/old/monitor\n')
        with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=inactive\n', '')):
            with self.assertRaisesRegex(ValueError, 'later drop-in'):
                self.install()
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())
        self.assertIn('/old/monitor', path.read_text())

    def installation_preimages(self):
        paths = [self.h / '.local/lib/cel-disk-headroom/controller.py',
                 self.h / '.local/bin/cel-disk-headroom', self.h / '.config/cel/disk-headroom.json']
        paths.extend(self.h / '.config/systemd/user' / (name + '.service.d/50-headroom.conf') for name in installer.UNITS)
        return {p: (p.read_bytes(), p.stat().st_mode & 0o777) for p in paths}

    def assert_preimages(self, originals):
        self.assertEqual(self.installation_preimages(), originals)
        manifests = list((self.h / '.local/state/cel-disk-headroom/install-backups').glob('*/manifest.json'))
        self.assertTrue(manifests)
        self.assertTrue(all(json.loads(p.read_text())['files'] for p in manifests))

    def test_daemon_reload_failure_restores_all_preimages_and_modes(self):
        good = subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=inactive\n', '')
        with patch.object(installer.subprocess, 'run', return_value=good):
            self.install()
        config = self.h / '.config/cel/disk-headroom.json'
        config.write_text('original config\n')
        config.chmod(0o640)
        originals = self.installation_preimages()
        reloads = []
        def fail_reload(argv, **kwargs):
            if argv[-1] == 'daemon-reload':
                reloads.append(argv)
                if len(reloads) == 1:
                    raise subprocess.CalledProcessError(1, argv)
            return good
        with patch.object(installer.subprocess, 'run', fail_reload):
            with self.assertRaisesRegex(ValueError, 'preimages restored'):
                self.install()
        self.assertEqual(len(reloads), 2)
        self.assert_preimages(originals)

    def test_post_replace_write_failure_restores_new_and_existing_paths(self):
        config = self.h / '.config/cel/disk-headroom.json'
        config.parent.mkdir(parents=True)
        config.write_text('before\n')
        config.chmod(0o640)
        replace = installer.replace_bytes
        injected = []
        def fail_after_replace(path, data, mode):
            replace(path, data, mode)
            if path == config and not injected:
                injected.append(True)
                raise OSError('injected ENOSPC after replace')
        with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=inactive\n', '')):
            with patch.object(installer, 'replace_bytes', fail_after_replace):
                with self.assertRaisesRegex(ValueError, 'preimages restored'):
                    self.install()
        self.assertEqual(config.read_text(), 'before\n')
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())
        self.assertFalse((self.h / '.local/bin/cel-disk-headroom').exists())
        self.assertTrue(injected)

    def test_manager_loaded_later_override_is_refused(self):
        path = self.h / 'manager/95-runtime.conf'
        path.parent.mkdir()
        path.write_text('[Service]\nExecStart=/old/runtime\n')
        result = subprocess.CompletedProcess([], 0, f'LoadState=loaded\nActiveState=inactive\nDropInPaths={path}\n', '')
        with patch.object(installer.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(ValueError, 'later drop-in'):
                self.install()
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())

    def test_capability_timeout_stays_timeout_not_completed_failure(self):
        c = self.controller()
        c.load()
        with patch.object(c, 'command', return_value={'status': 'timeout', 'output': 'deadline'}) as command:
            result = c.phase('docker-sweep')
        self.assertEqual(result['status'], 'timeout')
        self.assertEqual(command.call_count, 1)
        self.assertEqual(self.state()['producers']['docker-sweep']['status'], 'timeout')

    def test_describe_cli_prints_candidates_without_install(self):
        r = subprocess.run(['/usr/bin/python3', '-B', str(HERE / 'install.py'),
                            '--cel', str(self.bin / 'cel'), '--describe-cel'],
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        value = json.loads(r.stdout)
        self.assertEqual(value['cel_sha256'], self.data['cel_sha256'])
        self.assertEqual(value['docker_runtime_sha256'], self.data['docker_runtime_sha256'])
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())

    def test_inherited_cel_root_cannot_redirect_snapshot_or_notification(self):
        bad = self.h / 'untrusted-root'
        bad.mkdir()
        marker = self.h / 'untrusted-executed'
        (bad / 'intruder.py').write_text(f'pathlib.Path({str(marker)!r}).touch(); raise SystemExit(99)\n')
        with patch.dict(os.environ, {'CEL_ROOT': str(bad)}):
            self.assertEqual(self.controller().run('docker-sweep'), 0)
            c = self.controller()
            c.load()
            self.assertTrue(c.notify('root', 'fixture', 'private fixture enqueue'))
        self.assertFalse(marker.exists())
        roots = (self.h / 'cli-roots').read_text().splitlines()
        self.assertEqual(len(roots), 3)
        self.assertTrue(all(value.startswith(str(c.directory / 'docker-runtime-')) for value in roots[:2]))
        self.assertEqual(roots[2], str(self.bin.parent))

    def test_queue_issuer_requires_exact_reviewed_configuration(self):
        q = self.h / '.cache/slot-builder-iso/release-queue.json'
        q.parent.mkdir(parents=True)
        c = self.controller()
        c.load()
        queue = {'version': 1, 'generated_at': m.datetime.datetime.now(m.datetime.timezone.utc).isoformat(),
                 'entries': [], 'held_count': 0}
        for issuer in (None, '', 'different-producer', 'FIXTURE-PRODUCER'):
            with self.subTest(issuer=issuer):
                q.write_text(json.dumps(dict(queue, issuer=issuer)))
                c.producer_facts()
                self.assertEqual(self.state()['producers']['gate-runs']['status'], 'missing-adapter')
        q.write_text(json.dumps(dict(queue, issuer=self.data['release_queue_issuer'])))
        c.producer_facts()
        self.assertEqual(self.state()['producers']['gate-runs']['status'], 'observed')

    def test_missing_or_invalid_issuer_refuses_config_and_install(self):
        for issuer in (None, '', '   ', 7):
            with self.subTest(issuer=issuer):
                self.data['release_queue_issuer'] = issuer
                self.configure()
                with self.assertRaisesRegex(ValueError, 'explicit reviewed'):
                    self.controller().load()
                with self.assertRaisesRegex(ValueError, 'explicit reviewed'):
                    installer.install(self.h, self.bin / 'cel', {}, apply=True, release_queue_issuer=issuer)
        self.data.pop('release_queue_issuer')
        self.configure()
        with self.assertRaisesRegex(ValueError, 'explicit reviewed'):
            self.controller().load()
        self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())

    def test_follow_main_is_optional_and_invalid_configuration_fails_closed(self):
        row = self.observe_follow()
        self.assertEqual(row['status'], 'missing-adapter')
        self.assertEqual(row['authorization'], 'none')
        for value in (None, '', '  ', 4, [], {}, 'x' * 257, 'issuer\n'):
            with self.subTest(value=value):
                self.data['follow_main_issuer'] = value
                self.configure()
                with self.assertRaisesRegex(ValueError, 'follow-main issuer'):
                    self.controller().load()
                if value is not None:
                    with self.assertRaisesRegex(ValueError, 'follow-main issuer'):
                        installer.install(self.h, self.bin / 'cel', {}, follow_main_issuer=value)

    def test_follow_main_observes_retention_not_authorization(self):
        path, data, _ = self.follow_manifest()
        row = self.observe_follow()
        self.assertEqual(row['status'], 'observed', row)
        for key in ('live', 'rollback', 'base', 'generated_at'):
            self.assertEqual(row[key], data[key])
        self.assertEqual(row['candidate_count'], 1)
        self.assertLess(row['publication_age_seconds'], 10)
        self.assertTrue(row['source_controlled_deletion_disabled'])
        self.assertEqual(row['authorization'], 'none')
        self.assertNotIn('worktree_candidates', row)
        data['rollback'] = None
        data.pop('retired_this_pass')
        data['worktree_candidates'] = []
        path.write_text(json.dumps(data))
        row = self.observe_follow()
        self.assertEqual(row['status'], 'observed')
        self.assertIsNone(row['rollback'])
        self.assertEqual(row['candidate_count'], 0)
        self.assertEqual(self.commands(), [])

    def test_follow_main_rejects_unknown_malformed_stale_and_duplicate_facts(self):
        path, original, _ = self.follow_manifest()
        cases = [
            {'version': True}, {'version': 2}, {'issuer': 'different-issuer'},
            {'issuer': original['issuer'].upper()}, {'issuer': None}, {'unknown': []},
            {'generated_at': '2020-01-01T00:00:00Z'},
            {'generated_at': '2026-01-01T00:00:00'},
            {'generated_at': '2026-01-01T01:00:00+01:00'},
            {'generated_at': '2026-99-01T00:00:00Z'},
            {'generated_at': (m.datetime.datetime.now(m.datetime.timezone.utc) + m.datetime.timedelta(seconds=120)).isoformat()},
            {'live': None}, {'live': dict(original['live'], extra=True)},
            {'live': dict(original['live'], image='other:tag')},
            {'live': dict(original['live'], worktree=str(self.h / 'elsewhere/local-' ) + 'a' * 12)},
            {'rollback': original['live']}, {'base': dict(original['base'], label='cel.keep=false')},
            {'base': dict(original['base'], image='invalid image')},
            {'worktree_candidates': None}, {'worktree_candidates': original['worktree_candidates'] * 2},
            {'worktree_candidates': original['worktree_candidates'] * 257},
            {'worktree_candidates': [dict(original['worktree_candidates'][0], head='d' * 40)]},
            {'worktree_candidates': [dict(original['worktree_candidates'][0], head='c' * 39)]},
            {'rollback': {'worktree': str(self.h / 'code/slot-studio-wt' / ('local-' + 'a' * 40)),
                          'image': 'slot-studio-local/media-executor:' + 'a' * 40}},
            {'worktree_candidates': [{'path': str(self.h / 'code/slot-studio-wt' / ('local-' + 'a' * 40)),
                                      'head': 'a' * 40}]},
            {'worktree_candidates': [dict(original['worktree_candidates'][0], extra=True)]},
            {'worktree_candidates': [{'path': original['live']['worktree'], 'head': 'a' * 40}]},
            {'retired_this_pass': ['not-a-grant']},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                path.write_text(json.dumps(dict(original, **changes)))
                row = self.observe_follow()
                self.assertEqual(row['status'], 'blocked')
                self.assertEqual(row['authorization'], 'none')
                self.assertNotIn('candidate_count', row)
        for raw in ('{}', '[]', '{', json.dumps(original)[:-1] + ', "version": 1}', 'x' * 65537):
            with self.subTest(raw=raw[:30]):
                path.write_text(raw)
                self.assertEqual(self.observe_follow()['status'], 'blocked')

    def test_follow_main_timestamp_freshness_boundaries(self):
        path, data, _ = self.follow_manifest()
        stamp = m.datetime.datetime.fromisoformat(data['generated_at']).timestamp()
        for age, expected in ((-61, 'blocked'), (-60, 'observed'), (600, 'observed'), (601, 'blocked')):
            with self.subTest(age=age), patch.object(m.time, 'time', return_value=stamp + age):
                self.assertEqual(self.observe_follow()['status'], expected)

    def test_follow_main_owned_nonsymlink_bounded_files_and_metadata(self):
        path, data, metadata = self.follow_manifest()
        candidate_git = Path(data['worktree_candidates'][0]['path']) / '.git'
        for target in (path, candidate_git, metadata / 'HEAD'):
            with self.subTest(target=target):
                before = target.read_bytes()
                target.chmod(0o666)
                self.assertEqual(self.observe_follow()['status'], 'blocked')
                target.chmod(0o600)
                saved = target.with_name(target.name + '.saved')
                target.rename(saved)
                target.symlink_to(saved)
                self.assertEqual(self.observe_follow()['status'], 'blocked')
                target.unlink()
                os.mkfifo(target, 0o600)
                self.assertEqual(self.observe_follow()['status'], 'blocked')
                target.unlink()
                saved.rename(target)
                self.assertEqual(target.read_bytes(), before)
        c = self.controller()
        c.load()
        with patch.object(m.os, 'getuid', return_value=os.getuid() + 1):
            self.assertEqual(c.follow_main_facts()['status'], 'blocked')
        for directory in (path.parent, metadata, candidate_git.parent):
            saved = directory.with_name(directory.name + '.saved')
            directory.rename(saved)
            directory.symlink_to(saved, target_is_directory=True)
            self.assertEqual(self.observe_follow()['status'], 'blocked')
            directory.unlink()
            saved.rename(directory)
        path.unlink()
        self.assertEqual(self.observe_follow()['status'], 'blocked')

    def test_follow_main_head_metadata_mismatch_and_escape_are_blocked(self):
        _, data, metadata = self.follow_manifest()
        head = metadata / 'HEAD'
        for value in ('d' * 40, 'ref: refs/heads/main', 'x' * 129):
            head.write_text(value + '\n')
            self.assertEqual(self.observe_follow()['status'], 'blocked')
        head.write_text('c' * 40 + '\n')
        pointer = Path(data['worktree_candidates'][0]['path']) / '.git'
        for value in ('gitdir: /elsewhere', 'gitdir: relative/path', 'malformed'):
            pointer.write_text(value + '\n')
            self.assertEqual(self.observe_follow()['status'], 'blocked')
        self.assertEqual(self.commands(), [])

    def test_installer_carries_optional_observer_identity_transactionally(self):
        good = subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=inactive\n', '')
        with patch.object(installer.subprocess, 'run', return_value=good):
            self.install()
            config = self.h / '.config/cel/disk-headroom.json'
            self.assertNotIn('follow_main_issuer', json.loads(config.read_text()))
            installer.install(self.h, self.bin / 'cel', self.data['handler_sha256'],
                              True, True, True, self.data['cel_sha256'], self.data['docker_runtime_sha256'],
                              self.data['release_queue_issuer'], 'fixture-follow-main')
        self.assertEqual(json.loads(config.read_text())['follow_main_issuer'], 'fixture-follow-main')
        previous = config.read_bytes()
        def fail_reload(argv, **kwargs):
            if 'daemon-reload' in argv:
                raise subprocess.CalledProcessError(1, argv, stderr='fixture failure')
            return good
        with patch.object(installer.subprocess, 'run', fail_reload):
            with self.assertRaisesRegex(ValueError, 'rollback'):
                installer.install(self.h, self.bin / 'cel', self.data['handler_sha256'],
                                  True, True, True, self.data['cel_sha256'], self.data['docker_runtime_sha256'],
                                  self.data['release_queue_issuer'], 'different-fixture-issuer')
        self.assertEqual(config.read_bytes(), previous)

    def test_native_manifest_observer_reads_real_detached_metadata_without_mutation(self):
        path, data, old_metadata = self.follow_manifest()
        candidate = Path(data['worktree_candidates'][0]['path'])
        (candidate / '.git').unlink()
        candidate.rmdir()
        (old_metadata / 'HEAD').unlink()
        old_metadata.rmdir()
        repo = self.h / 'code/slot-studio'
        def git(*args):
            result = subprocess.run(['/usr/bin/git', '-C', str(repo), *args],
                                    capture_output=True, text=True, timeout=10, umask=0o077,
                                    env=dict(os.environ, HOME=str(self.h), GIT_CONFIG_GLOBAL='/dev/null',
                                             GIT_CONFIG_NOSYSTEM='1', GIT_TEMPLATE_DIR=''))
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        git('init', '-b', 'main')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'fixture')
        head = git('rev-parse', 'HEAD')
        candidate = candidate.parent / ('local-' + head[:12])
        git('worktree', 'add', '--detach', str(candidate), head)
        data['worktree_candidates'] = [{'path': str(candidate), 'head': head}]
        path.write_text(json.dumps(data))
        def snapshot():
            return {str(p.relative_to(self.h)): (p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns)
                    for root in (self.h / 'code', self.h / '.cache', self.bin)
                    for p in root.rglob('*') if p.is_file()}
        before = snapshot()
        program = ('import importlib.util,json,pathlib,sys; '
                   's=importlib.util.spec_from_file_location("headroom",sys.argv[1]); '
                   'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                   'c=m.Controller(pathlib.Path.home(),sys.argv[2]); c.load(); c.producer_facts(); '
                   'print(json.dumps(c.state["producers"]))')
        result = subprocess.run(['/usr/bin/python3', '-B', '-c', program, str(HERE / 'controller.py'), str(self.config)],
                                env=dict(os.environ, HOME=str(self.h)), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        producers = json.loads(result.stdout)
        row = producers['follow-main-executor-images']
        self.assertEqual(row['status'], 'observed')
        self.assertEqual(row['candidate_count'], 1)
        self.assertEqual(row['live'], data['live'])
        self.assertEqual(row['rollback'], data['rollback'])
        self.assertEqual(row['base'], data['base'])
        self.assertEqual(row['authorization'], 'none')
        self.assertTrue(row['source_controlled_deletion_disabled'])
        self.assertEqual(producers['miniflare-tracing']['status'], 'missing-adapter')
        self.assertEqual(snapshot(), before)
        self.assertTrue(candidate.exists())
        self.assertEqual(self.commands(), [['docker', 'system', 'df', '--format', '{{json .}}'],
                                           ['docker', 'ps', '-a', '--size', '--format', '{{json .}}']])


if __name__ == '__main__':
    unittest.main()
