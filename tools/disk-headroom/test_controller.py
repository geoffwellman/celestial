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
 if sys.argv[1:3]==['box','docker-safety']:
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
        self.env = patch.dict(os.environ, {'FIXTURE_HOME': str(self.h), 'PATH': str(self.bin) + ':/usr/bin:/bin'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.config = self.h / 'config.json'
        self.data = {'version': 1, 'cel': str(self.bin / 'cel'), 'docker_opt_in': True,
                     'retire_notification_version': 1, 'handler_sha256': {
                         name: hashlib.sha256((self.bin / binary).read_bytes()).hexdigest()
                         for name, (binary, _) in m.DEFAULTS.items()}}
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
        self.assertEqual(len(self.mail('root')), 1)
        self.assertTrue(s['notifications']['root']['acked_at'])
        self.assertFalse(s['notifications']['root']['debt'])

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
        (self.h / 'false-ack').unlink()
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
        q.write_text(json.dumps({'version': 1, 'issuer': 'standout-slot-builder',
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
                installer.install(self.h, self.bin / 'cel', {}, docker=True, apply=True)
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
            installer.install(self.h, self.bin / 'cel', self.data['handler_sha256'], True, True, True)
            installer.install(self.h, self.bin / 'cel', self.data['handler_sha256'], True, True, True)
        for p, b in originals.items():
            self.assertEqual(p.read_bytes(), b)
        self.assertFalse(any(x in ('stop', 'disable', 'enable', 'start') for cmd in calls for x in cmd))
        for name in installer.UNITS:
            text = (self.h / '.config/systemd/user' / (name + '.service.d/50-headroom.conf')).read_text()
            self.assertIn('ExecStart=\nExecStart=', text)
            self.assertIn('KillMode=control-group', text)
            self.assertIn('cel-disk-headroom', text)
        monitor = (self.h / '.config/systemd/user/cel-disk-monitor.service.d/50-headroom.conf').read_text()
        self.assertIn(' run\n', monitor)

    def test_installer_refuses_active_or_unknown_units(self):
        for output in ('LoadState=loaded\nActiveState=active\n', 'LoadState=not-found\nActiveState=inactive\n'):
            with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises(ValueError):
                    installer.install(self.h, self.bin / 'cel', {}, apply=True)
            self.assertFalse((self.h / '.local/lib/cel-disk-headroom/controller.py').exists())

    def test_migration_respects_direct_controller_lock(self):
        c = self.controller()
        with open(c.directory / 'lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(ValueError):
                installer.install(self.h, self.bin / 'cel', {}, apply=True)

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


if __name__ == '__main__':
    unittest.main()
