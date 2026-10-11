"""End-to-end normal Quit, refusal, stale identity, and agent protection against an owned app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

guard, fixture, workdir = map(Path, sys.argv[1:])
workdir.mkdir(mode=0o700)
app = workdir / 'Resource Guard QA.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
shutil.copy2(fixture, contents / 'MacOS' / 'RAMFixture')
with (contents / 'Info.plist').open('wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='com.productivity-os.qa.ram-fixture', CFBundleExecutable='RAMFixture',
                      CFBundleName='Resource Guard QA', CFBundlePackageType='APPL'), file)
env = dict(os.environ)
env.pop('RESOURCE_GUARD_JOB', None)


def until(predicate, message, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError(message)


def report():
    return json.loads(subprocess.check_output([str(guard), 'apps'], env=env, timeout=8))


def row(pid):
    return next((item for item in report()['apps'] if item['identity']['pid'] == pid), None)


def quit_app(item):
    identity = item['identity']
    return subprocess.run([str(guard), 'quit-app', str(identity['pid']), str(identity['seconds']), str(identity['micros']), item['bundleID']],
                          env=env, text=True, capture_output=True, timeout=8)


for mode in ('normal', 'refuse', 'protected'):
    directory = workdir / mode
    directory.mkdir()
    shutil.copyfile('/bin/sleep', directory / 'codex')
    (directory / 'codex').chmod(0o755)
    launcher = subprocess.Popen(['/usr/bin/open', '-n', '-g', '-W', str(app), '--args', mode, str(directory)], env=env)
    try:
        until(lambda: (directory / 'ready').exists(), f'{mode} fixture did not start')
        pid = int((directory / 'ready').read_text())
        item = until(lambda: row(pid), f'{mode} fixture not visible')
        assert Path(item['path']).resolve() == app.resolve() and item['bytes'] > 0 and item['processCount'] >= 1
        stale = json.loads(json.dumps(item))
        stale['identity']['micros'] += 1
        assert quit_app(stale).returncode != 0
        assert row(pid), 'stale identity unexpectedly quit the app'
        response = quit_app(item)
        if mode == 'normal':
            assert not item['protected'] and response.returncode == 0, response.stderr
            until(lambda: row(pid) is None, 'normal Quit did not close the fixture')
            assert (directory / 'quit-request').exists()
        elif mode == 'refuse':
            assert not item['protected']
            until(lambda: (directory / 'quit-request').exists(), 'Quit request not delivered')
            time.sleep(.5)
            assert row(pid), 'refusing app was force-quit'
        else:
            assert item['protected'] and item['processCount'] >= 2
            assert response.returncode != 0 and 'protected' in response.stderr
            assert not (directory / 'quit-request').exists(), 'protected app received Quit'
        print(f'PASS macOS app integration: {mode}, stale identity, real footprint', flush=True)
    finally:
        (directory / 'cleanup').touch()
        try:
            launcher.wait(timeout=10)
        except subprocess.TimeoutExpired:
            launcher.terminate(); launcher.wait(timeout=5)
            raise AssertionError('Fixture did not clean itself up; inspect only the owned QA app')
