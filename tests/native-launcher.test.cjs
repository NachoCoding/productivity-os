// Tests for src/native-launcher.ts. Also exports the fake machine (`harness`) and the shared per-client suite
// (`clientSuite`) used by the four tests/*-client.test.cjs files; this file's own tests register only when it is
// the test entry point, so requiring it from a client test does not run them twice.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const transpile = (file) => ts.transpileModule(fs.readFileSync(path.join(__dirname, '../src', file), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
const launcherCode = transpile('native-launcher.ts');
const infoPlist = (id) => Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleName</key>\n\t<string>Fixture</string>\n${id ? `\t<key>POSBuildID</key>\n\t<string>${id}</string>\n` : ''}</dict>\n</plist>\n`);

// A fake Mac for src/<file> (or the launcher alone when file is null) and ./native-launcher:
//   bundled / installed  build descriptions { id, exe, presets }; installed null = not installed (default: same as bundled)
//   setup                setup exit status (0 installs the bundled build), or (mode) => status
//   running              lsappinfo lists the app before any kickstart
//   loaded               `launchctl print` finds the LaunchAgent
//   startsAfter          lsappinfo polls after a kickstart before the app is listed (Infinity = never)
//   kickstartFails, openFails (stderr text), uid (undefined = no process.getuid)
function harness(file, world = {}) {
  const w = { bundled: { id: 'B2', exe: 'exe-2', presets: 'presets-2' }, setup: 0, running: false, loaded: false, startsAfter: 1, uid: 501, ...world };
  if (!('installed' in world)) w.installed = { ...w.bundled };
  const calls = [], reads = [];
  let kicked = false, polls = 0;
  const content = (build, part) => part === 'Contents/Info.plist' ? infoPlist(build.id) : part.startsWith('Contents/MacOS/') ? Buffer.from(build.exe) : part === 'Contents/Resources/pomodoro-presets.json' ? Buffer.from(build.presets) : undefined;
  const lookup = (name) => {
    const bundled = /^\/bundle\/assets\/[^/]+\.app\/(.+)$/.exec(name), installed = /^\/user\/Applications\/[^/]+\.app\/(.+)$/.exec(name);
    if (bundled && w.bundled) return content(w.bundled, bundled[1]);
    if (installed && w.installed) return content(w.installed, installed[1]);
  };
  const missing = (name) => Object.assign(new Error(`ENOENT: no such file or directory, open '${name}'`), { code: 'ENOENT' });
  const failure = (code, stderr) => Object.assign(new Error(`Command failed\n${stderr}`), { code, stderr });
  const running = () => w.running || (kicked && polls >= w.startsAfter);
  const run = async (command, args, options) => {
    args = Array.from(args);
    calls.push([command, args, { ...options }]);
    if (command === '/bin/bash') {
      const status = typeof w.setup === 'function' ? w.setup(args[1]) : w.setup;
      if (status) throw failure(status, w.setupStderr ?? `setup ${args[1]} failed\n`);
      w.installed = { ...w.bundled };
    } else if (command === '/usr/bin/lsappinfo') {
      if (kicked) polls++;
      return { stdout: running() ? 'ASN:0x0-0x1234-"Fixture":\n' : '', stderr: '' };
    } else if (command === '/bin/launchctl' && args[0] === 'print') {
      if (!w.loaded) throw failure(113, 'Could not find service in domain for user gui: 501\n');
    } else if (command === '/bin/launchctl' && args[0] === 'kickstart') {
      if (w.kickstartFails) throw failure(5, 'Could not kickstart service\n');
      kicked = true;
    } else if (command === '/usr/bin/open' && w.openFails) {
      throw failure(1, w.openFails);
    }
    return { stdout: '', stderr: '' };
  };
  const modules = {
    '@raycast/api': {
      environment: { assetsPath: '/bundle/assets' },
      closeMainWindow: async () => { calls.push(['close']); },
      showHUD: async (title) => { calls.push(['hud', title]); },
      showToast: async (options) => { calls.push(['toast', { ...options }]); return { hide: async () => { calls.push(['hide']); } }; },
      Toast: { Style: { Animated: 'animated', Failure: 'failure', Success: 'success' } },
    },
    child_process: { execFile: () => { throw new Error('execFile is only used promisified'); } },
    'fs/promises': {
      readFile: async (name) => { reads.push(name); const data = lookup(name); if (!data) throw missing(name); return data; },
      access: async (name) => { reads.push(name); if (!lookup(name)) throw missing(name); },
    },
    os: { homedir: () => '/user' },
    path,
    'timers/promises': { setTimeout: async () => {} },
    util: { promisify: () => run },
  };
  const load = (code, extra = {}) => {
    const exports = {};
    const require = (name) => { if (name in extra) return extra[name]; if (name in modules) return modules[name]; throw new Error(`Unexpected require: ${name}`); };
    vm.runInNewContext(code, { exports, require, Buffer, process: { getuid: () => w.uid } });
    return exports;
  };
  const launcher = load(launcherCode);
  const client = file ? load(transpile(file), { './native-launcher': launcher }) : {};
  // Process calls as flat argv arrays, and the order of every recorded step.
  const commands = () => calls.filter(([name]) => name.startsWith('/')).map(([name, args]) => [name, ...args]);
  const steps = () => calls.map(([name, args]) => (name === '/bin/launchctl' ? `launchctl ${args[0]}` : name.startsWith('/') ? path.basename(name) : name));
  return { ...client, launcher, calls, reads, world: w, commands, steps };
}

// The behaviour every native client shares. o: { file, name, bundleId, scheme, setup, launch, action, list, app, sample, background }
function clientSuite(o) {
  const app = `/user/Applications/${o.name}.app`;
  const service = `gui/501/${o.bundleId}`;
  const open = (command, background = false) => ['/usr/bin/open', ...(background ? ['-g'] : []), '-a', app, `${o.scheme}://${command}`];
  const setup = (mode) => ['/bin/bash', `/bundle/assets/${o.setup}`, mode];
  const launch = (world) => { const h = harness(o.file, world); return h[o.launch](o.sample).then(() => h); };

  test(`${o.name}: a current, running copy just receives the URL after Raycast closes`, async () => {
    const h = await launch({ running: true });
    assert.equal(h[o.app], app);
    assert.deepEqual(h.steps(), ['close', 'lsappinfo', 'open']);
    assert.deepEqual(h.commands(), [['/usr/bin/lsappinfo', 'find', `bundleid=${o.bundleId}`], open(o.sample)]);
    assert.ok(h.calls.filter(([name]) => name.startsWith('/')).every(([, , options]) => options.timeout > 0), 'every child process has a timeout');
  });

  test(`${o.name}: a stopped LaunchAgent is kickstarted and awaited before the URL is sent`, async () => {
    const h = await launch({ loaded: true, startsAfter: 2 });
    assert.deepEqual(h.steps(), ['close', 'lsappinfo', 'launchctl print', 'launchctl kickstart', 'lsappinfo', 'lsappinfo', 'open']);
    assert.deepEqual(h.commands().slice(1, 3), [['/bin/launchctl', 'print', service], ['/bin/launchctl', 'kickstart', service]]);
    assert.deepEqual(h.commands().at(-1), open(o.sample));
  });

  test(`${o.name}: without a loaded agent, or when kickstart fails or stalls, it falls back to open -a`, async () => {
    let h = await launch({ loaded: false });
    assert.deepEqual(h.steps(), ['close', 'lsappinfo', 'launchctl print', 'open']);
    h = await launch({ loaded: true, kickstartFails: true });
    assert.deepEqual(h.steps(), ['close', 'lsappinfo', 'launchctl print', 'launchctl kickstart', 'open']);
    h = await launch({ loaded: true, startsAfter: Infinity });
    assert.equal(h.steps().filter((step) => step === 'lsappinfo').length, 31, 'one check plus at most 30 polls (~3 s)');
    assert.deepEqual(h.commands().at(-1), open(o.sample));
    h = await launch({ loaded: true, uid: undefined });
    assert.deepEqual(h.steps(), ['close', 'open']);
  });

  test(`${o.name}: an outdated copy is updated (animated toast) before Raycast closes`, async () => {
    const h = await launch({ installed: { id: 'B1', exe: 'exe-1', presets: 'presets-1' }, running: true });
    assert.deepEqual(h.steps(), ['toast', 'bash', 'hide', 'close', 'lsappinfo', 'open']);
    assert.deepEqual(h.calls[0][1], { style: 'animated', title: `Updating ${o.name}…` });
    assert.deepEqual(h.commands()[0], setup('update'));
    assert.equal(h.calls[1][2].timeout, 30000);
  });

  test(`${o.name}: a busy update (75) still opens the installed copy, then explains how to finish`, async () => {
    const h = await launch({ installed: { id: 'B1', exe: 'exe-1', presets: 'presets-1' }, running: true, setup: 75 });
    assert.deepEqual(h.steps(), ['toast', 'bash', 'hide', 'close', 'lsappinfo', 'open', 'hud']);
    assert.deepEqual(h.calls.at(-1), ['hud', `Quit ${o.name} to finish updating`]);
    assert.deepEqual(h.commands().at(-1), open(o.sample));
  });

  test(`${o.name}: any other update failure never fails the command`, async () => {
    const h = harness(o.file, { installed: { id: 'B1', exe: 'exe-1', presets: 'presets-1' }, loaded: true, setup: 1 });
    await h[o.action](o.sample);
    assert.deepEqual(h.steps(), ['toast', 'bash', 'hide', 'close', 'lsappinfo', 'launchctl print', 'launchctl kickstart', 'lsappinfo', 'open', 'hud']);
    assert.deepEqual(h.calls.at(-1), ['hud', `${o.name} update failed; using the installed version`]);
    assert.equal(h.calls.some(([name, toast]) => name === 'toast' && toast.style === 'failure'), false);
  });

  test(`${o.name}: a missing copy is installed first`, async () => {
    const h = await launch({ installed: null });
    assert.deepEqual(h.calls[0][1], { style: 'animated', title: `Installing ${o.name}…` });
    assert.deepEqual(h.commands()[0], setup('install'));
    assert.deepEqual(h.steps(), ['toast', 'bash', 'hide', 'close', 'lsappinfo', 'launchctl print', 'open']);
  });

  test(`${o.name}: a failed install stops with a failure toast and opens nothing`, async () => {
    const h = harness(o.file, { installed: null, setup: 75, setupStderr: `Another ${o.name} setup is running; try again shortly.\n` });
    await h[o.action](o.sample);
    assert.deepEqual(h.steps(), ['toast', 'bash', 'toast']);
    assert.deepEqual(h.calls.at(-1)[1], { style: 'failure', title: `${o.name} could not open`, message: `Another ${o.name} setup is running; try again shortly.` });
  });

  test(`${o.name}: command validation rejects URL and shell injection before any side effect`, async () => {
    for (const command of ['area?path=/tmp/private', 'capture; rm -rf /', 'open/../../file', '', 'https://example.com', 'quit-if-idle', undefined]) {
      const h = harness(o.file);
      await assert.rejects(h[o.launch](command), /Unsupported/);
      assert.equal(h.calls.length + h.reads.length, 0);
    }
  });

  test(`${o.name}: ${o.background.length ? `only ${o.background.join(', ')} open` : 'no command opens'} in the background`, async () => {
    const h = harness(o.file, { running: true });
    for (const command of h[o.list]) await h[o.launch](command);
    const opened = h.commands().filter(([name]) => name === '/usr/bin/open');
    assert.deepEqual(opened, Array.from(h[o.list], (command) => open(command, o.background.includes(command))));
  });

  test(`${o.name}: installs without POSBuildID fall back to byte compares`, async () => {
    const legacy = { id: undefined, exe: 'exe-1', presets: 'presets-1' };
    let h = await launch({ bundled: legacy, installed: { ...legacy }, running: true });
    assert.deepEqual(h.steps(), ['close', 'lsappinfo', 'open']);
    h = await launch({ bundled: legacy, installed: { ...legacy, exe: 'exe-0' }, running: true });
    assert.deepEqual(h.commands()[0], setup('update'));
    h = await launch({ installed: legacy, running: true });
    assert.deepEqual(h.commands()[0], setup('update'), 'a stamped bundle replaces an unstamped install');
  });
}

module.exports = { harness, clientSuite, infoPlist };

if (require.main === module) {
  test('buildID reads the stamp from XML Info.plist text only', () => {
    const { launcher } = harness(null);
    assert.equal(launcher.buildID(infoPlist('5F0C1C9E-1C1B-4D1A-9E43-0F1D3B8C2A11')), '5F0C1C9E-1C1B-4D1A-9E43-0F1D3B8C2A11');
    assert.equal(launcher.buildID('<key>POSBuildID</key><string> x </string>'), 'x');
    assert.equal(launcher.buildID(infoPlist()), undefined);
    assert.equal(launcher.buildID(Buffer.from('bplist00Ñ\u0001\u0002')), undefined);
    assert.equal(launcher.buildID(undefined), undefined);
  });

  test('installState compares build IDs and never reads executables when both copies are stamped', async () => {
    const spec = { name: 'Fixture', executable: 'Fixture', compare: ['Contents/Resources/pomodoro-presets.json'] };
    let h = harness(null);
    assert.equal(await h.launcher.installState(spec), 'current');
    assert.equal(h.reads.some((name) => name.includes('/MacOS/') && name.startsWith('/bundle')), false);
    h = harness(null, { installed: { id: 'B1', exe: 'exe-2', presets: 'presets-2' } });
    assert.equal(await h.launcher.installState(spec), 'outdated');
    h = harness(null, { installed: null });
    assert.equal(await h.launcher.installState(spec), 'missing');
    h = harness(null, { bundled: null, installed: { id: 'B1', exe: 'exe-1', presets: 'presets-1' } });
    assert.equal(await h.launcher.installState(spec), 'current', 'an unbuilt or mid-rebuild bundle never blocks the installed copy');
  });

  test('installState byte-compares extra files (Health Breaks presets) only for unstamped copies', async () => {
    const spec = { name: 'Fixture', executable: 'Fixture', compare: ['Contents/Resources/pomodoro-presets.json'] };
    const legacy = { id: undefined, exe: 'exe-1', presets: 'presets-1' };
    let h = harness(null, { bundled: legacy, installed: { ...legacy, presets: 'presets-0' } });
    assert.equal(await h.launcher.installState(spec), 'outdated');
    h = harness(null, { bundled: legacy, installed: { ...legacy } });
    assert.equal(await h.launcher.installState(spec), 'current');
    h = harness(null, { installed: { id: 'B2', exe: 'exe-1', presets: 'presets-0' } });
    assert.equal(await h.launcher.installState(spec), 'current', 'matching stamps win over bytes');
  });

  test('errorMessage prefers the last stderr line and drops the "Error:" prefix', () => {
    const { launcher } = harness(null);
    assert.equal(launcher.errorMessage(Object.assign(new Error('Command failed: /bin/bash x'), { stderr: 'Warning: signed differently\nBuild Health Breaks first.\n' })), 'Build Health Breaks first.');
    assert.equal(launcher.errorMessage(new Error('spawn ENOENT')), 'spawn ENOENT');
    assert.equal(launcher.errorMessage('plain'), 'plain');
  });

  test('an open failure surfaces as a failure toast naming the app', async () => {
    const h = harness('health-breaks-client.ts', { running: true, openFails: 'LSOpenURLsWithRole() failed with error -10810\n' });
    await h.healthAction('settings');
    assert.deepEqual(h.calls.at(-1), ['toast', { style: 'failure', title: 'Health Breaks could not open', message: 'LSOpenURLsWithRole() failed with error -10810' }]);
  });

  test('SETUP_BUSY matches the setup scripts\' busy exit status', () => {
    assert.equal(harness(null).launcher.SETUP_BUSY, 75);
    for (const script of ['health-breaks', 'clipboard-history', 'drop-shelf', 'screenshot-studio']) {
      assert.match(fs.readFileSync(path.join(__dirname, `../assets/setup-${script}.sh`), 'utf8'), /exit 75/);
    }
  });
}
