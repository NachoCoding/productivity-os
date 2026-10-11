"""Coordinator idle cost and resilience against a private coordinator in a disposable directory."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

binary, directory = sys.argv[1:]
root = Path(directory)
root.mkdir(mode=0o700)
fixture = root / 'sample.json'
state = root / 'registry.json'
env = dict(os.environ, RESOURCE_GUARD_HOME=directory, RESOURCE_GUARD_SAMPLE=str(fixture))
# The suite may itself run under the real guard; never mistake that job token for a test job.
env.pop('RESOURCE_GUARD_JOB', None)
children = []
daemon = None
daemon_log = None


def pressure(level):
    temp = fixture.with_suffix('.new')
    temp.write_text(json.dumps(dict(time=0, pressure=level, cpu=10, swapOut=0, swapIn=0, swapUsed=0, memory=16 << 30)))
    temp.replace(fixture)


def cli(*args, check=True):
    return subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=8, check=check)


def status():
    return json.loads(cli('status', '--json').stdout)


def counters():
    return status()['testing']


def until(predicate, message, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.2)
    raise AssertionError(message)


def run(*args):
    process = subprocess.Popen([binary, 'run', '--', *args], env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(process)
    return process


def job_for(process):
    return next((job for job in status()['jobs'] if job['owner']['pid'] == process.pid), None)


try:
    state.write_text('{not json')
    pressure('critical')
    daemon_log = (root / 'daemon.log').open('w')
    daemon = subprocess.Popen([binary, 'serve'], env=env, stdout=subprocess.DEVNULL, stderr=daemon_log)
    until(status, 'coordinator did not start with damaged state', 10)
    moved = list(root.glob('registry.json.corrupt-*'))
    assert len(moved) == 1 and moved[0].read_text() == '{not json', moved
    assert status()['jobs'] == [] and daemon.poll() is None
    until(lambda: json.loads(state.read_text())['version'] == 1, 'fresh state was not written', 10)
    print('PASS damaged state is moved aside and the coordinator starts fresh', flush=True)

    first = counters()
    time.sleep(6.5)
    second = status()
    idle = second['testing']
    assert idle['inventoryScans'] == first['inventoryScans'] + 1, (first, idle)
    assert idle.get('groupScans', 0) == 0, idle
    assert 1 <= idle['ticks'] - first['ticks'] <= 3, (first, idle)
    assert idle['wakeups'] - first['wakeups'] <= 6, (first, idle)
    assert second['processes'] and 0 <= idle['inventoryAge'] < 1000, second['processes'][:1]
    assert second['sample']['pressure'] == 'critical' and second['sampleAge'] <= 10
    assert counters()['inventoryScans'] == idle['inventoryScans'], 'status inventory was not reused within 2 s'
    time.sleep(2.2)
    assert counters()['inventoryScans'] == idle['inventoryScans'] + 1, 'stale status inventory was not rebuilt'
    print('PASS idle coordinator: no process scans, 5 s ticks, fresh status inventory on demand', flush=True)

    before = counters()
    queued = run('/bin/echo', 'held')
    job = until(lambda: job_for(queued), 'queued job missing')
    time.sleep(3)
    waiting = counters()
    assert waiting.get('polls', 0) - before.get('polls', 0) <= 3, (before, waiting)
    assert waiting.get('groupScans', 0) == 0, 'queued jobs need no process scan'
    started = time.monotonic()
    cli('cancel', job['id'])
    out, _ = queued.communicate(timeout=5)
    assert queued.returncode == 130 and out == '' and time.monotonic() - started < 2, queued.returncode
    until(lambda: not status()['jobs'], 'cancelled job remained')
    print('PASS queued clients sleep until the state changes and leave promptly on cancel', flush=True)

    orphan = run('/bin/echo', 'orphan')
    until(lambda: job_for(orphan), 'orphan job missing')
    os.chmod(root, 0o500)
    try:
        orphan.kill()
        orphan.communicate(timeout=5)
        until(lambda: not status()['jobs'], 'dead wrapper was not reconciled while state was read-only', 10)
        assert daemon.poll() is None, 'coordinator exited after a failed state write'
        assert json.loads(state.read_text())['jobs'], 'state unexpectedly written to a read-only directory'
        assert cli('limit', '1', check=False).returncode != 0, 'failed write was not reported'
        assert status()['limit'] == 2, 'failed limit change stayed in memory'
    finally:
        os.chmod(root, 0o700)
    until(lambda: json.loads(state.read_text())['jobs'] == [], 'state was not saved after recovery', 10)
    assert daemon.poll() is None and status()['limit'] == 2
    assert 'still serving' in (root / 'daemon.log').read_text()
    print('PASS failed state writes are logged and retried; the coordinator keeps serving', flush=True)
finally:
    os.chmod(root, 0o700)
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
    if daemon and daemon.poll() is None:
        daemon.terminate(); daemon.wait(timeout=5)
    if daemon_log:
        daemon_log.close()
