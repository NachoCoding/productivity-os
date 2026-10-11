"""Real local sockets and disposable processes; simulated pressure, never stress the Mac."""
import json
import os
from pathlib import Path
import signal
import socket
import pty
import select
import subprocess
import sys
import time

binary, directory = sys.argv[1:]
root = Path(directory)
root.mkdir(mode=0o700)
fixture = root / 'sample.json'
env = dict(os.environ, RESOURCE_GUARD_HOME=directory, RESOURCE_GUARD_SAMPLE=str(fixture))
# The suite itself may be launched through the real guard. Its disposable coordinator is a
# separate namespace; do not mistake that outer job token for one of the test coordinator's jobs.
env.pop('RESOURCE_GUARD_JOB', None)
children = []
daemon = None


def pressure(level):
    temp = fixture.with_suffix('.new')
    temp.write_text(json.dumps(dict(time=0, pressure=level, cpu=10, swapOut=0, swapIn=0, swapUsed=0, memory=16 << 30)))
    temp.replace(fixture)


def cli(*args, check=True):
    return subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=8, check=check)


def status():
    return json.loads(cli('status', '--json').stdout)


def until(predicate, message, timeout=50):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
        time.sleep(.2)
    raise AssertionError(message)


def start_daemon():
    process = subprocess.Popen([binary, 'serve'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    until(lambda: status(), 'daemon did not start', 10)
    assert process.poll() is None
    return process


def run(*args, cwd=None, extra_env=None):
    process = subprocess.Popen([binary, 'run', '--', *args], env={**env, **(extra_env or {})}, cwd=cwd,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(process)
    return process


def job_for(process):
    return next((job for job in status()['jobs'] if job['owner']['pid'] == process.pid), None)


def packet(data):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(4)
        client.connect(str(root / 'guard.sock'))
        client.sendall(data + b'\n')
        received = b''
        while b'\n' not in received:
            received += client.recv(4096)
        return json.loads(received)


def terminal_job(arguments, interrupt=False):
    pid, terminal = pty.fork()
    if pid == 0:
        os.execve(str(binary), [str(binary), 'run', '--', *arguments], env)
    output = b''
    sent = False
    deadline = time.monotonic() + 25
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], .2)
            if ready:
                try:
                    data = os.read(terminal, 4096)
                except OSError:
                    break
                if not data:
                    break
                output += data
            if not sent and b'TTY_READY' in output:
                os.write(terminal, b'\x03' if interrupt else b'hello terminal\n')
                sent = True
        # The terminal reaches EOF while the launcher is still exiting, so allow it a moment to become waitable.
        child, result = os.waitpid(pid, os.WNOHANG)
        settle = time.monotonic() + 5
        while child == 0 and time.monotonic() < settle:
            time.sleep(.05)
            child, result = os.waitpid(pid, os.WNOHANG)
        if child == 0:
            raise AssertionError('PTY job did not exit: ' + repr(output))
        assert sent, output
        return os.waitstatus_to_exitcode(result), output
    finally:
        os.close(terminal)
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == 0:
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if os.waitpid(pid, os.WNOHANG)[0] != 0:
                        break
                    time.sleep(.05)
                else:
                    os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
        except ChildProcessError:
            pass


try:
    pressure('critical')
    daemon = start_daemon()
    duplicate = cli('serve', check=False)
    assert duplicate.returncode != 0 and 'already running' in duplicate.stderr
    queued = run('/bin/echo', 'must not start')
    job = until(lambda: job_for(queued), 'missing queued job')
    time.sleep(1)
    assert queued.poll() is None and job_for(queued)['state'] == 'queued'
    assert status()['sample']['pressure'] == 'critical'
    cli('cancel', job['id'])
    out, _ = queued.communicate(timeout=5)
    assert queued.returncode == 130 and out == ''
    until(lambda: not status()['jobs'], 'cancelled queue entry remained')
    print('PASS critical pressure holds jobs; queued cancellation; singleton', flush=True)

    assert 'error' in packet(b'{broken-json')
    assert 'error' in packet(json.dumps({'command': 'started', 'id': 'forged'}).encode())
    assert 'error' in packet(json.dumps({'command': 'cancel', 'id': 'forged', 'group': os.getpgrp()}).encode())
    assert status()['sample']['pressure'] == 'critical'
    burst = [run('/bin/echo', f'queued-{index}') for index in range(8)]
    until(lambda: all(job_for(process) for process in burst), 'concurrent enqueues lost jobs')
    assert len({job_for(process)['id'] for process in burst}) == 8
    for process in burst:
        cli('cancel', job_for(process)['id'])
    for process in burst:
        out, _ = process.communicate(timeout=5)
        assert process.returncode == 130 and out == ''
    until(lambda: not status()['jobs'], 'burst cancellation leaked queue entries')
    orphan = run('/bin/echo', 'orphan must never start')
    until(lambda: job_for(orphan), 'orphan not registered')
    orphan.kill(); orphan.communicate(timeout=5)
    until(lambda: not status()['jobs'], 'dead wrapper kept its reservation')
    forged = run('/bin/echo', 'forged token', extra_env={'RESOURCE_GUARD_JOB': 'forged'})
    out, _ = forged.communicate(timeout=5)
    assert forged.returncode == 75 and out == ''
    print('PASS malformed protocol, forged starts/tokens, concurrent queue requests, dead wrapper cleanup', flush=True)

    pressure('normal')
    first = run('/bin/sleep', '180', cwd='/tmp')
    first_job = until(lambda: (j if (j := job_for(first)) and j['state'] == 'running' else None), 'healthy recovery did not admit first job')
    first_started = time.monotonic()
    second = run('/bin/sleep', '180', cwd=str(root))
    until(lambda: job_for(second), 'second registration missing')
    third = run('/bin/echo', 'third')
    second_job = until(lambda: (j if (j := job_for(second)) and j['state'] == 'running' else None), 'second did not start')
    assert time.monotonic() - first_started >= 8
    assert job_for(third)['state'] == 'queued'
    assert len([j for j in status()['jobs'] if j['state'] == 'running']) == 2
    scans = status()['testing'].get('groupScans', 0)
    time.sleep(1.5)
    assert status()['testing'].get('groupScans', 0) > scans, 'running jobs were not reconciled every second'
    assert cli('maintenance', check=False).returncode != 0
    cli('limit', '1')
    cli('cancel', first_job['id'])
    first.communicate(timeout=5)
    assert first.returncode == 143 and second.poll() is None
    time.sleep(2)
    assert job_for(third)['state'] == 'queued'
    print('PASS shared FIFO queue, spacing, limits, and cancellation isolation', flush=True)

    daemon.kill(); daemon.wait(timeout=5)
    assert second.poll() is None and third.poll() is None
    registry_file = root / 'registry.json'
    registry = json.loads(registry_file.read_text())
    for job in registry['jobs']:
        if job['id'] == second_job['id']:
            job['state'] = 'unverified'
    registry_file.write_text(json.dumps(registry))
    daemon = start_daemon()
    assert job_for(second)['state'] == 'running'
    assert job_for(third)['state'] == 'queued'
    cli('cancel', second_job['id'])
    second.communicate(timeout=5)
    assert second.returncode == 143
    out, _ = third.communicate(timeout=50)
    assert third.returncode == 0 and out == 'third\n'
    print('PASS coordinator restart preserves work and queue; verified identities recover unverified jobs', flush=True)

    payload = 'spaces; $(echo DO_NOT_RUN) `literal` "quotes"'
    script = 'import os,sys; print(os.getcwd()); print(sys.argv[1]); print(os.environ["GUARD_TEST_VALUE"]); print(sys.stdin.read()); sys.stderr.write("stderr intact\\n"); sys.exit(7)'
    io = run(sys.executable, '-c', script, payload, cwd=str(root), extra_env={'GUARD_TEST_VALUE': 'secret-environment-value'})
    until(lambda: job_for(io), 'IO registration missing')
    state_text = (root / 'registry.json').read_text()
    assert 'secret-environment-value' not in state_text and payload not in state_text
    out, err = io.communicate('stdin intact', timeout=20)
    assert io.returncode == 7 and str(root) in out and payload in out
    assert 'secret-environment-value' in out and 'stdin intact' in out and 'stderr intact' in err
    nested = run('/bin/sh', '-c', '"$GUARD_TEST_BINARY" run -- /bin/echo nested', extra_env={'GUARD_TEST_BINARY': binary})
    out, _ = nested.communicate(timeout=20)
    assert nested.returncode == 0 and out == 'nested\n'
    print('PASS cwd, arguments, environment, stdin/stdout/stderr, exit codes, nested jobs', flush=True)

    code, output = terminal_job(['/bin/sh', '-c', 'echo TTY_READY; read value; printf "TTY_VALUE:%s\\n" "$value"; exit 7'])
    assert code == 7 and b'TTY_VALUE:hello terminal' in output, (code, output)
    code, output = terminal_job(['/bin/sh', '-c', 'echo TTY_READY; exec sleep 120'], interrupt=True)
    assert code == 130, (code, output)
    print('PASS real terminal input, foreground process groups, and Ctrl-C exit status', flush=True)

    # A surviving child retains its slot after its leader exits. It must not be mistaken for a new job.
    descendant = run('/bin/sh', '-c', 'sleep 25 & sleep 2')
    group_job = until(lambda: (j if (j := job_for(descendant)) and j['state'] == 'running' else None), 'descendant job missing', 20)
    until(lambda: len(job_for(descendant)['members']) >= 2, 'descendants not observed', 5)
    descendant.wait(timeout=5)
    assert any(j['id'] == group_job['id'] for j in status()['jobs'])
    cli('cancel', group_job['id'])
    descendant.communicate(timeout=5)
    until(lambda: not status()['jobs'], 'descendant group retained after exit', 5)
    print('PASS process group retains slot and remains cancellable after leader exits', flush=True)

    marker = root / 'stubborn-ready'
    stubborn = run(sys.executable, '-c', 'import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).touch(); time.sleep(120)', str(marker))
    until(lambda: marker.exists(), 'stubborn process did not initialize', 20)
    stubborn_job = job_for(stubborn)
    cli('cancel', stubborn_job['id'])
    time.sleep(.5)
    assert stubborn.poll() is None and job_for(stubborn)['state'] == 'stopping'
    cli('cancel', stubborn_job['id'], '--force')
    stubborn.communicate(timeout=5)
    assert stubborn.returncode == 137
    until(lambda: not status()['jobs'], 'force-stopped group not cleaned up')
    print('PASS graceful cancellation and explicit force-stop escalation', flush=True)

    missing = run('/resource-guard-test/no-such-executable')
    missing.communicate(timeout=20)
    assert missing.returncode == 127
    until(lambda: not status()['jobs'], 'failed exec retained a slot')

    # Simulate stale PID/group reuse with an unrelated, separately grouped test-owned process.
    sentinel = subprocess.Popen(['/bin/sleep', '120'], start_new_session=True)
    children.append(sentinel)
    daemon.terminate(); daemon.wait(timeout=5)
    registry_file = root / 'registry.json'
    registry = json.loads(registry_file.read_text())
    registry['jobs'] = [dict(id='stale-identity', owner=dict(pid=sentinel.pid, seconds=0, micros=0),
                             group=sentinel.pid, members=[dict(pid=sentinel.pid, seconds=0, micros=0)],
                             name='stale-test', directory=str(root), state='running', created=time.time(), cancelled=False)]
    registry_file.write_text(json.dumps(registry))
    daemon = start_daemon()
    assert status()['jobs'][0]['state'] == 'unverified'
    assert cli('cancel', 'stale-identity', '--force', check=False).returncode != 0
    assert sentinel.poll() is None
    sentinel.terminate(); sentinel.wait(timeout=5)
    until(lambda: not status()['jobs'], 'stale group did not reconcile')
    print('PASS missing executable exit status and stale process identity cancellation refusal', flush=True)

    fixture.write_text('invalid sample')
    until(lambda: status()['sample'] is None, 'invalid metrics were accepted', 10)
    held = run('/bin/echo', 'no bypass')
    held_job = until(lambda: job_for(held), 'held job missing')
    time.sleep(2)
    assert held.poll() is None
    held.send_signal(signal.SIGINT)
    held.communicate(timeout=5)
    assert held.returncode == 130
    until(lambda: not status()['jobs'], 'interrupted wrapper not cleaned up')
    cli('maintenance')
    assert cli('maintenance', check=False).returncode != 0
    blocked = run('/bin/echo', 'maintenance')
    blocked.communicate(timeout=5)
    assert blocked.returncode == 75
    cli('resume')
    print('PASS unavailable metrics fail closed, Ctrl-C cleanup, maintenance admission lock', flush=True)
finally:
    # Stop only groups created by this isolated test coordinator.
    try:
        for job in status()['jobs']:
            cli('cancel', job['id'], '--force', check=False)
    except Exception:
        pass
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
    if daemon and daemon.poll() is None:
        daemon.terminate(); daemon.wait(timeout=5)
