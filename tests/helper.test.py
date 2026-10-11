import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'assets/blocker.sh'

@unittest.skipIf(os.geteuid() == 0, 'Never exercise the production hosts target as root')
class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hosts = Path(self.tmp.name) / 'hosts'
        self.original = b'127.0.0.1 localhost\n::1 localhost\n# unrelated\n'
        self.hosts.write_bytes(self.original)
        self.clock_path = Path(str(self.hosts) + '.clock.json')
        self.state_path = Path(str(self.hosts) + '.state.json')
        self.clock = {'bootID': 'fixture-boot', 'uptimeMs': 100000, 'wallMs': 1700000000000, 'unlocked': True, 'available': True}
        self.save_clock()

    def save_clock(self):
        self.clock_path.write_text(json.dumps(self.clock))

    def advance(self, milliseconds, *, wall_only=False):
        self.clock['wallMs'] += milliseconds
        if not wall_only:
            self.clock['uptimeMs'] += milliseconds
        self.save_clock()

    def result(self, *args):
        return subprocess.run(['/bin/bash', str(HELPER), *args], env={**os.environ, 'HOSTS_FILE': str(self.hosts)}, capture_output=True, text=True, timeout=15)

    def error(self, code, *args):
        result = self.result(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stderr)['code'], code, result.stderr)

    def unblock(self, *args):
        request = json.loads(self.run_helper('request-unblock', *args))
        self.advance(60000)
        return self.run_helper('confirm-unblock', request['id'], 'Need this site for the current task')

    def pomodoro(self, *args):
        return json.loads(self.run_helper(*(args or ('pomodoro-status',))))

    def start_pomodoro(self, rounds='4'):
        return self.pomodoro('start-pomodoro', '1', '1', '2', rounds, 'Deep work', 'example.com', 'www.example.com')

    def finish_round(self, monitor='monitor-one'):
        status = self.pomodoro('pomodoro-checkpoint', monitor)
        while status['phase'] == 'focus':
            self.advance(min(10000, status['remainingMs']))
            status = self.pomodoro('pomodoro-checkpoint', monitor)
        return status

    def run_helper(self, *args, ok=True):
        result = self.result(*args)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout

    def test_overlap_and_ipv6(self):
        self.run_helper('add', 'example.com', 'manual')
        self.run_helper('add-many', 'social', 'example.com', 'www.example.com')
        self.run_helper('start-focus', '1', 'Social focus', 'example.com', 'focus.example.com')
        self.assertIn('example.com\tfocus,manual,social', self.run_helper('list'))
        self.assertIn('::1 example.com # manual', self.hosts.read_text())
        self.error('FOCUS_LOCKED', 'end-focus')
        self.advance(60000)
        self.run_helper('expire')
        self.unblock('remove-all-with-tag', 'social')
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\n')
        self.assertEqual(json.loads(self.run_helper('session')), None)

    def test_expiry_and_replacement(self):
        self.run_helper('start-focus', '1', 'First', 'one.com')
        self.error('FOCUS_LOCKED', 'start-focus', '2', 'Second', 'two.com')
        self.advance(60000)
        self.run_helper('start-focus', '2', 'Second', 'two.com')
        self.assertEqual(self.run_helper('list'), 'two.com\tfocus\n')
        session = json.loads(self.run_helper('session'))
        data = self.hosts.read_text().replace(str(session['endsAt']), '1')
        self.hosts.write_text(data)
        self.run_helper('expire')
        self.assertEqual(self.run_helper('list'), '')
        self.assertEqual(json.loads(self.run_helper('session')), None)

    def test_validation_is_transactional(self):
        for args in [('add', '-bad.com', 'manual'), ('add', 'a.com\nlocalhost', 'manual'), ('add', 'a.com', 'focus'), ('start-focus', 'NaN', 'bad', 'a.com'), ('start-focus', '1441', 'bad', 'a.com'), ('add-many', 'social', 'good.com', 'bad'), ('remove-all-with-tag', 'focus'), ('nope',)]:
            self.run_helper(*args, ok=False)
            self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_failed_replacement_keeps_previous_session(self):
        self.run_helper('start-focus', '10', 'Existing', 'example.com')
        before = self.hosts.read_bytes()
        self.run_helper('start-focus', '5', 'Replacement', 'good.com', 'invalid', ok=False)
        self.assertEqual(self.hosts.read_bytes(), before)
        self.assertEqual(json.loads(self.run_helper('session'))['label'], 'Existing')

    def test_interpreter_environment_is_discarded(self):
        result = subprocess.run(['/bin/bash', str(HELPER), 'add', 'example.com', 'manual'], env={**os.environ, 'HOSTS_FILE': str(self.hosts), 'PERL5OPT': '-MNonexistentModule'}, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\n')

    def test_marker_boundaries_and_byte_preservation(self):
        prefix = b'# custom\r\n127.0.0.1 localhost\n'
        suffix = b'# final without newline'
        for before in (b'', prefix):
            self.hosts.write_bytes(before + b'# >>> productivity-os >>>\n# <<< productivity-os <<<\n' + suffix)
            self.run_helper('add', 'example.com', 'manual')
            self.unblock('remove-everything')
            self.assertEqual(self.hosts.read_bytes(), before + suffix)

    def test_malformed_markers_fail_without_writes(self):
        for data in (b'# >>> productivity-os >>>\n', b'# <<< productivity-os <<<\n# >>> productivity-os >>>\n', b'# >>> productivity-os >>>\n# >>> productivity-os >>>\n# <<< productivity-os <<<\n'):
            self.hosts.write_bytes(data)
            self.run_helper('add', 'example.com', 'manual', ok=False)
            self.assertEqual(self.hosts.read_bytes(), data)

    def test_concurrent_mutations(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda i: self.run_helper('add', f'site{i}.com', 'manual'), range(20)))
        self.assertEqual(len(self.run_helper('list').splitlines()), 20)

    def test_idempotence_and_legacy_entries(self):
        self.hosts.write_bytes(self.original + b'# >>> productivity-os >>>\n127.0.0.1 example.com # manual\n# <<< productivity-os <<<\n')
        self.run_helper('add', 'example.com', 'manual')
        self.run_helper('add', 'example.com', 'social')
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual,social\n')
        self.unblock('remove', 'example.com')
        self.unblock('remove', 'example.com')
        self.assertEqual(self.run_helper('list'), '')

    def test_site_blocker_section_is_adopted(self):
        prefix = b'# custom\r\n127.0.0.1 localhost\n'
        suffix = b'# final without newline'
        legacy = b'# >>> site-blocker >>>\n# focus-session {"endsAt":99999999999999,"label":"Old"}\n127.0.0.1 example.com # focus\n::1 example.com # focus\n127.0.0.1 example.com # manual\n::1 example.com # manual\n# <<< site-blocker <<<\n'
        self.hosts.write_bytes(prefix + legacy + suffix)
        self.assertEqual(self.run_helper('list'), 'example.com\tfocus,manual\n')
        self.assertEqual(json.loads(self.run_helper('session')), {'endsAt': 99999999999999, 'label': 'Old'})
        data = self.hosts.read_bytes()
        entries = legacy.split(b'\n', 2)[2].replace(b'site-blocker', b'productivity-os')
        self.assertTrue(data.startswith(prefix + b'# >>> productivity-os >>>\n# focus-session {'), data)
        self.assertTrue(data.endswith(entries + suffix), data)
        self.assertNotIn(b'site-blocker', data)
        self.hosts.write_bytes(prefix + b'# >>> site-blocker >>>\n# <<< site-blocker <<<\n' + suffix)
        self.run_helper('expire')
        self.assertEqual(self.hosts.read_bytes(), prefix + suffix)

    def test_mixed_or_malformed_site_blocker_markers_fail_without_writes(self):
        for data in (b'# >>> site-blocker >>>\n# <<< site-blocker <<<\n# >>> productivity-os >>>\n# <<< productivity-os <<<\n', b'# >>> productivity-os >>>\n# <<< site-blocker <<<\n', b'# >>> site-blocker >>>\n', b'# <<< site-blocker <<<\n# >>> site-blocker >>>\n'):
            self.hosts.write_bytes(data)
            self.run_helper('list', ok=False)
            self.assertEqual(self.hosts.read_bytes(), data)

    def test_remove_tag_leaves_other_tags(self):
        self.run_helper('add-many', 'social', 'example.com', 'www.example.com')
        self.run_helper('add-many', 'manual', 'example.com', 'other.com')
        self.unblock('remove-tag', 'example.com', 'manual')
        self.unblock('remove-tag', 'other.com', 'manual')
        self.assertEqual(self.run_helper('list'), 'example.com\tsocial\nwww.example.com\tsocial\n')
        before = self.hosts.read_bytes()
        self.unblock('remove-tag', 'example.com', 'manual')
        self.unblock('remove-tag', 'absent.com', 'manual')
        self.assertEqual(self.hosts.read_bytes(), before)
        for args in (('remove-tag', 'example.com'), ('remove-tag', 'example.com', 'focus'), ('remove-tag', 'bad', 'manual')):
            self.run_helper(*args, ok=False)
            self.assertEqual(self.hosts.read_bytes(), before)

    def test_unrecognized_lines_in_the_section_fail_without_writes(self):
        for line in (b'0.0.0.0 zero.com # manual', b'127.0.0.1 a.com # manual trailing words', b'not a hosts line'):
            data = self.original + b'# >>> productivity-os >>>\n127.0.0.1 example.com # manual\n' + line + b'\n# <<< productivity-os <<<\n'
            self.hosts.write_bytes(data)
            result = subprocess.run(['/bin/bash', str(HELPER), 'add', 'new.com', 'manual'], env={**os.environ, 'HOSTS_FILE': str(self.hosts)}, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(line.decode(), result.stderr)
            self.assertEqual(self.hosts.read_bytes(), data)

    def test_comments_and_blank_lines_in_the_section_are_kept(self):
        self.hosts.write_bytes(self.original + b'# >>> productivity-os >>>\n# my note\n\n127.0.0.1 example.com # manual\n# <<< productivity-os <<<\n')
        self.run_helper('add', 'new.com', 'manual')
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\nnew.com\tmanual\n')
        self.assertIn('# my note\n', self.hosts.read_text())

    def test_unicode_label_round_trips(self):
        self.run_helper('start-focus', '5', 'Café ☕ focus', 'example.com')
        self.assertEqual(json.loads(self.run_helper('session'))['label'], 'Café ☕ focus')
        self.advance(300000)
        self.assertEqual(json.loads(self.run_helper('start-focus', '5', 'Plain', 'example.com'))['label'], 'Plain')
        result = subprocess.run(['/bin/bash', str(HELPER), 'start-focus', '1', b'\xff', 'a.com'], env={**os.environ, 'HOSTS_FILE': str(self.hosts)}, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)

    def test_removing_a_focus_domain_cannot_bypass_the_session(self):
        self.run_helper('start-focus', '5', 'Keep', 'one.com', 'two.com')
        self.error('FOCUS_LOCKED', 'remove', 'one.com')
        self.error('FOCUS_LOCKED', 'request-unblock', 'remove', 'one.com')
        self.assertEqual(self.run_helper('list'), 'one.com\tfocus\ntwo.com\tfocus\n')
        self.assertEqual(json.loads(self.run_helper('session'))['label'], 'Keep')

    def test_empty_section_is_removed(self):
        self.run_helper('add', 'example.com', 'manual')
        self.unblock('remove', 'example.com')
        self.assertEqual(self.hosts.read_bytes(), self.original)
        self.run_helper('start-focus', '1', 'Short', 'example.com')
        self.advance(60000)
        self.run_helper('expire')
        self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_reading_expires_a_stale_session(self):
        self.run_helper('start-focus', '1', 'Stale', 'example.com')
        session = json.loads(self.run_helper('session'))
        self.hosts.write_text(self.hosts.read_text().replace(str(session['endsAt']), '1'))
        self.assertEqual(self.run_helper('list'), '')
        self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_unparseable_managed_entry_names_the_line(self):
        self.hosts.write_bytes(self.original + b'# >>> productivity-os >>>\n127.0.0.1 localhost\n# <<< productivity-os <<<\n')
        result = subprocess.run(['/bin/bash', str(HELPER), 'list'], env={**os.environ, 'HOSTS_FILE': str(self.hosts)}, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('127.0.0.1 localhost', result.stderr)

    def test_crlf_hosts_file(self):
        self.hosts.write_bytes(b'127.0.0.1 localhost\r\n')
        self.run_helper('add', 'example.com', 'manual')
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\n')
        self.unblock('remove', 'example.com')
        self.assertEqual(self.hosts.read_bytes(), b'127.0.0.1 localhost\r\n')

    def test_every_direct_removal_requires_delayed_review(self):
        self.assertEqual(self.run_helper('version'), '4\n')
        self.run_helper('add-many', 'social', 'example.com', 'www.example.com')
        before = self.hosts.read_bytes()
        for command in [('remove', 'example.com'), ('remove-tag', 'example.com', 'social'), ('remove-all-with-tag', 'social'), ('remove-everything',), ('end-focus',), ('end-pomodoro',)]:
            self.error('UNLOCK_REQUIRED', *command)
            self.assertEqual(self.hosts.read_bytes(), before)

    def test_unblock_wait_reason_single_use_and_reason_privacy(self):
        self.run_helper('add', 'example.com', 'manual')
        request = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.assertEqual(request['readyAt'], self.clock['wallMs'] + 60000)
        self.assertEqual(request['expiresAt'], request['readyAt'] + 120000)
        self.advance(30000)
        repeated = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.assertEqual(request, repeated)
        self.error('UNLOCK_NOT_READY', 'confirm-unblock', request['id'], 'Task')
        self.advance(30000)
        self.error('REASON_REQUIRED', 'confirm-unblock', request['id'], ' \n ')
        self.run_helper('confirm-unblock', request['id'], 'PRIVATE REASON café')
        self.assertEqual(self.run_helper('list'), '')
        self.assertNotIn('PRIVATE REASON', self.state_path.read_text())
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)
        self.error('UNLOCK_EXPIRED', 'confirm-unblock', request['id'], 'Again')

    def test_unblock_expiry_scope_changes_and_clock_changes(self):
        self.run_helper('add', 'example.com', 'manual')
        request = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.advance(60000, wall_only=True)
        self.error('UNLOCK_NOT_READY', 'confirm-unblock', request['id'], 'Task')
        self.clock['uptimeMs'] += 60000; self.save_clock()
        self.run_helper('add', 'example.com', 'social')
        self.error('UNLOCK_CHANGED', 'confirm-unblock', request['id'], 'Task')
        renewed = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.assertNotEqual(renewed['id'], request['id'])
        self.advance(180000)
        self.error('UNLOCK_EXPIRED', 'confirm-unblock', renewed['id'], 'Task')
        rebooted = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.advance(60000); self.clock['bootID'] = 'different-boot'; self.save_clock()
        self.error('UNLOCK_EXPIRED', 'confirm-unblock', rebooted['id'], 'Task')
        self.assertIn('example.com', self.run_helper('list'))

    def test_batch_unblock_is_bound_and_atomic(self):
        self.run_helper('add-many', 'manual', 'example.com', 'www.example.com')
        operations = json.dumps([['remove-tag', 'example.com', 'manual'], ['remove-tag', 'www.example.com', 'manual']])
        request = json.loads(self.run_helper('request-unblock', 'batch', operations))
        self.advance(60000)
        self.run_helper('confirm-unblock', request['id'], 'Needed for work')
        self.assertEqual(self.hosts.read_bytes(), self.original)
        self.run_helper('add-many', 'manual', 'example.com', 'www.example.com')
        self.error('INVALID_REQUEST', 'request-unblock', 'batch', json.dumps([['remove', 'example.com'], ['add', 'www.example.com', 'manual']]))
        self.assertEqual(len(self.run_helper('list').splitlines()), 2)

    def test_new_focus_invalidates_waiting_unblocks(self):
        self.run_helper('add', 'example.com', 'manual')
        request = json.loads(self.run_helper('request-unblock', 'remove', 'example.com'))
        self.run_helper('start-focus', '1', 'Focus', 'example.com')
        self.advance(60000)
        self.error('UNLOCK_EXPIRED', 'confirm-unblock', request['id'], 'Task')
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\n')

    def test_pomodoro_attaches_and_only_helper_clock_debits(self):
        status = self.start_pomodoro()
        self.assertEqual((status['phase'], status['remainingMs'], status['pauseReason']), ('focus', 60000, 'monitor'))
        hosts_before = self.hosts.read_bytes(); hosts_mtime = self.hosts.stat().st_mtime_ns
        status = self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.assertFalse(status['paused']); self.assertEqual(status['remainingMs'], 60000)
        self.advance(10000)
        self.assertEqual(self.pomodoro()['remainingMs'], 60000, 'A status read never grants focus progress')
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['remainingMs'], 50000)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['remainingMs'], 50000, 'Repeated same-time ticks cannot accelerate')
        self.assertEqual(self.hosts.read_bytes(), hosts_before)
        self.assertEqual(self.hosts.stat().st_mtime_ns, hosts_mtime, 'Checkpoints never rewrite hosts')
        self.assertIsNone(json.loads(self.run_helper('session')))

    def test_pomodoro_all_removal_and_replacement_paths_hard_lock(self):
        self.start_pomodoro()
        before = self.hosts.read_bytes()
        commands = [('remove', 'example.com'), ('remove-tag', 'example.com', 'pomodoro'), ('remove-all-with-tag', 'pomodoro'), ('remove-everything',), ('end-focus',), ('end-pomodoro',), ('pomodoro-stop',), ('start-focus', '1', 'Different', 'different.com'), ('start-pomodoro', '1', '1', '1', '1', 'Different', 'different.com'), ('request-unblock', 'remove', 'example.com')]
        for command in commands:
            self.error('FOCUS_LOCKED', *command)
            self.assertEqual(self.hosts.read_bytes(), before)
        self.error('NOT_STALLED', 'request-unblock', 'end-pomodoro')
        self.error('NOT_READY', 'pomodoro-next', 'monitor-one', '1', '1', '1', '1')

    def test_pomodoro_sleep_lock_stale_monitor_and_reboot_preserve_debt(self):
        self.start_pomodoro(); self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.advance(10000); self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.advance(3600000, wall_only=True)
        self.clock['unlocked'] = False; self.save_clock()
        away = self.pomodoro('pomodoro-pause', 'monitor-one', 'away')
        self.assertEqual((away['remainingMs'], away['pauseReason']), (50000, 'away'))
        self.advance(100000); self.run_helper('expire')
        self.assertEqual(self.pomodoro()['remainingMs'], 50000)
        self.clock['unlocked'] = True; self.save_clock()
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['remainingMs'], 50000)
        self.advance(10000)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['remainingMs'], 40000)
        self.advance(16000)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['remainingMs'], 40000)
        self.advance(5000)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'new-instance')['remainingMs'], 40000)
        self.clock.update(bootID='new-boot', uptimeMs=1); self.save_clock()
        self.run_helper('expire')
        self.assertEqual(self.pomodoro()['pauseReason'], 'monitor')
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'new-instance')['remainingMs'], 40000)
        self.error('FOCUS_LOCKED', 'pomodoro-stop')

    def test_pomodoro_manual_pause_requires_explicit_resume(self):
        self.start_pomodoro(); self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.advance(5000)
        paused = self.pomodoro('pomodoro-pause', 'monitor-one', 'manual')
        self.assertEqual((paused['remainingMs'], paused['pauseReason']), (55000, 'manual'))
        self.advance(10000)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['pauseReason'], 'manual')
        self.pomodoro('pomodoro-pause', 'monitor-one', 'away')
        self.assertEqual(self.pomodoro()['pauseReason'], 'manual')
        self.assertFalse(self.pomodoro('pomodoro-resume', 'monitor-one')['paused'])
        self.assertEqual(self.pomodoro()['remainingMs'], 55000)

    def test_pomodoro_breaks_continue_away_next_is_manual_and_long_break_every_set(self):
        self.start_pomodoro(rounds='2')
        status = self.finish_round()
        self.assertEqual((status['phase'], status['completedRounds']), ('shortBreak', 1))
        self.clock['unlocked'] = False; self.save_clock()
        self.assertFalse(self.pomodoro('pomodoro-pause', 'monitor-one', 'away')['paused'])
        self.advance(60000, wall_only=True); self.run_helper('expire')
        self.assertEqual(self.pomodoro()['phase'], 'ready')
        self.assertEqual(len(self.run_helper('list').splitlines()), 2)
        self.advance(86400000); self.assertEqual(self.pomodoro()['phase'], 'ready')
        self.clock['unlocked'] = True; self.save_clock()
        self.pomodoro('pomodoro-next', 'monitor-one', '1', '1', '2', '2')
        status = self.finish_round()
        self.assertEqual((status['phase'], status['completedRounds'], status['remainingMs']), ('longBreak', 2, 120000))
        self.assertIsNone(self.pomodoro('pomodoro-stop'))
        self.assertEqual(len(self.run_helper('list').splitlines()), 2, 'Stopping never unblocks websites')
        self.error('UNLOCK_REQUIRED', 'remove-all-with-tag', 'pomodoro')
        self.unblock('remove-all-with-tag', 'pomodoro')
        self.assertEqual(self.run_helper('list'), '')

    def test_pomodoro_probe_failure_and_damaged_state_fail_closed(self):
        self.start_pomodoro(); self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.clock['available'] = False; self.save_clock(); self.advance(10000)
        status = self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.assertEqual((status['remainingMs'], status['pauseReason']), (60000, 'monitor'))
        self.error('FOCUS_LOCKED', 'remove-everything')
        before = self.hosts.read_bytes()
        self.state_path.write_text('{bad json')
        self.error('STATE_INVALID', 'remove-everything')
        self.assertEqual(self.hosts.read_bytes(), before)
        self.state_path.unlink()
        self.error('STATE_INVALID', 'request-unblock', 'remove-everything')
        self.assertEqual(self.hosts.read_bytes(), before)

    def test_unblock_during_break_keeps_timer_and_reblocks_only_on_next_round(self):
        self.pomodoro('start-pomodoro', '1', '2', '3', '4', 'Deep work', 'example.com', 'www.example.com')
        self.assertEqual(self.finish_round()['phase'], 'shortBreak')
        self.unblock('remove', 'example.com')
        status = self.pomodoro()
        self.assertEqual((status['phase'], status['completedRounds']), ('shortBreak', 1))
        self.assertEqual(status['domains'], ['example.com', 'www.example.com'])
        self.assertEqual(self.run_helper('list'), 'www.example.com\tpomodoro\n')
        self.pomodoro()
        self.run_helper('expire')
        self.assertEqual(self.run_helper('list'), 'www.example.com\tpomodoro\n', 'Status and expiry must preserve a reviewed unblock')
        self.advance(60000)
        self.assertEqual(self.pomodoro()['phase'], 'ready')
        self.assertEqual(self.run_helper('list'), 'www.example.com\tpomodoro\n')
        status = self.pomodoro('pomodoro-next', 'monitor-one', '1', '2', '3', '4')
        self.assertEqual((status['phase'], status['completedRounds']), ('focus', 1))
        self.assertEqual(self.run_helper('list'), 'example.com\tpomodoro\nwww.example.com\tpomodoro\n')

    def test_pomodoro_rejects_invalid_settings_before_any_change(self):
        self.error('INVALID_REQUEST', 'start-pomodoro', '0', '5', '15', '4', 'Focus', 'example.com')
        self.error('INVALID_REQUEST', 'start-pomodoro', '25', '241', '15', '4', 'Focus', 'example.com')
        self.error('INVALID_REQUEST', 'start-pomodoro', '25', '5', '15', '13', 'Focus', 'example.com')
        self.error('INVALID_REQUEST', 'add', 'example.com', 'pomodoro')
        self.error('INVALID_REQUEST', 'start-pomodoro', '25', '5', '15', '4', 'Focus', *[f'site{i}.example.com' for i in range(201)])
        self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_pomodoro_domain_budget_deduplicates_and_fits_native_response(self):
        domains = [f'{i:03}' + 'a' * 60 + '.' + 'b' * 63 + '.' + 'c' * 63 + '.' + 'd' * 57 + '.com' for i in range(200)]
        output = self.run_helper('start-pomodoro', '25', '5', '15', '4', 'Focus', *domains, domains[0])
        self.assertEqual(len(json.loads(output)['domains']), 200)
        self.assertLess(len(output.encode()), 65536)
        for args in (('pomodoro-status',), ('pomodoro-checkpoint', 'monitor-one'), ('pomodoro-pause', 'monitor-one', 'manual'), ('pomodoro-resume', 'monitor-one')):
            output = self.run_helper(*args)
            self.assertIn('"stalled":false', output)
            self.assertLess(len(output.encode()), 65536, args)

    def test_policy_symlink_is_rejected_without_changing_hosts_or_target(self):
        target = Path(self.tmp.name) / 'unrelated'
        target.write_text('Do not change')
        self.state_path.symlink_to(target)
        self.error('STATE_INVALID', 'start-pomodoro', '25', '5', '15', '4', 'Focus', 'example.com')
        for command in (('expire',), ('status',), ('list',), ('repair-state',)):
            self.error('STATE_INVALID', *command)
        self.assertTrue(self.state_path.is_symlink(), 'Unsafe policy files are never repaired or moved')
        self.assertEqual(target.read_text(), 'Do not change')
        self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_pomodoro_unicode_label_persists_without_stderr_warnings(self):
        label = 'Café ☕ atenção'
        result = self.result('start-pomodoro', '25', '5', '15', '4', label, 'example.com')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(json.loads(result.stdout)['label'], label)
        self.assertEqual(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['label'], label)
        self.assertEqual(json.loads(self.state_path.read_text())['pomodoro']['label'], label)

    # ---- helper v4

    def snapshot(self, path):
        stat = path.stat()
        return path.read_bytes(), stat.st_ino, stat.st_mtime_ns

    def expire_for(self, minutes, step=60000):
        for _ in range(minutes):
            self.advance(step)
            self.run_helper('expire')

    def stall(self):
        return json.loads(self.state_path.read_text())['pomodoro'].get('stall', {})

    def stalled_round(self):
        # Health Breaks never attaches, so the round stays paused while its owner is present.
        self.clock['idleMs'] = 1000; self.save_clock()
        self.start_pomodoro()
        self.run_helper('expire')
        state = json.loads(self.state_path.read_text())
        state['pomodoro']['stall']['accruedMs'] = 1740000  # 29 minutes; accrual itself is covered below
        self.state_path.write_text(json.dumps(state))
        self.expire_for(1)
        self.assertTrue(self.pomodoro()['stalled'])

    def test_version_is_answered_without_hosts_or_policy(self):
        self.hosts.write_bytes(b'# >>> productivity-os >>>\n# >>> productivity-os >>>\n')
        self.state_path.write_text('{bad json')
        for hosts in (self.hosts, Path(self.tmp.name) / 'missing'):
            result = subprocess.run(['/bin/bash', str(HELPER), 'version'], env={**os.environ, 'HOSTS_FILE': str(hosts)}, capture_output=True, text=True, timeout=15)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '4\n', ''))
        self.error('INVALID_REQUEST', 'version', 'extra')
        # The Perl program, which the wrapper skips for `version`, gives the same answer.
        program = HELPER.read_text().split("<<'PERL'\n", 1)[1].rsplit('\nPERL', 1)[0]
        result = subprocess.run(['/usr/bin/perl', '-', str(self.hosts), '/nonexistent', 'version'], input=program, capture_output=True, text=True, timeout=15)
        self.assertEqual((result.returncode, result.stdout), (0, '4\n'), result.stderr)

    def test_status_matches_the_separate_reads(self):
        def separate():
            entries = [dict(zip(('domain', 'tag'), line.split('\t'))) for line in self.run_helper('list').splitlines()]
            return {'session': json.loads(self.run_helper('session')), 'pomodoro': self.pomodoro(), 'entries': entries}
        def combined():
            status = json.loads(self.run_helper('status'))
            self.assertEqual((status.pop('version'), status.pop('stateDamaged')), (4, False))
            return status
        self.assertEqual(combined(), {'session': None, 'pomodoro': None, 'entries': []})
        self.run_helper('add-many', 'social', 'example.com', 'www.example.com')
        self.run_helper('add', 'example.com', 'manual')
        self.run_helper('start-focus', '5', 'Café focus', 'focus.example.com')
        self.assertEqual(combined(), separate())
        self.assertEqual(combined()['entries'][0], {'domain': 'example.com', 'tag': 'manual,social'})
        self.advance(300000)
        self.start_pomodoro()
        self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.advance(5000)
        self.assertEqual(combined(), separate())
        self.assertEqual(self.finish_round()['phase'], 'shortBreak')
        self.advance(20000)
        status = combined()
        self.assertEqual((status['pomodoro']['remainingMs'], status['pomodoro']['stalled']), (40000, False))
        self.assertEqual(status, separate())

    def test_hung_probe_is_killed_within_the_client_budget(self):
        self.run_helper('add', 'example.com', 'manual')
        self.clock_path.unlink()
        pid_file = Path(self.tmp.name) / 'probe.pid'
        probe = Path(self.tmp.name) / 'hung-probe'
        probe.write_text(f"#!/bin/sh\necho $$ > '{pid_file}'\nexec /bin/sleep 30\n")
        probe.chmod(0o755)
        def reap():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGKILL)
            except (FileNotFoundError, ValueError, ProcessLookupError):
                pass
        self.addCleanup(reap)
        started = time.monotonic()
        result = subprocess.run(['/bin/bash', str(HELPER), 'request-unblock', 'remove', 'example.com'], env={**os.environ, 'HOSTS_FILE': str(self.hosts), 'FOCUS_PROBE': str(probe)}, capture_output=True, text=True, timeout=10)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(json.loads(result.stderr)['code'], 'CLOCK_UNAVAILABLE')
        with self.assertRaises(ProcessLookupError, msg='The stuck probe must not outlive the helper'):
            os.kill(int(pid_file.read_text()), 0)
        self.assertEqual(self.run_helper('list'), 'example.com\tmanual\n')

    def test_held_lock_reports_busy_within_the_client_budget(self):
        with open(self.hosts, 'rb+') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            started = time.monotonic()
            result = self.result('add', 'example.com', 'manual')
            elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stderr)['code'], 'BUSY')
        self.assertGreater(elapsed, 3.5)
        self.assertLess(elapsed, 5)
        self.assertEqual(self.hosts.read_bytes(), self.original)

    def test_degraded_policy_keeps_reads_additions_and_expiry_working(self):
        hosts = self.original + b'# >>> productivity-os >>>\n# focus-session {"endsAt":1,"label":"Old"}\n127.0.0.1 example.com # pomodoro\n::1 example.com # pomodoro\n127.0.0.1 focus.com # focus\n::1 focus.com # focus\n# <<< productivity-os <<<\n'
        uid = os.getuid()
        policies = [None, b'{bad json', b'[]', b' ' * 1048577, json.dumps({'schema': 2, 'ownerUID': uid}).encode(), json.dumps({'schema': 3, 'ownerUID': uid + 1}).encode(),
                    json.dumps({'schema': 3, 'ownerUID': uid, 'pomodoro': {'phase': 'focus'}}).encode()]
        locked = [('pomodoro-status',), ('pomodoro-stop',), ('pomodoro-checkpoint', 'monitor-one'), ('request-unblock', 'remove', 'example.com'), ('request-unblock', 'end-pomodoro'),
                  ('confirm-unblock', '0' * 32, 'Reason'), ('remove', 'example.com'), ('start-focus', '5', 'Focus', 'a.com'), ('start-pomodoro', '1', '1', '1', '1', 'Focus', 'a.com')]
        for index, policy in enumerate(policies):
            with self.subTest(policy=policy if policy is None else policy[:40]):
                self.hosts.write_bytes(hosts)
                if policy is None:
                    self.state_path.unlink(missing_ok=True)
                else:
                    self.state_path.write_bytes(policy)
                self.run_helper('expire')
                self.assertEqual(self.run_helper('list'), 'example.com\tpomodoro\n', 'Expiry ends only the finished session')
                self.assertEqual(json.loads(self.run_helper('status')), {'version': 4, 'session': None, 'pomodoro': None, 'entries': [{'domain': 'example.com', 'tag': 'pomodoro'}], 'stateDamaged': True})
                self.assertIsNone(json.loads(self.run_helper('session')))
                self.run_helper('add', 'manual.com', 'manual'); self.run_helper('add-many', 'social', 'social.com'); self.run_helper('flush')
                for command in locked if index < 2 else locked[:3]:
                    self.error('STATE_INVALID', *command)
                self.assertEqual(self.run_helper('list'), 'example.com\tpomodoro\nmanual.com\tmanual\nsocial.com\tsocial\n')
                if policy is None:
                    self.assertFalse(self.state_path.exists(), 'Degraded mode never recreates the policy')
                else:
                    self.assertEqual(self.state_path.read_bytes(), policy, 'Degraded mode never rewrites the policy')

    def test_repair_state_is_a_no_op_when_healthy(self):
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': False})
        self.assertFalse(self.state_path.exists())
        self.start_pomodoro()
        before, hosts = self.snapshot(self.state_path), self.hosts.read_bytes()
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': False})
        self.assertEqual(self.snapshot(self.state_path), before)
        self.assertEqual(self.hosts.read_bytes(), hosts)
        self.assertEqual(list(Path(self.tmp.name).glob('*.damaged-*')), [])

    def test_repair_state_moves_damaged_policy_aside_and_rebuilds_a_paused_round(self):
        self.run_helper('add', 'manual.com', 'manual')
        self.start_pomodoro()
        hosts = self.hosts.read_bytes()
        self.state_path.write_text('{bad json')
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': True})
        aside = list(Path(self.tmp.name).glob('*.damaged-*'))
        self.assertEqual([path.name for path in aside], ['hosts.state.json.damaged-1700000000'])
        self.assertEqual(aside[0].read_text(), '{bad json')
        status = json.loads(self.run_helper('status'))
        self.assertFalse(status['stateDamaged'])
        self.assertEqual(status['pomodoro'], {'phase': 'focus', 'paused': True, 'pauseReason': 'monitor', 'remainingMs': 1500000, 'endsAt': None, 'focusMinutes': 25, 'shortBreakMinutes': 5,
                                              'longBreakMinutes': 15, 'roundsPerSet': 4, 'completedRounds': 0, 'label': 'Recovered Pomodoro', 'domains': ['example.com', 'www.example.com'], 'stalled': False})
        self.assertEqual(self.hosts.read_bytes(), hosts, 'Repair never changes site blocks')
        self.error('FOCUS_LOCKED', 'request-unblock', 'remove', 'example.com')
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': False})
        self.assertFalse(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['paused'], 'The recovered round resumes when Health Breaks attaches')

    def test_repair_state_without_pomodoro_blocks_leaves_no_plan(self):
        self.run_helper('add', 'manual.com', 'manual')
        self.state_path.write_text('[]')
        self.error('STATE_INVALID', 'pomodoro-status')
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': True})
        self.assertIsNone(self.pomodoro())
        self.assertEqual(json.loads(self.state_path.read_text()), {'schema': 3, 'ownerUID': os.getuid()})
        # A missing policy with Pomodoro blocks has nothing to move aside.
        self.hosts.write_bytes(self.original + b'# >>> productivity-os >>>\n127.0.0.1 example.com # pomodoro\n::1 example.com # pomodoro\n# <<< productivity-os <<<\n')
        self.state_path.unlink()
        self.assertEqual(json.loads(self.run_helper('repair-state')), {'repaired': True})
        self.assertEqual((self.pomodoro()['domains'], self.pomodoro()['label']), (['example.com'], 'Recovered Pomodoro'))
        self.assertEqual(len(list(Path(self.tmp.name).glob('*.damaged-*'))), 1)

    def test_valve_opens_after_thirty_present_minutes_without_progress(self):
        self.clock['idleMs'] = 1000; self.save_clock()
        self.start_pomodoro()
        self.run_helper('expire')
        self.expire_for(29)
        self.expire_for(1, step=30000)
        self.assertEqual(self.stall()['accruedMs'], 1770000)
        self.assertFalse(self.pomodoro()['stalled'])
        self.error('NOT_STALLED', 'request-unblock', 'end-pomodoro')
        self.error('FOCUS_LOCKED', 'end-pomodoro')
        self.expire_for(1, step=30000)
        self.assertTrue(self.pomodoro()['stalled'])
        self.assertTrue(json.loads(self.run_helper('status'))['pomodoro']['stalled'])
        before = self.snapshot(self.state_path)
        self.expire_for(2, step=30000)
        self.assertEqual(self.snapshot(self.state_path), before, 'An open valve stops rewriting the policy')
        self.assertEqual(self.stall(), {'accruedMs': 1800000})
        self.error('UNLOCK_REQUIRED', 'end-pomodoro')
        self.error('FOCUS_LOCKED', 'request-unblock', 'remove', 'example.com')
        self.error('FOCUS_LOCKED', 'pomodoro-stop')

    def test_valve_counts_at_most_a_minute_per_run_and_reanchors_after_reboot(self):
        self.clock['idleMs'] = 0; self.save_clock()
        self.start_pomodoro()
        self.run_helper('expire')
        self.expire_for(1, step=600000)
        self.assertEqual(self.stall()['accruedMs'], 60000)
        self.clock.update(bootID='new-boot', uptimeMs=5000); self.save_clock()
        self.run_helper('expire')
        self.assertEqual(self.stall(), {'bootID': 'new-boot', 'uptimeMs': 5000, 'accruedMs': 60000})
        self.expire_for(1, step=30000)
        for _ in range(3):
            self.run_helper('expire')
        self.assertEqual(self.stall()['accruedMs'], 90000, 'Repeated runs at the same uptime add nothing')

    def test_valve_ignores_away_idle_and_manual_pauses(self):
        self.clock['idleMs'] = 0; self.save_clock()
        self.start_pomodoro()
        self.run_helper('expire')
        self.expire_for(5)
        self.assertEqual(self.stall()['accruedMs'], 300000)
        self.clock['unlocked'] = False; self.save_clock()
        self.expire_for(5)
        self.assertEqual((self.pomodoro()['pauseReason'], self.stall()), ('away', {'accruedMs': 300000}))
        self.clock.update(unlocked=True, idleMs=300001); self.save_clock()
        self.expire_for(5)
        self.assertEqual(self.stall(), {'accruedMs': 300000}, 'More than 5 idle minutes is not presence')
        del self.clock['idleMs']; self.save_clock()
        self.expire_for(5)
        self.assertEqual(self.stall(), {'accruedMs': 300000}, 'Unknown idle time is not presence')
        self.clock['idleMs'] = 300000; self.save_clock()
        self.pomodoro('pomodoro-pause', 'monitor-one', 'manual')
        self.expire_for(5)
        self.assertEqual((self.pomodoro()['pauseReason'], self.stall()), ('manual', {'accruedMs': 300000}))
        self.assertFalse(self.pomodoro()['stalled'])
        self.pomodoro('pomodoro-resume', 'monitor-one')
        self.expire_for(2)
        self.assertEqual((self.pomodoro()['pauseReason'], self.stall()['accruedMs']), ('monitor', 360000), 'Accrual resumes from the kept total')

    def test_valve_resets_on_credited_focus_time(self):
        self.stalled_round()
        self.assertTrue(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['stalled'], 'Attaching alone credits nothing')
        self.advance(10000)
        status = self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.assertEqual((status['remainingMs'], status['stalled']), (50000, False))
        self.assertNotIn('stall', json.loads(self.state_path.read_text())['pomodoro'])
        self.expire_for(3)
        self.assertEqual(self.stall()['accruedMs'], 120000, 'The valve starts over')

    def test_valve_cannot_be_batched(self):
        self.stalled_round()
        for operations in ([['end-pomodoro']], [['end-pomodoro'], ['remove', 'example.com']], [['remove', 'example.com'], ['end-pomodoro']]):
            self.error('INVALID_REQUEST', 'request-unblock', 'batch', json.dumps(operations))
        self.error('INVALID_REQUEST', 'request-unblock', 'end-pomodoro', 'example.com')
        self.assertNotIn('pendingUnlock', json.loads(self.state_path.read_text()))

    def test_valve_review_fails_if_the_round_recovers(self):
        self.stalled_round()
        request = json.loads(self.run_helper('request-unblock', 'end-pomodoro'))
        self.assertEqual(request['description'], 'End the stalled Pomodoro round (site blocks stay)')
        self.pomodoro('pomodoro-checkpoint', 'monitor-one')
        self.advance(10000)
        self.assertFalse(self.pomodoro('pomodoro-checkpoint', 'monitor-one')['stalled'])
        self.advance(50000)
        self.error('UNLOCK_CHANGED', 'confirm-unblock', request['id'], 'Health Breaks stopped responding')
        self.assertEqual(self.pomodoro()['label'], 'Deep work')

    def test_valve_review_ends_the_plan_and_keeps_every_block(self):
        self.run_helper('add', 'manual.com', 'manual')
        self.stalled_round()
        hosts = self.hosts.read_bytes()
        request = json.loads(self.run_helper('request-unblock', 'end-pomodoro'))
        self.assertEqual(json.loads(self.run_helper('request-unblock', 'end-pomodoro')), request, 'A repeated request reuses the running review')
        self.expire_for(1, step=30000)
        self.error('UNLOCK_NOT_READY', 'confirm-unblock', request['id'], 'Health Breaks crashed')
        self.expire_for(1, step=30000)
        self.assertEqual(json.loads(self.run_helper('confirm-unblock', request['id'], 'Health Breaks crashed')), {'unblocked': True})
        self.assertIsNone(self.pomodoro())
        self.assertIsNone(json.loads(self.state_path.read_text())['pomodoro'])
        self.assertEqual(self.hosts.read_bytes(), hosts, 'Ending the plan keeps every site block')
        self.error('UNLOCK_EXPIRED', 'confirm-unblock', request['id'], 'Again')
        self.unblock('remove-all-with-tag', 'pomodoro')
        self.assertEqual(self.run_helper('list'), 'manual.com\tmanual\n')

    def test_breaks_never_rewrite_the_policy_until_ready(self):
        self.start_pomodoro()
        self.assertEqual(self.finish_round()['phase'], 'shortBreak')
        before = self.snapshot(self.state_path)
        for elapsed in (10000, 20000, 30000):
            self.advance(10000)
            self.assertEqual(self.pomodoro()['remainingMs'], 60000 - elapsed)
            self.assertEqual(json.loads(self.run_helper('status'))['pomodoro']['remainingMs'], 60000 - elapsed)
            self.run_helper('expire')
            for args in (('pomodoro-checkpoint', 'monitor-one'), ('pomodoro-pause', 'monitor-one', 'away'), ('pomodoro-resume', 'monitor-one')):
                self.assertEqual(self.pomodoro(*args)['remainingMs'], 60000 - elapsed)
        self.assertEqual(self.snapshot(self.state_path), before)
        self.advance(30000)
        self.assertEqual(self.pomodoro()['phase'], 'ready')
        self.assertEqual(json.loads(self.state_path.read_text())['pomodoro']['phase'], 'ready', 'Only the ready transition is saved')
        ready = self.snapshot(self.state_path)
        self.expire_for(2)
        self.pomodoro()
        self.assertEqual(self.snapshot(self.state_path), ready)

    def test_manual_break_pause_keeps_the_time_left(self):
        self.start_pomodoro()
        self.finish_round()
        self.advance(20000)
        paused = self.pomodoro('pomodoro-pause', 'monitor-one', 'manual')
        self.assertEqual((paused['paused'], paused['remainingMs'], paused['endsAt']), (True, 40000, None))
        self.advance(100000)
        self.assertEqual(self.pomodoro()['remainingMs'], 40000)
        resumed = self.pomodoro('pomodoro-resume', 'monitor-one')
        self.assertEqual((resumed['paused'], resumed['remainingMs'], resumed['endsAt']), (False, 40000, self.clock['wallMs'] + 40000))

if __name__ == '__main__':
    unittest.main()
