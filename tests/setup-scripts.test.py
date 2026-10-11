"""Tests for assets/setup-{health-breaks,clipboard-history,drop-shelf,screenshot-studio}.sh.

Every run uses a temporary HOME, fixture bundles and stubs for launchctl, osascript, open, lsregister, pgrep and
codesign (real ditto and plutil), so nothing reaches the real launchd labels, Launch Services or running helpers.
Set POS_SETUP_FIXTURES to an assets directory with built helper bundles to also run the real-bundle checks (real
codesign verification and designated requirements).
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / 'assets'
TOOLS = ('launchctl', 'osascript', 'open', 'lsregister', 'pgrep', 'codesign')
SEP = '\x1f'

# Logs "<tool>\t<POSBuildID installed right now>\t<argv joined by \x1f>" and simulates the helper from $POS_TEST_STATE.
STUB = r'''#!/bin/bash
tool="${0##*/}" state="$POS_TEST_STATE"
build="$(/usr/bin/plutil -extract POSBuildID raw -o - "$HOME/Applications/$POS_TEST_APP.app/Contents/Info.plist" 2>/dev/null || echo none)"
IFS=$'\x1f'
printf '%s\t%s\t%s\n' "$tool" "$build" "$*" >>"$state/log"
case "$tool" in
  pgrep) [[ -e "$state/running" ]]; exit ;;
  osascript | open)
    if [[ -e "$state/quit-hangs" ]]; then exec sleep 30; fi
    if [[ -e "$state/obeys-quit" ]]; then rm -f "$state/running"; fi ;;
  launchctl)
    if [[ "$1" =~ ^(bootstrap|kickstart)$ && -e "$state/launchd-refuses" ]]; then echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; fi ;;
  codesign)
    if [[ "$1" == --verify && -e "$state/bad-signature" ]]; then echo 'a sealed resource is missing or invalid' >&2; exit 1; fi
    if [[ "$1" == -d ]]; then
      echo "Executable=${*: -1}" >&2
      sed 's/^/designated => /' "${*: -1}/Contents/Resources/requirement" 2>/dev/null
    fi ;;
esac
exit 0
'''


class App:
    def __init__(self, slug, name, executable, quit, login, scheme=None):
        self.slug, self.name, self.executable, self.quit, self.login, self.scheme = slug, name, executable, quit, login, scheme
        self.label = f'com.productivity-os.{slug}'


# quit: how a running copy is asked to quit ('url' = quit-if-idle only; 'hybrid' = quit-if-idle when the installed
# build advertises POSLauncherProtocol, else AppleScript). login: when a missing LaunchAgent plist is created.
APPS = [
    App('health-breaks', 'Health Breaks', 'HealthBreaks', 'hybrid', 'first-install', 'pos-health'),
    App('clipboard-history', 'Clipboard History', 'ClipboardHistory', 'hybrid', 'first-install', 'pos-clipboard'),
    App('drop-shelf', 'Drop Shelf', 'DropShelf', 'url', 'never', 'pos-shelf'),
    App('screenshot-studio', 'Screenshot Studio', 'ScreenshotStudio', 'url', 'always', 'pos-screenshot'),
]
BY_SLUG = {app.slug: app for app in APPS}
OLD_PLIST = {'Label': None, 'ProgramArguments': None, 'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua'}


def make_bundle(parent, app, build, *, protocol=True, requirement=None):
    bundle = Path(parent) / f'{app.name}.app'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    (bundle / 'Contents/Resources').mkdir()
    executable = bundle / 'Contents/MacOS' / app.executable
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
    (bundle / 'Contents/Resources/requirement').write_text(requirement or f'identifier "{app.label}" and certificate leaf = H"aa"')
    info = {'CFBundleIdentifier': app.label, 'CFBundleExecutable': app.executable, 'POSBuildID': build}
    if protocol:
        info['POSLauncherProtocol'] = 1
    with open(bundle / 'Contents/Info.plist', 'wb') as handle:
        plistlib.dump(info, handle)
    return bundle


class World:
    """One temporary HOME + assets directory for one helper."""

    def __init__(self, root, app, *, installed=None, protocol=True, plist=False, running=False, obeys_quit=True,
                 requirement=None, new_requirement=None, bundled=None, real_codesign=False):
        self.app, self.protocol = app, protocol
        self.root = Path(tempfile.mkdtemp(prefix=f'{app.slug}-', dir=root))
        self.home, self.assets, self.state, self.bin = (self.root / name for name in ('home', 'assets', 'state', 'bin'))
        for directory in (self.home, self.assets, self.state, self.bin):
            directory.mkdir()
        (self.bin / 'stub').write_text(STUB)
        (self.bin / 'stub').chmod(0o755)
        for tool in TOOLS:
            (self.bin / tool).symlink_to('stub')
        shutil.copy(ASSETS / f'setup-{app.slug}.sh', self.assets)
        if bundled:
            subprocess.run(['/usr/bin/ditto', str(Path(bundled) / f'{app.name}.app'), str(self.assets / f'{app.name}.app')], check=True)
        else:
            make_bundle(self.assets, app, 'new', requirement=new_requirement)
        self.apps = self.home / 'Applications'
        self.target = self.apps / f'{app.name}.app'
        self.plist = self.home / 'Library/LaunchAgents' / f'{app.label}.plist'
        if installed:
            self.apps.mkdir(parents=True)
            make_bundle(self.apps, app, installed, protocol=protocol, requirement=requirement)
        if plist:
            self.plist.parent.mkdir(parents=True)
            with open(self.plist, 'wb') as handle:
                plistlib.dump({**OLD_PLIST, 'Label': app.label, 'ProgramArguments': [str(self.executable), '--background']}, handle)
        for flag, on in (('running', running), ('obeys-quit', obeys_quit)):
            if on:
                (self.state / flag).touch()
        self.real_codesign = real_codesign

    @property
    def executable(self):
        return self.target / 'Contents/MacOS' / self.app.executable

    def flag(self, name):
        (self.state / name).touch()

    def run(self, *args):
        env = {
            'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.home), 'TMPDIR': str(self.root),
            'POS_TEST_STATE': str(self.state), 'POS_TEST_APP': self.app.name, 'POS_QUIT_WAIT': '1',
        }
        for tool in TOOLS:
            if tool != 'codesign' or not self.real_codesign:
                env[f'POS_{tool.upper()}'] = str(self.bin / tool)
        # Never let a script reach the real launchd labels, running helpers or Launch Services.
        for tool in ('launchctl', 'osascript', 'open', 'lsregister', 'pgrep'):
            assert Path(env[f'POS_{tool.upper()}']).resolve().is_relative_to(self.root.resolve()), tool
        assert Path(env['HOME']).resolve() != Path.home().resolve()
        return subprocess.run(['/bin/bash', str(self.assets / f'setup-{self.app.slug}.sh'), *args], env=env,
                              capture_output=True, text=True, timeout=60)

    def log(self):
        path = self.state / 'log'
        lines = path.read_text().splitlines() if path.exists() else []
        return [(tool, build, args.split(SEP)) for tool, build, args in (line.split('\t') for line in lines)]

    def steps(self):
        """Ordered (step, installed build) pairs; launchctl steps are named by subcommand."""
        return [(f'launchctl {args[0]}' if tool == 'launchctl' else tool, build) for tool, build, args in self.log()]

    def index(self, step):
        names = [name for name, _ in self.steps()]
        return names.index(step) if step in names else None

    def installed_build(self):
        info = self.target / 'Contents/Info.plist'
        return plistlib.loads(info.read_bytes()).get('POSBuildID') if info.exists() else None

    def leftovers(self):
        return sorted(p.name for p in self.apps.iterdir() if p.name.startswith(f'.{self.app.slug}.')) if self.apps.exists() else []

    def expected_plist(self):
        return {
            'Label': self.app.label, 'ProgramArguments': [str(self.executable), '--background'], 'RunAtLoad': True,
            'KeepAlive': {'SuccessfulExit': False}, 'ProcessType': 'Interactive', 'ThrottleInterval': 30,
            'LimitLoadToSessionType': 'Aqua',
        }

    def quit_step(self):
        return 'osascript' if self.app.quit == 'hybrid' and not self.protocol else 'open'


class SetupScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='pos-setup-')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def world(self, slug, **options):
        return World(self.tmp, BY_SLUG[slug], **options)

    def assertQuitRequest(self, world):
        tool, build, args = next(entry for entry in world.log() if entry[0] == world.quit_step())
        self.assertEqual(build, 'old')
        if tool == 'osascript':
            script = '\n'.join(args)
            self.assertIn('with timeout of 5 seconds', script)
            self.assertIn(f'if application id "{world.app.label}" is running then tell application id "{world.app.label}" to quit', script)
        else:
            self.assertEqual(args, ['-g', '-a', str(world.target), f'{world.app.scheme}://quit-if-idle'])

    def test_first_install_creates_the_agent_only_where_it_always_did(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug)
                result = world.run('install')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(world.installed_build(), 'new')
                self.assertEqual(world.plist.exists(), app.login != 'never')
                if world.plist.exists():
                    self.assertEqual(plistlib.loads(world.plist.read_bytes()), world.expected_plist())
                    self.assertEqual(world.log()[-1][2], ['bootstrap', f'gui/{os.getuid()}', str(world.plist)])
                else:
                    self.assertIsNone(world.index('launchctl bootstrap'))
                self.assertIn(('lsregister', 'new'), world.steps())
                self.assertIsNone(world.index(world.quit_step()), 'nothing was running')
                self.assertEqual(world.leftovers(), [])

    def test_update_quits_before_unloading_before_swapping(self):
        for app in APPS:
            for mode in ('update', 'install'):
                with self.subTest(app.slug, mode=mode):
                    world = self.world(app.slug, installed='old', plist=True, running=True)
                    result = world.run(mode)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertQuitRequest(world)
                    steps = world.steps()
                    order = [world.index(step) for step in (world.quit_step(), 'launchctl bootout', 'lsregister', 'launchctl bootstrap')]
                    self.assertEqual(order, sorted(order), steps)
                    self.assertIn(('launchctl bootout', 'old'), steps, 'unloaded before the swap')
                    self.assertIn(('lsregister', 'new'), steps)
                    self.assertIn(('launchctl bootstrap', 'new'), steps)
                    self.assertLess(world.index('codesign'), world.index(world.quit_step()), 'verified before quitting')
                    self.assertEqual(world.installed_build(), 'new')
                    self.assertEqual(plistlib.loads(world.plist.read_bytes()), world.expected_plist(), 'plist migrated')
                    self.assertEqual(world.leftovers(), [])
                    self.assertTrue(result.stdout.startswith('Updated' if mode == 'update' else 'Installed'), result.stdout)

    def test_a_busy_helper_leaves_everything_untouched_and_exits_75(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug, installed='old', plist=True, running=True, obeys_quit=False)
                before = world.plist.read_bytes()
                result = world.run('update')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIn('nothing was changed', result.stderr)
                self.assertQuitRequest(world)
                self.assertEqual(world.installed_build(), 'old')
                self.assertEqual(world.plist.read_bytes(), before)
                self.assertFalse(any(step.startswith('launchctl') for step, _ in world.steps()), world.steps())
                self.assertIsNone(world.index('lsregister'))
                self.assertEqual(world.leftovers(), [], 'staging and lock are cleaned up')

    def test_a_quit_request_stuck_behind_a_dialog_does_not_extend_the_wait(self):
        for slug in ('health-breaks', 'clipboard-history'):
            with self.subTest(slug):
                world = self.world(slug, installed='old', running=True, obeys_quit=False)
                world.flag('quit-hangs')
                started = time.monotonic()
                result = world.run('update')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertLess(time.monotonic() - started, 4, 'POS_QUIT_WAIT=1 bounds the whole quit attempt')
                self.assertEqual(world.installed_build(), 'old')

    def test_shelf_and_studio_builds_without_the_launcher_protocol_count_as_busy(self):
        for slug in ('drop-shelf', 'screenshot-studio'):
            with self.subTest(slug):
                world = self.world(slug, installed='old', protocol=False, plist=True, running=True)
                result = world.run('update')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIn('cannot be asked to quit', result.stderr)
                self.assertEqual([step for step, _ in world.steps()], ['pgrep'], 'not even staged or verified')
                self.assertEqual(world.installed_build(), 'old')
                self.assertEqual(world.leftovers(), [])
                result = world.run('uninstall')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIsNone(world.index('open'), 'an old build is never sent quit-if-idle')
                self.assertEqual(world.installed_build(), 'old')
                self.assertTrue(world.plist.exists())

    def test_health_and_clipboard_builds_without_the_launcher_protocol_get_an_applescript_quit(self):
        for slug in ('health-breaks', 'clipboard-history'):
            with self.subTest(slug):
                world = self.world(slug, installed='old', protocol=False, plist=True, running=True)
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(world.quit_step(), 'osascript')
                self.assertQuitRequest(world)
                self.assertIsNone(world.index('open'), 'an old build is never sent quit-if-idle')
                self.assertEqual(world.installed_build(), 'new')

    def test_existing_plists_are_rewritten_and_missing_ones_respected(self):
        cases = [
            ('health-breaks', False, False), ('clipboard-history', False, False),  # login turned off stays off
            ('drop-shelf', False, False), ('drop-shelf', True, True),  # opt-in only; existing refreshed
            ('screenshot-studio', False, True),  # resident ⌘⇧2 helper always has its agent
        ]
        for slug, had_plist, has_plist in cases:
            with self.subTest(slug, had_plist=had_plist):
                world = self.world(slug, installed='old', plist=had_plist)
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(world.plist.exists(), has_plist)
                if has_plist:
                    self.assertEqual(plistlib.loads(world.plist.read_bytes()), world.expected_plist())
                self.assertEqual(world.index('launchctl bootstrap') is not None, has_plist)
                self.assertIsNone(world.index(world.quit_step()), 'nothing was running')

    def test_symbolic_link_targets_are_refused(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug)
                elsewhere = make_bundle(world.root / 'elsewhere', app, 'old')
                world.apps.mkdir()
                world.target.symlink_to(elsewhere)
                result = world.run('update')
                self.assertEqual(result.returncode, 1)
                self.assertIn('Refusing a symbolic-link installation target', result.stderr)
                self.assertTrue(world.target.is_symlink())
                self.assertEqual(plistlib.loads((elsewhere / 'Contents/Info.plist').read_bytes())['POSBuildID'], 'old')
                self.assertEqual(world.log(), [])
        world = self.world('health-breaks')
        world.plist.parent.mkdir(parents=True)
        world.plist.symlink_to(world.root / 'elsewhere.plist')
        self.assertEqual(world.run('install').returncode, 1)
        self.assertFalse((world.root / 'elsewhere.plist').exists())

    def test_a_live_lock_holder_means_busy_and_a_stale_lock_is_broken(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug, installed='old', plist=True)
                lock = world.apps / f'.{app.slug}.setup.lock'
                lock.mkdir()
                (lock / 'pid').write_text(f'{os.getpid()}\n')
                result = world.run('update')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIn('setup is running', result.stderr)
                self.assertEqual((lock / 'pid').read_text().strip(), str(os.getpid()), "the holder's lock is kept")
                self.assertEqual(world.installed_build(), 'old')
                self.assertEqual(world.log(), [])
                gone = subprocess.Popen(['/usr/bin/true'])
                gone.wait()
                (lock / 'pid').write_text(f'{gone.pid}\n')
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(world.installed_build(), 'new')
                self.assertFalse(lock.exists())

    def test_a_bundle_that_fails_verification_changes_nothing(self):
        world = self.world('health-breaks', installed='old', plist=True, running=True)
        world.flag('bad-signature')
        result = world.run('update')
        self.assertEqual(result.returncode, 1)
        self.assertIn('failed signature verification', result.stderr)
        self.assertIsNone(world.index(world.quit_step()), 'the running copy was not asked to quit')
        self.assertEqual(world.installed_build(), 'old')
        self.assertEqual(world.leftovers(), [])

    def test_a_changed_designated_requirement_warns_about_privacy_prompts(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug, installed='old', requirement='cdhash H"0123"', new_requirement='cdhash H"4567"')
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('signed differently', result.stderr)
                world = self.world(app.slug, installed='old')
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('signed differently', result.stderr)

    def test_launchd_refusing_the_agent_is_not_fatal(self):
        world = self.world('screenshot-studio', installed='old', plist=True)
        world.flag('launchd-refuses')
        result = world.run('update')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Login Items may be off', result.stderr)
        self.assertEqual(world.installed_build(), 'new')
        self.assertEqual([step for step, _ in world.steps()][-2:], ['launchctl bootstrap', 'launchctl kickstart'])

    def test_uninstall_quits_first_and_a_busy_helper_is_kept(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = self.world(app.slug, installed='old', plist=True, running=True)
                result = world.run('uninstall')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(world.index(world.quit_step()), world.index('launchctl bootout'))
                self.assertFalse(world.target.exists())
                self.assertFalse(world.plist.exists())
                world = self.world(app.slug, installed='old', plist=True, running=True, obeys_quit=False)
                result = world.run('uninstall')
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertEqual(world.installed_build(), 'old')
                self.assertTrue(world.plist.exists())
                self.assertIsNone(world.index('launchctl bootout'))

    def test_unknown_actions_are_rejected(self):
        for app in APPS:
            with self.subTest(app.slug):
                result = self.world(app.slug).run('upgrade')
                self.assertEqual(result.returncode, 64)
                self.assertIn('install|update|uninstall', result.stderr)


@unittest.skipUnless(os.environ.get('POS_SETUP_FIXTURES'), 'set POS_SETUP_FIXTURES to an assets directory with built helpers')
class RealBundleTests(unittest.TestCase):
    """End to end with built, signed bundles: real ditto, codesign and plutil; launchd/apps/Launch Services stubbed."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='pos-setup-real-')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fixtures = Path(os.environ['POS_SETUP_FIXTURES'])

    def test_install_then_update_a_running_helper(self):
        for app in APPS:
            with self.subTest(app.slug):
                world = World(self.tmp, app, bundled=self.fixtures, real_codesign=True)
                build = plistlib.loads((world.assets / f'{app.name}.app/Contents/Info.plist').read_bytes())
                self.assertEqual(build.get('POSLauncherProtocol'), 1)
                result = world.run('install')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(world.installed_build(), build['POSBuildID'])
                subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(world.target)], check=True)
                if app.login != 'never':
                    self.assertEqual(plistlib.loads(world.plist.read_bytes()), world.expected_plist())
                else:
                    self.assertFalse(world.plist.exists())
                # Same signing identity → same designated requirement → no privacy warning.
                world.flag('running')
                world.flag('obeys-quit')
                (world.state / 'log').unlink()
                result = world.run('update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('signed differently', result.stderr)
                names = [step for step, _ in world.steps()]
                quit = world.quit_step()  # installed from the fixtures, which advertise the launcher protocol
                self.assertLess(names.index(quit), names.index('launchctl bootout'))
                self.assertLess(names.index('launchctl bootout'), names.index('lsregister'))
                subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(world.target)], check=True)
                self.assertEqual(world.leftovers(), [])


if __name__ == '__main__':
    unittest.main()
