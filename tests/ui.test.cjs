// Renders every command outside Raycast and presses its actions.
//
// @raycast/api and @raycast/utils are replaced with small stand-ins, but the code under test is the
// real thing: website blocking goes through the bundled assets/blocker.sh (or the helper named by
// POS_TEST_HELPER, e.g. an older v3 copy) on a temporary hosts file, so each test covers a view,
// the client in src/lib.ts and the helper together. Color filters, the menu bar agent and
// Amphetamine are simulated by the small state machines below. `world.calls` records every
// process and script a test causes, and `world.gate` holds them all so a first frame can be seen.
const { afterEach, test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const childProcess = require('node:child_process');
const React = require('react');
const renderer = require('react-test-renderer');
const ts = require('typescript');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const project = path.resolve(__dirname, '..');
const HELPER = process.env.POS_TEST_HELPER ? path.resolve(process.env.POS_TEST_HELPER) : path.join(project, 'assets/blocker.sh');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'productivity-os-ui-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));

const world = {};
const actualNow = Date.now;
Date.now = () => world.now ?? actualNow();
function advanceClock(ms) { world.now += ms; world.uptime += ms; saveClock(); }
function saveClock() { fs.writeFileSync(`${world.hosts}.clock.json`, JSON.stringify({bootID:"ui-test", uptimeMs:world.uptime, wallMs:world.now, unlocked:true, available:true})); }
function reset(overrides = {}) {
  world.hosts = path.join(tmp, `hosts-${Math.random().toString(36).slice(2)}`);
  fs.writeFileSync(world.hosts, '127.0.0.1 localhost\n');
  Object.assign(world, {
    now: actualNow(), uptime: 100000,
    setup: true, filters: false, filtersBroken: false, menuBar: 'stopped', menuBarConfigured: false,
    awake: { installed: true, running: true, active: false, remaining: -3, started: undefined },
    huds: [], toasts: [], launched: [], launchOptions: [], opened: [], pushed: [], storage: {}, prefs: {}, closed: 0, popped: 0, confirm: true, locked: 0,
    cache: {}, calls: [], gate: undefined, stalled: false, fakeHelper: {}, disabled: [], clipboard: undefined,
    guardState: 'missing', guardCancelled: [], guardSnapshot: {
      version: 1, limit: 2, blocked: false, reason: 'Ready', sampleAge: 1,
      sample: { pressure: 'normal', cpu: 20, swapIn: 0, swapOut: 0, swapUsed: 0, memory: 16 * 1024 ** 3 },
      jobs: [], processes: [{ identity: { pid: 123 }, name: 'Warp', rss: 1024 ** 3 }],
    },
    memoryApps: [], quitApps: [], priorityInstalled: false, priorityEnabled: false,
    priorityError: undefined, priorityRaw: undefined, priorityCheckedAt: Date.now()/1000, priorityErrors: [],
    memoryRaw: undefined, memoryError: undefined, guardRaw: undefined, quitError: undefined,
  }, overrides);
  api.environment.launchType = 'userInitiated';
  saveClock();
}
function deferred() { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; }
/** Holds every process and script until `release()`, so the first frame of a view can be inspected. */
function hold() { world.gate = deferred(); }
function release() { const gate = world.gate; world.gate = undefined; gate?.resolve(); }
const gated = (start) => (world.gate ? world.gate.promise.then(start) : start());
// Helper v4 reports stalled rounds; the stand-in marks the Pomodoro in a reply as stalled on request.
function markStalled(op, stdout) {
  if (!world.stalled || (op !== 'status' && op !== 'pomodoro-status') || !stdout.trim()) return stdout;
  const value = JSON.parse(stdout);
  const pomodoro = op === 'status' ? value.pomodoro : value;
  if (pomodoro) pomodoro.stalled = true;
  return `${JSON.stringify(value)}\n`;
}
const failures = () => world.toasts.filter((toast) => toast.style === 'failure').map((toast) => toast.title);

// ---- processes: sudo → the bundled helper on the temporary hosts file; the menu bar helper → a state machine
let pending = 0;
const realExecFile = childProcess.execFile;
const realExistsSync = fs.existsSync;
fs.existsSync = (filename) => String(filename).endsWith('/Resource Guard/resource-guard') ? world.guardState !== 'missing' : String(filename).endsWith('/productivity-os/resource-priority') ? world.priorityInstalled : realExistsSync(filename);
const helper = (...args) => childProcess.execFileSync('/bin/bash', [HELPER, ...args], { env: { ...process.env, HOSTS_FILE: world.hosts }, encoding: 'utf8' });
function menuBarHelper(command) {
  const state = world.menuBar;
  if (command === 'status') return state;
  if (command === 'quit') return (world.menuBar = 'stopped');
  if (command === 'show') return state === 'stopped' ? 'stopped' : (world.menuBar = 'visible');
  if (!world.menuBarConfigured) {
    world.menuBarConfigured = true;
    world.menuBar = 'visible';
    return 'setup';
  }
  return (world.menuBar = command === 'hide' || state !== 'hidden' ? 'hidden' : 'visible');
}
childProcess.execFile = (command, args, options, callback) => {
  if (typeof options === 'function') [callback, options] = [options, {}];
  pending++;
  const done = (error, stdout, stderr) => { pending--; callback(error, stdout, stderr); };
  const reply = (code, stdout, stderr = '') => gated(() => setImmediate(() => done(code ? Object.assign(new Error(stderr), { code }) : null, stdout, stderr)));
  if (command === '/usr/bin/sudo') {
    if (args[1].endsWith('/resource-priority')) {
      if (world.priorityError) return reply(1, '', world.priorityError);
      if (world.priorityRaw !== undefined) return reply(0, world.priorityRaw);
      if (args[2] === 'enable') world.priorityEnabled = true;
      if (args[2] === 'disable') world.priorityEnabled = false;
      return reply(0, JSON.stringify({ enabled: world.priorityEnabled, processCount: world.priorityEnabled ? 3 : 0, errors: world.priorityErrors, checkedAt: world.priorityCheckedAt }));
    }
    world.calls.push(`helper:${args[2]}`);
    if (!world.setup) return reply(1, '', 'sudo: a password is required');
    if (world.fakeHelper[args[2]] !== undefined) return reply(0, `${world.fakeHelper[args[2]]}\n`);
    return void gated(() => realExecFile('/bin/bash', [HELPER, ...args.slice(2)], { ...options, env: { ...process.env, HOSTS_FILE: world.hosts } }, (error, stdout, stderr) => done(error, markStalled(args[2], stdout), stderr)));
  }
  if (command === '/bin/launchctl') { world.calls.push('launchctl'); return reply(world.setup ? 0 : 113, '', 'Could not find service'); }
  if (command.endsWith('/menubar-divider')) { world.calls.push(`menubar:${args[0]}`); return reply(0, `${menuBarHelper(args[0])}\n`); }
  if (command.endsWith('/Resource Guard/resource-guard')) {
    world.calls.push(`guard:${args[0]}`);
    if (world.guardState === 'unavailable') return reply(1, '', 'Guard unavailable');
    if (args[0] === 'status') return reply(0, world.guardRaw ?? JSON.stringify(world.guardSnapshot));
    if (args[0] === 'apps') {
      if (world.memoryError) return reply(1, '', world.memoryError);
      return reply(0, world.memoryRaw ?? JSON.stringify({ apps: world.memoryApps, codingBytes: 1024 ** 3, codingProcessCount: 3, codingIncomplete: false, measuredAt: Date.now()/1000 }));
    }
    if (args[0] === 'quit-app') {
      if (world.quitError) return reply(1, '', world.quitError);
      world.quitApps.push(args.slice(1)); return reply(0, 'Quit requested. Save any work if prompted.');
    }
    if (args[0] === 'limit') world.guardSnapshot.limit = Number(args[1]);
    if (args[0] === 'cancel') world.guardCancelled.push(args.slice(1));
    return reply(0, '');
  }
  if (command === '/bin/bash' && args[0].endsWith('/setup-resource-guard.sh')) {
    world.guardState = 'ready'; return reply(0, 'Installed');
  }
  return realExecFile(command, args, options, done);
};

// ---- AppleScript: color filters (JXA) and Amphetamine
async function runAppleScript(script, options = {}) {
  if (options.language === 'JavaScript') {
    if (script.includes('SACLockScreenImmediate')) { world.calls.push('jxa:lock'); await gated(() => undefined); world.locked++; return '0'; }
    const toggle = script.includes('MADisplayFilterPrefSetCategoryEnabled(1, !');
    world.calls.push(toggle ? 'jxa:toggle-filters' : 'jxa:read-filters');
    await gated(() => undefined);
    if (world.filtersBroken) throw new Error('private API missing');
    if (toggle) world.filters = !world.filters;
    return String(world.filters);
  }
  const awake = world.awake;
  const start = script.match(/set wasActive to session is active\nstart new session with options \{duration:(\d+), interval:(\w+), displaySleepAllowed:(true|false)\}\nreturn wasActive/);
  const startDefault = script.includes('if session is active then return "running"\nstart new session\nreturn "started"');
  const call = start ? 'start' : startDefault ? 'start-default' : script.includes('is not running') ? 'status' : script.includes('session time remaining') ? 'remaining' : script.includes('end session') ? 'end' : script.includes('session is active') ? 'active' : undefined;
  if (!call) throw new Error(`unexpected script: ${script}`);
  world.calls.push(`amphetamine:${call}`);
  await gated(() => undefined);
  if (call === 'status') return !awake.running ? 'stopped' : !awake.active ? 'idle' : String(awake.remaining);
  if (call === 'remaining') return String(awake.active ? awake.remaining : -3);
  if (call === 'end') { awake.active = false; return ''; }
  if (call === 'active') return String(awake.active);
  if (call === 'start-default') {
    if (awake.active) return 'running';
    awake.active = awake.running = true;
    awake.started = { duration: 'default' };
    return 'started';
  }
  const replaced = awake.active;
  awake.active = awake.running = true;
  awake.started = { duration: Number(start[1]), interval: start[2], displaySleep: start[3] === 'true' };
  awake.remaining = Number(start[1]) * 60;
  return String(replaced);
}

// ---- @raycast/api and @raycast/utils stand-ins
const host = (name, members = {}) => Object.assign((props) => React.createElement(name, props), { displayName: name }, members);
const names = (prefix) => new Proxy({}, { get: (_, key) => `${prefix}.${String(key)}` });
class Toast {
  constructor(options) { Object.assign(this, options); }
  show() {}
  hide() {}
}
Toast.Style = { Animated: 'animated', Success: 'success', Failure: 'failure' };
const showToast = async (options) => { const toast = new Toast(options); world.toasts.push(toast); return toast; };
// Raycast's Cache: synchronous, shared by every command, and it notifies subscribers in-process.
const cacheSubscribers = new Set();
class Cache {
  get(key) { return world.cache[key]; }
  has(key) { return key in world.cache; }
  set(key, value) { world.cache[key] = value; for (const subscriber of [...cacheSubscribers]) subscriber(key, value); }
  remove(key) { const had = key in world.cache; delete world.cache[key]; for (const subscriber of [...cacheSubscribers]) subscriber(key, undefined); return had; }
  subscribe(subscriber) { cacheSubscribers.add(subscriber); return () => cacheSubscribers.delete(subscriber); }
}
const api = {
  Action: host('Action', { CopyToClipboard: host('Action.CopyToClipboard'), Paste: host('Action.Paste'), OpenInBrowser: host('Action.OpenInBrowser'), SubmitForm: host('Action.SubmitForm'), Style: { Destructive: 'destructive', Regular: 'regular' } }),
  ActionPanel: host('ActionPanel', { Section: host('ActionPanel.Section'), Submenu: host('ActionPanel.Submenu') }),
  Alert: { ActionStyle: { Destructive: 'destructive' } },
  Cache,
  Clipboard: { copy: async (text) => { world.clipboard = text; } },
  Color: names('Color'),
  Detail: host('Detail'),
  Form: host('Form', { Description: host('Form.Description'), Dropdown: host('Form.Dropdown', { Item: host('Form.Dropdown.Item') }), TextField: host('Form.TextField'), DatePicker: host('Form.DatePicker', { Type: { DateTime: 'datetime' } }) }),
  Icon: names('Icon'),
  Keyboard: { Shortcut: { Common: names('Shortcut') } },
  LaunchType: { UserInitiated: 'userInitiated', Background: 'background' },
  List: host('List', { Item: host('List.Item'), Section: host('List.Section'), EmptyView: host('List.EmptyView') }),
  LocalStorage: { getItem: async (key) => world.storage[key], setItem: async (key, value) => { world.storage[key] = value; } },
  MenuBarExtra: host('MenuBarExtra', { Item: host('MenuBarExtra.Item'), Section: host('MenuBarExtra.Section'), Separator: host('MenuBarExtra.Separator'), Submenu: host('MenuBarExtra.Submenu') }),
  Toast,
  closeMainWindow: async () => { world.closed++; },
  confirmAlert: async () => world.confirm,
  environment: { supportPath: path.join(tmp, 'support'), assetsPath: path.join(project, 'assets'), launchType: 'userInitiated' },
  getApplications: async () => { world.calls.push('apps'); await gated(() => undefined); return world.awake.installed ? [{ bundleId: 'com.if.Amphetamine' }] : []; },
  getPreferenceValues: () => world.prefs,
  launchCommand: async (options) => {
    // Raycast refuses to launch a command the user has disabled.
    if (world.disabled.includes(options.name)) throw new Error('Command is disabled');
    world.launched.push(options.name); world.launchOptions.push(options);
  },
  open: async (url) => { world.opened.push(url); },
  popToRoot: async () => { world.popped++; },
  showHUD: async (text) => { world.huds.push(text); },
  showToast,
  useNavigation: () => ({ push: (element, onPop) => world.pushed.push({ element, onPop }), pop: () => world.popped++ }),
};
// Like the real hook: runs on mount unless `execute` is false, `revalidate` always runs, and an
// error without `onError` raises the "Failed to fetch latest data" toast.
function usePromise(fn, args = [], options = {}) {
  const execute = options.execute !== false;
  const [state, setState] = React.useState({ isLoading: execute });
  const latest = React.useRef({ fn, args, options });
  latest.current = { fn, args, options };
  const revalidate = React.useCallback(async () => {
    setState((previous) => ({ ...previous, isLoading: true }));
    try {
      const data = await latest.current.fn(...latest.current.args);
      setState({ isLoading: false, data });
    } catch (error) {
      setState((previous) => ({ ...previous, isLoading: false, error }));
      if (latest.current.options.onError) await latest.current.options.onError(error);
      else await showToast({ style: 'failure', title: 'Failed to fetch latest data', message: String(error) });
    }
  }, []);
  React.useEffect(() => { if (execute) void revalidate(); }, [execute, JSON.stringify(args)]);
  return { ...state, revalidate };
}
const utils = {
  usePromise, useCachedPromise: usePromise, runAppleScript: (...args) => { pending++; return runAppleScript(...args).finally(() => pending--); },
  showFailureToast: (error, options = {}) => showToast({ style: 'failure', title: options.title ?? 'Something went wrong', message: String(error) }),
};
const stubs = { '@raycast/api': api, '@raycast/utils': utils, 'dns/promises': { lookup: async () => [{ address: '127.0.0.1' }, { address: '::1' }] } };
const loadModule = Module._load;
Module._load = function (request, ...rest) { return stubs[request] ?? loadModule.call(this, request, ...rest); };
for (const extension of ['.ts', '.tsx']) {
  require.extensions[extension] = (module, filename) => module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true } }).outputText, filename);
}
const command = (name) => require(path.join(project, 'src', name)).default;

// ---- driving the rendered tree
async function settle() {
  for (let quiet = 0, turn = 0; quiet < 3 && turn < 500; turn++) {
    await renderer.act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
    quiet = pending === 0 ? quiet + 1 : 0;
  }
}
const mounted = [];
async function mount(name, props = {}) {
  let tree;
  await renderer.act(async () => { tree = renderer.create(React.createElement(command(name), props)); });
  mounted.push(tree);
  await settle();
  return tree;
}
// Unmounting stops timers a view started, which would otherwise keep the test process alive.
afterEach(() => renderer.act(() => { for (const tree of mounted.splice(0)) tree.unmount(); }));
const all = (tree, type) => tree.root.findAll((node) => node.type === type);
const one = (tree, type, match = () => true) => {
  const found = all(tree, type).filter((node) => match(node.props));
  assert.equal(found.length, 1, `expected one ${type}, found ${found.length} among [${all(tree, type).map((node) => node.props.title ?? node.props.id).join(', ')}]`);
  return found[0];
};
const row = (tree, title) => one(tree, 'List.Item', (props) => props.title === title);
const tags = (node) => (node.props.accessories ?? []).map((accessory) => accessory.tag?.value ?? accessory.text);
function actionsOf(node) {
  if (!node.props.actions) return [];
  let panel;
  renderer.act(() => { panel = renderer.create(node.props.actions); });
  return panel.root.findAll((child) => typeof child.type === 'string' && /^Action(\.|$)/.test(child.type));
}
const actionTitles = (node) => actionsOf(node).map((action) => action.props.title);
/** Presses the action called `title` in the node's action panel (or the node itself for menu items). */
async function press(node, title, ...args) {
  const target = node.props.onAction && node.props.title === title ? node : actionsOf(node).find((action) => action.props.title === title);
  assert.ok(target, `no action "${title}" among [${actionTitles(node).join(', ')}]`);
  await renderer.act(async () => { await (target.props.onAction ?? target.props.onSubmit)(...args); });
  await settle();
}
const change = async (node, value) => { await renderer.act(async () => { node.props.onChange(value); }); await settle(); };
const run = async (name, args = {}) => { await command(name)({ arguments: args }); };
const session = () => JSON.parse(helper('session'));
const SOCIAL = 12, NEWS = 8, VIDEO = 6;
const clock = (time) => new Date(time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
const menuItem = (tree, title) => one(tree, 'MenuBarExtra.Item', (props) => props.title === title);
const menuTitles = (tree) => all(tree, 'MenuBarExtra.Item').map((item) => item.props.title);
/** Creates a command's tree without waiting for its loads, so the first frame can be inspected. */
async function open(name, props = {}) {
  let tree;
  await renderer.act(async () => { tree = renderer.create(React.createElement(command(name), props)); });
  mounted.push(tree);
  return tree;
}
async function mountElement(element) {
  let tree;
  await renderer.act(async () => { tree = renderer.create(element); });
  mounted.push(tree); await settle(); return tree;
}
async function finishReview(element) {
  const waiting = await mountElement(element);
  assert.match(actionTitles(one(waiting, 'Form'))[0], /^Wait /);
  // Leaving and reopening the view must preserve the privileged cooldown.
  advanceClock(60001);
  const ready = await mountElement(element);
  await change(one(ready, 'Form.TextField', (props) => props.id === 'reason'), 'Need to check this for work');
  await press(one(ready, 'Form'), 'Confirm Unblock', {});
  return ready;
}


test('Block Site blocks both hostnames, verifies them, and Undo removes only the manual block', async () => {
  reset();
  helper('add-many', 'social', 'example.com');
  const tree = await mount('block-site', { arguments: { domain: ' https://Example.com/some/path ' } });
  assert.equal(helper('list'), 'example.com\tmanual,social\nwww.example.com\tmanual\n');
  const detail = one(tree, 'Detail');
  assert.match(detail.props.markdown, /Block entry saved: example\.com, www\.example\.com/);
  assert.match(detail.props.markdown, /resolves these hostnames to a blocked address/);
  await press(detail, 'Undo: Unblock Site');
  assert.equal(helper('list'), 'example.com\tmanual,social\nwww.example.com\tmanual\n');
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'example.com\tsocial\n');
  assert.equal(world.huds.length, 1);
  assert.match(world.huds[0], /^🔓 Unblocked/);
  assert.deepEqual(failures(), []);
});

test('Block Site rejects invalid input and shows setup when blocking is not installed', async () => {
  for (const domain of ['localhost', '127.0.0.1', 'ftp://example.com', 'bad domain', '']) {
    reset();
    const before = fs.readFileSync(world.hosts, 'utf8');
    const tree = await mount('block-site', { arguments: { domain } });
    assert.match(one(tree, 'Detail').props.markdown, /Invalid domain/, domain);
    assert.equal(fs.readFileSync(world.hosts, 'utf8'), before);
  }
  reset({ setup: false });
  const tree = await mount('block-site', { arguments: { domain: 'example.com' } });
  assert.match(one(tree, 'Detail').props.markdown, /Productivity OS setup[\s\S]*sudo \/bin\/bash '.*assets\/setup\.sh'/);
});

test('Blocked Sites reviews removals and cannot end an unfinished focus round', async () => {
  reset();
  helper('add-many', 'manual', 'a.com', 'b.com');
  helper('add-many', 'social', 'b.com', 'c.com');
  let tree = await mount('blocked-sites');
  assert.equal(one(tree, 'List').props.filtering, true);
  await press(row(tree, 'a.com'), 'Review Unblock…');
  assert.ok(helper('list').includes('a.com'));
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'b.com\tmanual,social\nc.com\tsocial\n');
  await press(row(tree, 'c.com'), 'Unblock All Social Preset');
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'b.com\tmanual\n');
  helper('start-focus', '10', 'Deep work', 'c.com', 'd.com');
  tree = await mount('blocked-sites');
  // The helper refuses every removal during focus, so the list says until when instead of offering them.
  const locked = `Locked until ${clock(session().endsAt)}`;
  assert.deepEqual(actionTitles(row(tree, 'd.com')), [locked, 'Check Block', 'Copy Domain', 'Open in Browser (Test Block)', 'Refresh']);
  assert.equal(actionsOf(row(tree, 'd.com')).find((action) => action.props.title === 'Copy Domain').props.shortcut, 'Shortcut.Copy');
  world.calls = [];
  await press(row(tree, 'd.com'), locked);
  assert.deepEqual([world.toasts.at(-1).title, world.calls, session().label], [locked, [], 'Deep work']);
  world.toasts = [];
  // A review opened anyway (from a stale screen) is refused, and its page goes back instead of looping.
  const stale = await mountElement(React.createElement(require(path.join(project, 'src/unlock-request.tsx')).UnlockForm, { operations: [['end-focus']], pushed: true }));
  assert.match(one(stale, 'Detail').props.markdown, /Focus is still protected/);
  assert.deepEqual(actionTitles(one(stale, 'Detail')), ['Back', 'Try Again']);
  const popped = world.popped;
  await press(one(stale, 'Detail'), 'Back');
  assert.equal(world.popped, popped + 1);
  advanceClock(10 * 60000 + 1); helper('expire');
  tree = await mount('blocked-sites');
  await press(row(tree, 'b.com'), 'Unblock All Sites…');
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), '');
  assert.deepEqual(failures(), []);
  tree = await mount('blocked-sites');
  assert.equal(one(tree, 'List.EmptyView').props.title, 'Nothing blocked');
});

test('Unblock Site unblocks the typed site with its www variant, or falls back to the list', async () => {
  reset();
  helper('add-many', 'manual', 'x.com', 'www.x.com', 'keep.com');
  const pendingReview = await mount('unblock-site', { arguments: { domain: 'https://www.x.com/home' } });
  assert.equal(helper('list'), 'keep.com\tmanual\nwww.x.com\tmanual\nx.com\tmanual\n');
  assert.match(actionTitles(one(pendingReview, 'Form'))[0], /^Wait /);
  advanceClock(60001);
  const review = await mount('unblock-site', { arguments: { domain: 'https://www.x.com/home' } });
  await change(one(review, 'Form.TextField'), 'Check a work link');
  await press(one(review, 'Form'), 'Confirm Unblock', {});
  assert.equal(helper('list'), 'keep.com\tmanual\n');
  assert.equal(world.huds.length, 1);
  assert.match(world.huds[0], /^🔓 Unblocked/);
  let tree = await mount('unblock-site', { arguments: { domain: 'kee' } });
  assert.equal(one(tree, 'List').props.searchText, 'kee');
  assert.equal(helper('list'), 'keep.com\tmanual\n');
  tree = await mount('unblock-site', { arguments: { domain: '' } });
  assert.deepEqual(all(tree, 'List.Item').map((item) => item.props.title), ['keep.com']);
  assert.deepEqual(failures(), []);
});

test('Block Preset blocks, completes a partial preset, and unblocks', async () => {
  reset();
  helper('add', 'instagram.com', 'social');
  helper('add', 'instagram.com', 'manual');
  let tree = await mount('block-preset');
  assert.deepEqual(all(tree, 'List.Item').map((item) => [item.props.title, ...tags(item)]), [['Social', `1/${SOCIAL} blocked`], ['News', `${NEWS} sites`], ['Video', `${VIDEO} sites`]]);
  assert.deepEqual(actionTitles(row(tree, 'Social')), ['Unblock Social', `Block Remaining ${SOCIAL - 1}`, 'Refresh']);
  await press(row(tree, 'Social'), `Block Remaining ${SOCIAL - 1}`);
  assert.equal(helper('list').trim().split('\n').length, SOCIAL);
  assert.deepEqual(world.huds, [`🔒 Blocked Social (${SOCIAL} sites)`]);
  tree = await mount('block-preset');
  assert.deepEqual(tags(row(tree, 'Social')), ['blocked']);
  await press(row(tree, 'Social'), 'Unblock Social');
  assert.deepEqual([world.launched, world.pushed.at(-1).element.props.operations], [[], [['remove-all-with-tag', 'social']]]);
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'instagram.com\tmanual\n');
  // Successful submits leave Raycast at its root search.
  assert.equal(world.popped, 2);
  assert.deepEqual(failures(), []);
});

test('Start Focus Session starts presets and custom sessions and reports bad input in the form', async () => {
  reset();
  let tree = await mount('start-focus-session');
  const submit = (values) => press(one(tree, 'Form'), 'Start Focus Session', values);
  await submit({ preset: 'custom', duration: '30' });
  assert.match(one(tree, 'Form.Dropdown', (props) => props.id === 'preset').props.error, /Nothing is currently blocked/);
  for (const customMinutes of ['0', '1441', '1.5', 'abc', '']) {
    await submit({ preset: 'social', duration: 'custom', customMinutes });
    assert.equal(session(), null, customMinutes);
  }
  await submit({ preset: 'news', duration: '45' });
  assert.equal(session().label, 'News focus');
  assert.equal(helper('list').trim().split('\n').length, NEWS);
  assert.match(world.huds.at(-1), /^🔒 Focus until .+ \(News, 45 min\)$/);
  assert.deepEqual([world.closed, world.popped], [1, 1]);
  advanceClock(45 * 60000 + 1); helper('expire');
  helper('add', 'manual.com', 'manual');
  tree = await mount('start-focus-session');
  await submit({ preset: 'custom', duration: 'custom', customMinutes: ' 20 ' });
  assert.equal(session().label, 'Custom focus');
  assert.ok(helper('list').includes('manual.com\tfocus,manual\n'));
  assert.ok(Math.abs(session().endsAt - Date.now() - 20 * 60000) < 5000);
  assert.deepEqual(failures(), []);
});

test('Quick Focus starts from arguments, defaults to Social for 30 minutes, and guards its input', async () => {
  reset();
  await run('quick-focus', {});
  assert.equal(session().label, 'Social focus');
  assert.ok(Math.abs(session().endsAt - Date.now() - 30 * 60000) < 5000);
  await run('quick-focus', { preset: 'video', minutes: ' 20 ' });
  assert.equal(session().label, 'Social focus');
  assert.deepEqual(failures(), ['Could not start session']);
  reset();
  await run('quick-focus', { preset: 'video', minutes: ' 20 ' });
  assert.equal(session().label, 'Video focus');
  assert.equal(helper('list').trim().split('\n').length, VIDEO);
  assert.match(world.huds.at(-1), /^🔒 Focus until .+ \(Video, 20 min\)$/);
  reset(); helper('add', 'work.com', 'manual');
  await run('quick-focus', { preset: 'custom', minutes: '5' });
  assert.equal(session().label, 'Custom focus');
  for (const minutes of ['abc', '0', '1441', '2.5']) await run('quick-focus', { preset: 'news', minutes });
  assert.equal(session().label, 'Custom focus');
  assert.deepEqual(failures(), ['Invalid duration', 'Invalid duration', 'Invalid duration', 'Invalid duration']);
  reset();
  await run('quick-focus', { preset: 'custom' });
  assert.deepEqual(failures(), ['Nothing is currently blocked']);
  reset({ setup: false });
  await run('quick-focus', {});
  assert.deepEqual([world.launched, failures(), world.huds], [['run-setup'], [], []]);
});

test('Focus Status shows the countdown and flips the session, color filters and menu bar icons', async () => {
  reset();
  helper('start-focus', '90', 'Social focus', 'x.com');
  let tree = await mount('focus-status');
  const menu = () => one(tree, 'MenuBarExtra');
  const item = (title) => one(tree, 'MenuBarExtra.Item', (props) => props.title === title);
  assert.deepEqual([menu().props.title, menu().props.icon, menu().props.isLoading], ['1h 30m', 'Icon.Lock', false]);
  assert.match(menu().props.tooltip, /^Social focus until /);
  await press(item('Color Filters: Off'), 'Color Filters: Off');
  await press(item('Menu Bar Icons: Shown'), 'Menu Bar Icons: Shown');
  await press(item('Menu Bar Icons: Shown'), 'Menu Bar Icons: Shown');
  assert.deepEqual([world.filters, world.menuBar], [true, 'hidden']);
  assert.deepEqual(world.huds, ['⚫ Color filters on', 'Hold ⌘ and drag the icons to keep to the right of ‹, then toggle again', '🙈 Menu bar icons hidden']);
  // The helper refuses new sessions and unblocks during focus: one disabled item says until when.
  const locked = item(`Locked until ${clock(session().endsAt)}`);
  assert.equal(locked.props.onAction, undefined);
  assert.ok(!menuTitles(tree).some((title) => ['Start Focus Session…', 'Review Ending Session…'].includes(title)));
  assert.equal(all(tree, 'MenuBarExtra.Submenu').filter((submenu) => submenu.props.title.startsWith('Unblock Site')).length, 0);
  advanceClock(90 * 60000 + 1); helper('expire');
  tree = await mount('focus-status');
  assert.deepEqual([menu().props.title, menu().props.icon], [undefined, 'Icon.LockUnlocked']);
  item('Color Filters: On');
  item('Menu Bar Icons: Hidden');
  item('Start Focus Session…');
  await press(item('Open Productivity OS…'), 'Open Productivity OS…');
  assert.deepEqual(world.launched, ['dashboard']);
  assert.deepEqual(failures(), []);
  // Not set up, and the color filter read failing: still loads, with no toasts from a background run.
  reset({ setup: false, filtersBroken: true });
  tree = await mount('focus-status');
  assert.equal(menu().props.isLoading, false);
  await press(item('Set Up Productivity OS…'), 'Set Up Productivity OS…');
  assert.deepEqual([world.launched, world.toasts.length], [['run-setup'], 0]);
});

test('Dashboard shows every switch with its state and flips each one', async () => {
  reset();
  helper('add', 'manual.com', 'manual');
  const tree = await mount('dashboard');
  const state = (title) => tags(row(tree, title));
  assert.deepEqual(all(tree, 'List.Item').map((item) => item.props.title), ['Resource Guard', 'Pomodoro', 'Health Breaks', 'Drop Shelf', 'Clipboard History', 'Screenshot Studio', 'Color Filters', 'Menu Bar Icons', 'Lock Screen and Keep Awake', 'Keep Awake', 'Focus Session', 'Block Social', 'Block News', 'Block Video', 'Blocked Sites']);
  assert.deepEqual(['Color Filters', 'Menu Bar Icons', 'Keep Awake', 'Focus Session', 'Block News', 'Blocked Sites'].map((title) => state(title)[0]), ['Off', 'Shown', 'Off', 'Off', 'Off', '1 blocked']);

  await press(row(tree, 'Color Filters'), 'Turn on Color Filters');
  assert.deepEqual([world.filters, state('Color Filters'), actionTitles(row(tree, 'Color Filters'))[0]], [true, ['On'], 'Turn off Color Filters']);
  await press(row(tree, 'Color Filters'), 'Turn off Color Filters');
  assert.deepEqual([world.filters, state('Color Filters')], [false, ['Off']]);

  await press(row(tree, 'Menu Bar Icons'), 'Hide Menu Bar Icons');
  assert.deepEqual([world.menuBar, state('Menu Bar Icons'), world.toasts.at(-1).title], ['visible', ['Shown'], 'Hold ⌘ and drag the icons to keep to the right of ‹, then toggle again']);
  await press(row(tree, 'Menu Bar Icons'), 'Hide Menu Bar Icons');
  assert.deepEqual([world.menuBar, state('Menu Bar Icons')], ['hidden', ['Hidden']]);
  await press(row(tree, 'Menu Bar Icons'), 'Show Menu Bar Icons');
  assert.deepEqual([world.menuBar, state('Menu Bar Icons')], ['visible', ['Shown']]);

  await press(row(tree, 'Lock Screen and Keep Awake'), 'Lock Now');
  // Locking shows exactly one HUD, and the toast that announced it is dismissed.
  assert.deepEqual([world.locked, world.awake.started, state('Keep Awake'), world.huds], [1, { duration: 0, interval: '0', displaySleep: true }, ['No time limit'], ['🔒 Locked · awake with no time limit']]);
  await press(row(tree, 'Lock Screen and Keep Awake'), '1h');
  assert.deepEqual([world.locked, world.awake.started, world.huds.at(-1)], [2, { duration: 60, interval: 'minutes', displaySleep: true }, '🔒 Locked · awake for 1h · replaced the running session']);
  await press(row(tree, 'Keep Awake'), 'End Session');
  assert.deepEqual(actionTitles(row(tree, 'Keep Awake')), ['30m', '1h', '2h', '4h', 'No Time Limit', 'Custom Duration or End Time…', 'Refresh']);
  await press(row(tree, 'Keep Awake'), '2h');
  assert.deepEqual([world.awake.started, state('Keep Awake'), world.toasts.at(-1).title], [{ duration: 120, interval: 'minutes', displaySleep: false }, ['02:00h left'], '☕ Keeping awake for 2h']);
  await press(row(tree, 'Keep Awake'), 'No Time Limit');
  assert.deepEqual([world.awake.started, state('Keep Awake'), world.toasts.at(-1).title], [{ duration: 0, interval: '0', displaySleep: false }, ['No time limit'], '☕ Keeping awake with no time limit · replaced the running session']);
  await press(row(tree, 'Keep Awake'), 'End Session');
  assert.deepEqual([world.awake.active, state('Keep Awake'), world.toasts.at(-1).title], [false, ['Off'], '😴 Keep awake ended']);

  await press(row(tree, 'Block News'), 'Block News');
  assert.deepEqual([state('Block News'), state('Blocked Sites')], [['Blocked'], [`${NEWS + 1} blocked`]]);
  await press(row(tree, 'Block News'), 'Unblock News');
  assert.deepEqual(state('Block News'), ['Blocked']);
  await finishReview(world.pushed.at(-1).element);
  assert.deepEqual([state('Block News'), helper('list')], [['Off'], 'manual.com\tmanual\n']);

  assert.ok(world.toasts.every((toast) => toast.style === 'success' || (toast.style === 'animated' && toast.title === 'Locking…')));
  helper('start-focus', '25', 'Video focus', 'youtube.com');
  await press(row(tree, 'Focus Session'), 'Refresh');
  assert.match(row(tree, 'Focus Session').props.subtitle, /^Video focus until /);
  assert.deepEqual(state('Focus Session'), ['25m left']);
  // Neither ending nor replacing the session is possible before it ends, so neither is offered.
  const locked = `Locked until ${clock(session().endsAt)}`;
  assert.deepEqual(actionTitles(row(tree, 'Focus Session')), [locked, 'Refresh']);
  await press(row(tree, 'Focus Session'), locked);
  assert.deepEqual([failures(), session().label], [[locked], 'Video focus']);
  await press(row(tree, 'Blocked Sites'), 'Open Blocked Sites');
  // Pushed views read the status the dashboard just loaded instead of reading it again.
  assert.equal(world.pushed.at(-1).element.props.preloaded, true);
  assert.equal(world.pushed.length, 2);
});

test('Dashboard stays quiet and useful when blocking is not set up or Amphetamine is missing', async () => {
  reset({ setup: false });
  world.awake.installed = false;
  const tree = await mount('dashboard');
  assert.deepEqual(all(tree, 'List.Item').map((item) => item.props.title), ['Resource Guard', 'Pomodoro', 'Health Breaks', 'Drop Shelf', 'Clipboard History', 'Screenshot Studio', 'Color Filters', 'Menu Bar Icons', 'Install Amphetamine', 'Set Up Website Blocking']);
  assert.equal(one(tree, 'List').props.isLoading, false);
  await press(row(tree, 'Color Filters'), 'Turn on Color Filters');
  await press(row(tree, 'Color Filters'), 'Refresh');
  assert.deepEqual([world.filters, failures()], [true, []]);
  await press(row(tree, 'Set Up Website Blocking'), 'Show Setup Command');
  assert.deepEqual([world.pushed.length, world.pushed[0].element.props.pushed], [1, true]);
  // A failing switch reports the failure in its own toast and leaves the row readable.
  world.filtersBroken = true;
  await press(row(tree, 'Color Filters'), 'Turn off Color Filters');
  assert.deepEqual(failures(), ['That did not work']);
  assert.equal(row(tree, 'Color Filters').props.subtitle, 'Could not read the setting');
  assert.deepEqual(tags(row(tree, 'Color Filters')), ['Unavailable']);
});

test('Run Setup reports the installation and blocked sites, or the setup command', async () => {
  reset();
  helper('add', 'a.com', 'manual');
  helper('add-many', 'news', 'bbc.com', 'www.bbc.com');
  helper('start-focus', '5', 'Focus', 'a.com');
  let tree = await mount('run-setup');
  assert.equal(row(tree, 'Setup complete').props.subtitle, '3 sites blocked: 1 manual, 2 preset, 1 focus.');
  assert.match(tags(row(tree, 'Setup complete'))[0], /^helper v[34]$/);
  assert.deepEqual(['a.com', 'bbc.com', 'www.bbc.com'].map((title) => row(tree, title).props.accessories.map((accessory) => accessory.tag)), [['focus', 'manual'], ['news'], ['news']]);
  reset({ setup: false });
  tree = await mount('run-setup');
  assert.match(one(tree, 'Detail').props.markdown, /sudo \/bin\/bash '.*assets\/setup\.sh'/);
});

test('Toggle Color Filters and Toggle Menu Bar Icons report the new state', async () => {
  reset();
  await run('toggle-color-filters');
  await run('toggle-color-filters');
  world.filtersBroken = true;
  await run('toggle-color-filters');
  assert.deepEqual([world.huds, failures()], [['⚫ Color filters on', '🌈 Color filters off'], ['Could not toggle color filters']]);
  reset();
  for (let turn = 0; turn < 4; turn++) await run('toggle-menu-bar-icons');
  assert.deepEqual(world.huds, ['Hold ⌘ and drag the icons to keep to the right of ‹, then toggle again', '🙈 Menu bar icons hidden', '👀 Menu bar icons shown', '🙈 Menu bar icons hidden']);
  // The helper runs from a copy in the support directory, identical to the bundled binary.
  const installed = path.join(api.environment.supportPath, 'menubar-divider');
  assert.ok(fs.readFileSync(installed).equals(fs.readFileSync(path.join(project, 'assets/menubar-divider'))));
  // A stale copy is replaced; the agent it stops was hiding icons, so the result is "shown" without another toggle.
  fs.writeFileSync(installed, 'stale');
  await run('toggle-menu-bar-icons');
  assert.deepEqual([world.huds.at(-1), world.menuBar], ['👀 Menu bar icons shown', 'stopped']);
  assert.ok(fs.readFileSync(installed).equals(fs.readFileSync(path.join(project, 'assets/menubar-divider'))));
  assert.deepEqual(failures(), []);
});

test('Keep Awake commands start, describe and end Amphetamine sessions', async () => {
  reset();
  // Start Keep Awake uses Amphetamine's own default session and leaves a running one alone; commands that
  // take a duration treat an empty field as no time limit and replace the running session.
  await run('amphetamine-start');
  assert.deepEqual([world.awake.started, world.huds], [{ duration: 'default' }, ['☕ Keep awake started']]);
  await run('amphetamine-start');
  assert.deepEqual([failures(), world.huds.at(-1), world.awake.started], [[], '☕ Keep awake is already running', { duration: 'default' }]);
  world.huds = [];
  world.awake.remaining = 754;
  await run('amphetamine-remaining');
  for (const [remaining, text] of [[0, 'Your current session has no time limit'], [-1, 'Your session is Trigger-based'], [7260, 'Remaining time: 02:01h']]) {
    world.awake.remaining = remaining;
    await run('amphetamine-remaining');
    assert.equal(world.huds.at(-1), text);
  }
  await run('amphetamine-end');
  await run('amphetamine-remaining');
  assert.deepEqual(world.huds.slice(0, 1).concat(world.huds.slice(-2)), ['Remaining time: 12:34min', '😴 Keep awake ended', 'There is no session running']);
  await run('amphetamine-end');
  assert.deepEqual(failures(), ['Keep awake is not running']);

  reset({ prefs: { displaySleepAllowed: true } });
  await run('amphetamine-quick-start', { hours: '1', minutes: '30', seconds: '1' });
  assert.deepEqual([world.awake.started, world.huds], [{ duration: 91, interval: 'minutes', displaySleep: true }, ['☕ Keeping awake for 1h 31m (rounded up)']]);
  reset();
  await run('amphetamine-quick-start', {});
  await run('amphetamine-quick-start', { minutes: '45' });
  assert.deepEqual([world.awake.started, world.huds], [{ duration: 45, interval: 'minutes', displaySleep: false }, ['☕ Keeping awake with no time limit', '☕ Keeping awake for 45m · replaced the running session']]);
  await run('amphetamine-quick-start', { minutes: '4.5' });
  assert.deepEqual(failures(), ['Invalid duration']);

  reset();
  world.awake.installed = false;
  for (const name of ['amphetamine-start', 'amphetamine-quick-start', 'amphetamine-end', 'amphetamine-remaining']) await run(name);
  assert.deepEqual([failures(), world.huds, world.awake.started], [Array(4).fill('Amphetamine is not installed'), [], undefined]);
});

test('Configure Keep Awake remembers the duration, validates it, and supports an end time', async () => {
  reset({ storage: { 'amphetamine-duration': '2', 'amphetamine-unit': 'hours' } });
  let tree = await mount('amphetamine-configure');
  const field = (type, id) => one(tree, type, (props) => props.id === id);
  const submit = () => press(one(tree, 'Form'), 'Start Keep Awake');
  assert.deepEqual([field('Form.TextField', 'duration').props.value, field('Form.TextField', 'duration').props.title, field('Form.Dropdown', 'unit').props.value], ['2', 'Duration (in hours)', 'hours']);
  // The dropdown reporting its own value must not overwrite what is remembered.
  await change(field('Form.Dropdown', 'unit'), 'hours');
  assert.equal(world.storage['amphetamine-unit'], 'hours');
  await submit();
  assert.deepEqual([world.awake.started, world.huds, world.popped], [{ duration: 120, interval: 'minutes', displaySleep: false }, ['☕ Keeping awake for 2h'], 1]);

  reset();
  tree = await mount('amphetamine-configure');
  assert.deepEqual([field('Form.TextField', 'duration').props.value, field('Form.Dropdown', 'unit').props.value], ['30', 'minutes']);
  // Raycast reports a dropdown's initial value when the form opens; that must not be stored as a choice.
  await change(field('Form.Dropdown', 'unit'), 'minutes');
  assert.equal(world.storage['amphetamine-unit'], undefined);
  await change(field('Form.Dropdown', 'unit'), 'hours');
  await change(field('Form.Dropdown', 'unit'), 'minutes');
  assert.equal(world.storage['amphetamine-unit'], 'minutes');
  await change(field('Form.TextField', 'duration'), '1.5');
  await submit();
  assert.deepEqual([world.awake.started, failures(), world.storage['amphetamine-duration']], [undefined, ['Could not start keep awake'], '1.5']);
  await change(field('Form.TextField', 'duration'), '');
  await submit();
  assert.deepEqual([world.awake.started, world.huds.at(-1)], [{ duration: 0, interval: '0', displaySleep: false }, '☕ Keeping awake with no time limit']);

  reset();
  tree = await mount('amphetamine-configure');
  await change(field('Form.Dropdown', 'sessionType'), 'time');
  await submit();
  assert.deepEqual([world.awake.started, failures()], [undefined, ['Could not start keep awake']]);
  await change(field('Form.DatePicker', 'target'), new Date(Date.now() - 60000));
  assert.equal(field('Form.DatePicker', 'target').props.error, 'Choose a future date and time.');
  await change(field('Form.DatePicker', 'target'), new Date(Date.now() + 90 * 60000));
  assert.equal(field('Form.DatePicker', 'target').props.error, undefined);
  await submit();
  assert.deepEqual([world.awake.started, world.huds], [{ duration: 90, interval: 'minutes', displaySleep: false }, ['☕ Keeping awake for 1h 30m']]);
});

test('Lock Screen and Keep Awake keeps the Mac running, then locks', async () => {
  reset();
  await run('lock-keep-awake', {});
  assert.deepEqual([world.locked, world.awake.started, world.huds], [1, { duration: 0, interval: '0', displaySleep: true }, ['🔒 Locked · awake with no time limit']]);
  await run('lock-keep-awake', {});
  assert.deepEqual([world.locked, world.huds.at(-1)], [2, '🔒 Locked · awake with no time limit · replaced the running session']);
  await run('lock-keep-awake', { minutes: '90' });
  assert.deepEqual([world.locked, world.awake.started, world.huds.at(-1), world.huds.length], [3, { duration: 90, interval: 'minutes', displaySleep: true }, '🔒 Locked · awake for 1h 30m · replaced the running session', 3]);
  // The installed check runs once per lock.
  world.calls = [];
  await run('lock-keep-awake', {});
  assert.deepEqual(world.calls, ['apps', 'amphetamine:start', 'jxa:lock']);
  await run('lock-keep-awake', { minutes: 'soon' });
  assert.deepEqual([world.locked, failures()], [4, ['Invalid duration']]);
  world.awake.installed = false;
  await run('lock-keep-awake', {});
  assert.deepEqual([world.locked, failures().at(-1)], [4, 'Amphetamine is not installed']);
});

test('Resource Guard installs, shows measurements, changes limits, and opens Activity Monitor', async () => {
  reset();
  const tree = await mount('resource-guard');
  await press(row(tree, 'Not installed'), 'Install Resource Guard');
  assert.equal(world.guardState, 'ready');
  assert.ok(row(tree, 'Memory pressure: normal'));
  assert.deepEqual(tags(row(tree, 'Warp')), ['1.0 GB RSS']);
  await press(row(tree, '0/2 running · 0 waiting'), '1 Job');
  assert.equal(world.guardSnapshot.limit, 1);
  await press(row(tree, '0/1 running · 0 waiting'), 'Open Activity Monitor');
  assert.equal(world.opened.at(-1), '/System/Applications/Utilities/Activity Monitor.app');
  assert.deepEqual(failures(), []);
});

test('Resource Guard confirms specific job cancellation and separates force stop from observed processes', async () => {
  reset({ guardState: 'ready' });
  world.guardSnapshot.jobs = [{ id: 'test-job', name: 'test-build', directory: '/tmp/project', state: 'running', created: Date.now() / 1000, cancelled: false }];
  const tree = await mount('resource-guard');
  world.confirm = false;
  await press(row(tree, 'test-build'), 'Cancel Job');
  assert.deepEqual(world.guardCancelled, []);
  world.confirm = true;
  await press(row(tree, 'test-build'), 'Cancel Job');
  assert.deepEqual(world.guardCancelled, [['test-job']]);
  world.guardSnapshot.jobs[0].state = 'stopping';
  world.guardSnapshot.jobs[0].cancelled = true;
  await press(row(tree, 'test-build'), 'Refresh');
  await press(row(tree, 'test-build'), 'Force Stop Job');
  assert.deepEqual(world.guardCancelled.at(-1), ['test-job', '--force']);
  assert.ok(!actionTitles(row(tree, 'Warp')).includes('Cancel Job'));
});

test('Resource Guard explains pressure, missing measurements, and service errors', async () => {
  reset({ guardState: 'ready' });
  world.guardSnapshot.blocked = true;
  world.guardSnapshot.reason = 'Memory pressure: critical';
  world.guardSnapshot.sample.pressure = 'critical';
  const tree = await mount('resource-guard');
  assert.ok(all(tree, 'List.Item').some((node) => node.props.title === 'Memory pressure: critical'));
  world.guardSnapshot.sample = null;
  const header = all(tree, 'List.Item')[0];
  await press(header, 'Refresh');
  assert.ok(row(tree, 'Measurements unavailable'));
  world.guardState = 'unavailable';
  await press(row(tree, 'Measurements unavailable'), 'Refresh');
  assert.match(row(tree, 'Monitoring unavailable').props.subtitle, /Guard unavailable/);
});

test('Dashboard and menu bar link to Resource Guard', async () => {
  reset();
  const dashboard = await mount('dashboard');
  await press(row(dashboard, 'Resource Guard'), 'Open Resource Guard');
  assert.ok(world.pushed.length);
  const menu = await mount('focus-status');
  await press(one(menu, 'MenuBarExtra.Item', (props) => props.title === 'Resource Guard: Not installed'), 'Resource Guard: Not installed');
  assert.equal(world.launched.at(-1), 'resource-guard');
});

test('RAM controls show grouped app memory, protect coding apps, and only quit the confirmed app', async () => {
  reset({ guardState: 'ready' });
  world.guardSnapshot.processes = [];
  world.memoryApps = [
    { identity: { pid: 10, seconds: 20, micros: 30 }, bundleID: 'test.browser', path: '/Applications/Browser.app', name: 'Browser', bytes: 2 * 1024 ** 3, processCount: 8, protected: false, incomplete: false },
    { identity: { pid: 11, seconds: 21, micros: 31 }, bundleID: 'dev.warp.Warp-Stable', path: '/Applications/Warp.app', name: 'Warp', bytes: 1024 ** 3, processCount: 4, protected: true, reason: 'Coding host', incomplete: false },
  ];
  const tree = await mount('resource-guard');
  assert.ok(row(tree, 'Warp and agents stay running'));
  assert.deepEqual(tags(row(tree, 'Browser')), ['2.0 GB estimated']);
  assert.ok(!actionTitles(row(tree, 'Warp')).some((title) => title?.startsWith('Quit ')));
  world.confirm = false;
  await press(row(tree, 'Browser'), 'Quit Browser to Free RAM');
  assert.deepEqual(world.quitApps, []);
  world.confirm = true;
  await press(row(tree, 'Browser'), 'Quit Browser to Free RAM');
  assert.deepEqual(world.quitApps, [['10', '20', '30', 'test.browser']]);
  assert.match(world.toasts.at(-1).message, /Quit requested/);
});

test('CPU priority shows administrator setup separately from RAM controls and can be toggled', async () => {
  reset({ guardState: 'ready' });
  const tree = await mount('resource-guard');
  assert.ok(actionTitles(row(tree, 'Warp & Agents: CPU Priority Off')).includes('Copy CPU Priority Setup Command'));
  world.priorityInstalled = true;
  await press(row(tree, 'Warp & Agents: CPU Priority Off'), 'Refresh');
  await press(row(tree, 'Warp & Agents: CPU Priority Off'), 'Favor Warp and Agents');
  assert.equal(world.priorityEnabled, true);
  await press(row(tree, 'Warp & Agents: CPU Priority On'), 'Turn off CPU Priority');
  assert.equal(world.priorityEnabled, false);
  assert.deepEqual(world.quitApps, []);
});

test('CPU priority distinguishes missing, inaccessible, stale, and malformed status without claiming Off', async () => {
  reset({ guardState: 'ready', priorityInstalled: true, priorityEnabled: true, priorityError: 'Permission denied' });
  const tree = await mount('resource-guard');
  assert.match(row(tree, 'CPU Priority: Status Unavailable').props.subtitle, /Permission denied/);
  assert.ok(!all(tree, 'List.Item').some((node) => node.props.title === 'Warp & Agents: CPU Priority Off'));
  world.priorityError = undefined;
  world.priorityCheckedAt = Date.now()/1000 - 120;
  await press(row(tree, 'CPU Priority: Status Unavailable'), 'Refresh');
  assert.ok(row(tree, 'CPU Priority: Monitoring Stale'));
  world.priorityRaw = '{"enabled":true}';
  await press(row(tree, 'CPU Priority: Monitoring Stale'), 'Refresh');
  assert.match(row(tree, 'CPU Priority: Status Unavailable').props.subtitle, /Invalid CPU priority response/);
  world.priorityRaw = undefined;
  world.priorityCheckedAt = Date.now()/1000;
  world.priorityErrors = ['Could not restore process 123'];
  await press(row(tree, 'CPU Priority: Status Unavailable'), 'Refresh');
  assert.ok(row(tree, 'CPU Priority: Needs Attention'));
  await press(row(tree, 'CPU Priority: Needs Attention'), 'Turn off CPU Priority');
  assert.equal(world.toasts.at(-1).style, 'failure');
});

test('Malformed helper payloads show errors instead of crashing or offering unsafe app actions', async () => {
  reset({ guardState: 'ready', memoryRaw: '{"apps":[{"name":"fake"}]}', guardRaw: '{"version":1,"jobs":[],"processes":[]}' });
  const tree = await mount('resource-guard');
  assert.ok(row(tree, 'Could not measure app memory'));
  assert.ok(row(tree, 'Monitoring unavailable'));
  assert.ok(!all(tree, 'List.Item').some((node) => node.props.title === 'fake'));
  world.memoryRaw = 'not-json';
  await press(row(tree, 'Could not measure app memory'), 'Refresh');
  assert.ok(row(tree, 'Could not measure app memory'));
});

test('Failed app refresh hides stale Quit actions and a refused quit does not claim memory was freed', async () => {
  reset({ guardState: 'ready' });
  world.memoryApps = [{ identity: { pid: 20, seconds: 50, micros: 1 }, bundleID: 'test.notes', path: '/Applications/Notes.app', name: 'QA Notes', bytes: 1024, processCount: 1, protected: false, incomplete: false }];
  const tree = await mount('resource-guard');
  world.quitError = 'The app declined to quit';
  await press(row(tree, 'QA Notes'), 'Quit QA Notes to Free RAM');
  assert.equal(world.toasts.at(-1).style, 'failure');
  assert.deepEqual(world.quitApps, []);
  world.memoryError = 'Cannot enumerate processes';
  await press(row(tree, 'QA Notes'), 'Refresh');
  assert.ok(row(tree, 'Could not measure app memory'));
  assert.ok(!all(tree, 'List.Item').some((node) => node.props.title === 'QA Notes'));
});

test('Pomodoro status follows protected focus, elapsed break, and manual next-round readiness', async () => {
  reset();
  helper('start-pomodoro', '1', '1', '2', '4', 'Test focus', 'focus.example.com');
  let tree = await mount('dashboard');
  assert.match(row(tree, 'Pomodoro').props.subtitle, /Focus paused/);
  assert.deepEqual(tags(row(tree, 'Pomodoro')), ['Paused · sites locked']);
  helper('pomodoro-checkpoint', 'ui-monitor');
  for (let step = 0; step < 6; step++) { advanceClock(10000); helper('pomodoro-checkpoint', 'ui-monitor'); }
  tree = await mount('dashboard');
  assert.match(row(tree, 'Pomodoro').props.subtitle, /Break · 1m left/);
  assert.equal(helper('list'), 'focus.example.com\tpomodoro\n');
  advanceClock(61000); helper('expire');
  tree = await mount('focus-status');
  assert.ok(all(tree, 'MenuBarExtra.Item').some((item) => item.props.title === 'Pomodoro: Ready for the next round'));
  assert.equal(JSON.parse(helper('pomodoro-status')).phase, 'ready');
  assert.equal(helper('list'), 'focus.example.com\tpomodoro\n');
});

test('Unblock review cannot submit before its wait or without a reason', async () => {
  reset(); helper('add', 'example.com', 'manual');
  let tree = await mount('unlock-request', { launchContext: { operations: [['remove', 'example.com']] } });
  await press(one(tree, 'Form'), 'Wait 60s', {});
  assert.equal(helper('list'), 'example.com\tmanual\n');
  assert.deepEqual(failures(), ['Wait 60 more seconds']);
  advanceClock(60001);
  tree = await mount('unlock-request', { launchContext: { operations: [['remove', 'example.com']] } });
  await press(one(tree, 'Form'), 'Confirm Unblock', {});
  assert.match(one(tree, 'Form.TextField').props.error, /short reason/);
  assert.equal(helper('list'), 'example.com\tmanual\n');
});

test('Views open with the last values any command read, then refresh them in place', async () => {
  reset();
  helper('add', 'manual.com', 'manual');
  world.filters = true;
  await mount('dashboard');
  // Everything changes behind the cache's back; the next open shows the cached values first.
  world.filters = false;
  helper('add-many', 'news', 'bbc.com');
  world.calls = [];
  hold();
  const tree = await open('dashboard');
  const state = (title) => tags(row(tree, title));
  assert.equal(one(tree, 'List').props.isLoading, true);
  assert.deepEqual(['Color Filters', 'Menu Bar Icons', 'Keep Awake', 'Focus Session', 'Blocked Sites'].map(state), [['On'], ['Shown'], ['Off'], ['Off'], ['1 blocked']]);
  // No row is hidden or blank while it reloads.
  assert.equal(all(tree, 'List.Item').length, 15);
  release();
  await settle();
  assert.deepEqual([state('Color Filters'), state('Blocked Sites'), one(tree, 'List').props.isLoading], [['Off'], ['2 blocked'], false]);
  // With a cached "set up" verdict the setup check does not run again; the status read alone does.
  assert.ok(!world.calls.includes('helper:version') && !world.calls.includes('launchctl'), world.calls.join());
  // The menu bar and the website views open with the dashboard's status.
  hold();
  const menu = await open('focus-status');
  assert.ok(all(menu, 'MenuBarExtra.Submenu').some((submenu) => submenu.props.title === 'Unblock Site (2)'));
  assert.ok(menuItem(menu, 'Color Filters: Off'));
  const list = await open('blocked-sites');
  assert.deepEqual(all(list, 'List.Item').map((item) => item.props.title), ['bbc.com', 'manual.com']);
  release();
  await settle();
});

test('During focus, every action the helper would refuse says until when instead', async () => {
  reset();
  helper('add-many', 'social', 'instagram.com', 'www.instagram.com');
  helper('start-focus', '30', 'Deep work', 'x.com');
  const locked = `Locked until ${clock(session().endsAt)}`;
  let tree = await mount('dashboard');
  assert.deepEqual(actionTitles(row(tree, 'Focus Session')), [locked, 'Refresh']);
  // Adding blocks stays possible; removing them does not.
  assert.deepEqual(actionTitles(row(tree, 'Block Social')), [`Block Remaining ${SOCIAL - 2}`, locked, 'Refresh']);
  tree = await mount('block-preset');
  assert.deepEqual(actionTitles(row(tree, 'Social')), [locked, `Block Remaining ${SOCIAL - 2}`, 'Refresh']);
  tree = await mount('start-focus-session');
  assert.match(one(tree, 'Form.Description').props.text, new RegExp(`^${locked}`));
  // Unblock Site opens the list, which explains the lock, rather than a review the helper refuses.
  tree = await mount('unblock-site', { arguments: { domain: 'instagram.com' } });
  assert.deepEqual([one(tree, 'List').props.searchText, actionTitles(row(tree, 'instagram.com'))[0]], ['instagram.com', locked]);
  // The diagnostics page drops its unblock action too.
  tree = await mountElement(React.createElement(require(path.join(project, 'src/block-diagnostics.tsx')).default, { domains: ['instagram.com'] }));
  assert.deepEqual(actionTitles(one(tree, 'Detail')), ['Check Again', 'Copy Diagnostic Report']);
  assert.deepEqual(failures(), []);
  // A paused Pomodoro focus round has no end time yet.
  advanceClock(30 * 60000 + 1); helper('expire');
  helper('start-pomodoro', '1', '1', '2', '4', 'Deep', 'focus.example.com');
  tree = await mount('dashboard');
  assert.deepEqual([actionTitles(row(tree, 'Focus Session')), tags(row(tree, 'Focus Session'))], [['Locked during focus', 'Refresh'], ['Locked during focus']]);
  tree = await mount('focus-status');
  assert.equal(menuItem(tree, 'Locked during focus').props.onAction, undefined);
  // In a break nothing is locked, but a Pomodoro plan still rules out a second timer.
  helper('pomodoro-checkpoint', 'ui-monitor');
  for (let step = 0; step < 6; step++) { advanceClock(10000); helper('pomodoro-checkpoint', 'ui-monitor'); }
  tree = await mount('dashboard');
  assert.match(row(tree, 'Pomodoro').props.subtitle, /^Break/);
  assert.deepEqual(actionTitles(row(tree, 'Focus Session')), ['Open Pomodoro', 'Refresh']);
  assert.ok(actionTitles(row(tree, 'Block Social')).includes('Unblock Social'));
  tree = await mount('focus-status');
  assert.ok(!menuTitles(tree).includes('Start Focus Session…'));
});

test('A stalled Pomodoro round can be ended through the usual review', async () => {
  reset({ stalled: true });
  helper('start-pomodoro', '25', '5', '15', '4', 'Deep', 'focus.example.com');
  let tree = await mount('dashboard');
  assert.deepEqual([tags(row(tree, 'Pomodoro')), row(tree, 'Pomodoro').props.subtitle], [['Stalled'], 'Focus stalled · 25m left']);
  assert.deepEqual(actionTitles(row(tree, 'Focus Session')), ['Locked during focus', 'End Stalled Round…', 'Refresh']);
  await press(row(tree, 'Pomodoro'), 'End Stalled Round…');
  assert.deepEqual([world.pushed.at(-1).element.props.operations, world.pushed.at(-1).element.props.pushed], [[['end-pomodoro']], true]);
  // The real helper re-checks the stall: v4 answers NOT_STALLED (only the stand-in says stalled), v3
  // has no such operation. Either way the page explains and goes back; the round is untouched.
  const refused = await mountElement(world.pushed.at(-1).element);
  assert.match(one(refused, 'Detail').props.markdown, /^## (This round is not stalled|Could not prepare this request)\n/);
  assert.deepEqual(actionTitles(one(refused, 'Detail')), ['Back', 'Try Again']);
  assert.equal(JSON.parse(helper('pomodoro-status')).phase, 'focus');
  tree = await mount('blocked-sites');
  assert.deepEqual(actionTitles(row(tree, 'focus.example.com')).slice(0, 2), ['Locked during focus', 'End Stalled Round…']);
  tree = await mount('focus-status');
  await press(menuItem(tree, 'End Stalled Round…'), 'End Stalled Round…');
  assert.deepEqual(world.launchOptions.at(-1), { name: 'unlock-request', type: 'userInitiated', context: { operations: [['end-pomodoro']] } });
});

test('Background menu-bar runs refresh only the countdown and blocks, and re-check setup only after a failed read', async () => {
  reset({ guardState: 'ready' });
  helper('start-focus', '30', 'Deep work', 'x.com');
  await mount('focus-status');
  world.filters = true;
  world.menuBar = 'hidden';
  world.calls = [];
  api.environment.launchType = 'background';
  let tree = await mount('focus-status');
  assert.ok(world.calls.length && world.calls.every((call) => call.startsWith('helper:') && call !== 'helper:version'), world.calls.join());
  // The rows it skipped show their cached values.
  assert.deepEqual(['Color Filters: Off', 'Menu Bar Icons: Shown', 'Resource Guard: 0/2 running · 0 waiting'].map((title) => !!menuItem(tree, title)), [true, true, true]);
  assert.deepEqual([one(tree, 'MenuBarExtra').props.title, one(tree, 'MenuBarExtra').props.isLoading], ['30m', false]);
  // A failed read does re-check setup, and the failure stays quiet.
  world.calls = [];
  world.fakeHelper = { status: 'garbage' };
  tree = await mount('focus-status');
  assert.ok(world.calls.includes('helper:version'), world.calls.join());
  assert.deepEqual([one(tree, 'MenuBarExtra').props.icon, world.toasts.length], ['Icon.ExclamationMark', 0]);
  menuItem(tree, 'Could not read status — retry');
  // sudo asking for a password means setup is needed, without a separate check.
  world.fakeHelper = {};
  world.setup = false;
  world.calls = [];
  tree = await mount('focus-status');
  assert.deepEqual([world.calls.filter((call) => call === 'helper:version'), !!menuItem(tree, 'Set Up Productivity OS…')], [[], true]);
});

test('Dashboard switches flip at once, ignore a second press, and each action reloads only what it changed', async () => {
  reset();
  const tree = await mount('dashboard');
  const state = (title) => tags(row(tree, title));
  const action = (title, name) => actionsOf(row(tree, title)).find((each) => each.props.title === name);
  // The toggle reports the new state: the row flips before it finishes and is not read again.
  world.calls = [];
  hold();
  const turnOn = action('Color Filters', 'Turn on Color Filters').props.onAction;
  let pressing;
  await renderer.act(async () => { pressing = turnOn(); await new Promise((resolve) => setTimeout(resolve, 20)); });
  assert.deepEqual(state('Color Filters'), ['On']);
  // A second ↵ while the first runs does nothing.
  await renderer.act(async () => { await turnOn(); });
  release();
  await renderer.act(async () => { await pressing; });
  await settle();
  assert.deepEqual([world.filters, state('Color Filters'), world.calls], [true, ['On'], ['jxa:toggle-filters']]);
  world.calls = [];
  await press(row(tree, 'Menu Bar Icons'), 'Hide Menu Bar Icons');
  assert.deepEqual([state('Menu Bar Icons'), world.calls], [['Shown'], ['menubar:toggle']]);
  world.calls = [];
  await press(row(tree, 'Block News'), 'Block News');
  assert.deepEqual(state('Block News'), ['Blocked']);
  assert.ok(world.calls.every((call) => call.startsWith('helper:')), world.calls.join());
  assert.deepEqual([world.calls.filter((call) => call === 'helper:add-many').length, world.calls.filter((call) => call === 'helper:status').length], [1, 1]);
  world.calls = [];
  await press(row(tree, 'Keep Awake'), '2h');
  assert.deepEqual(world.calls, ['amphetamine:start', 'apps', 'amphetamine:status']);
  assert.deepEqual(failures(), []);
});

test('Opening a disabled command names the command to turn on', async () => {
  reset({ disabled: ['blocked-sites', 'unlock-request'] });
  const tree = await mount('focus-status');
  await press(menuItem(tree, 'Blocked Sites…'), 'Blocked Sites…');
  assert.deepEqual([world.launched, world.toasts.at(-1).title], [[], 'Enable “Blocked Sites”']);
  helper('add', 'a.com', 'manual');
  const menu = await mount('focus-status');
  const submenu = one(menu, 'MenuBarExtra.Submenu', (props) => props.title === 'Unblock Site (1)');
  await press(submenu.findAll((node) => node.type === 'MenuBarExtra.Item')[0], 'a.com');
  assert.equal(world.toasts.at(-1).title, 'Enable “Review Unblock Request”');
  // The names in those toasts are the manifest titles.
  const { COMMAND_TITLES } = require(path.join(project, 'src/launch.ts'));
  const manifest = JSON.parse(fs.readFileSync(path.join(project, 'package.json'), 'utf8'));
  for (const [name, title] of Object.entries(COMMAND_TITLES)) assert.equal(manifest.commands.find((each) => each.name === name)?.title, title, name);
});

test('Setup instructions open Terminal with the command copied and check again', async () => {
  reset({ setup: false });
  const tree = await mount('run-setup');
  const detail = () => one(tree, 'Detail');
  assert.deepEqual(actionTitles(detail()), ['Copy Command and Open Terminal', 'Check Again', 'Copy Setup Command', 'Paste Setup Command']);
  await press(detail(), 'Copy Command and Open Terminal');
  assert.match(world.clipboard, /^sudo \/bin\/bash '.*assets\/setup\.sh'$/);
  assert.deepEqual([world.opened.at(-1), world.huds.at(-1)], ['/System/Applications/Utilities/Terminal.app', 'Setup command copied. Paste it into Terminal.']);
  await press(detail(), 'Check Again');
  assert.equal(world.toasts.at(-1).title, 'Setup is not complete yet');
  world.setup = true;
  await press(detail(), 'Check Again');
  assert.equal(world.toasts.at(-1).title, 'Setup is complete');
  // The command that showed the instructions reloads into its own view.
  assert.ok(row(tree, 'Setup complete'));
  // Opened without a request, Review Unblock Request lists the blocked sites instead of a dead end.
  helper('add', 'a.com', 'manual');
  const review = await mount('unlock-request', {});
  assert.deepEqual(all(review, 'List.Item').map((item) => item.props.title), ['a.com']);
});

test('Run Setup shows the helper version and repairs damaged Pomodoro state', async () => {
  reset({ fakeHelper: { status: JSON.stringify({ version: 4, session: null, pomodoro: null, entries: [{ domain: 'a.com', tag: 'manual' }], stateDamaged: true }), 'repair-state': '{"repaired":true}' } });
  const tree = await mount('run-setup');
  assert.deepEqual(tags(row(tree, 'Setup complete')), ['helper v4']);
  await press(row(tree, 'Pomodoro state needs repair'), 'Repair Pomodoro State');
  assert.deepEqual([world.toasts.at(-1).title, world.calls.filter((call) => call === 'helper:repair-state').length], ['Pomodoro state repaired', 1]);
  // The dashboard points there too.
  const dashboard = await mount('dashboard');
  assert.deepEqual([tags(row(dashboard, 'Pomodoro')), actionTitles(row(dashboard, 'Pomodoro'))[0]], [['Needs Repair'], 'Repair in Run Setup']);
  await press(row(dashboard, 'Pomodoro'), 'Repair in Run Setup');
  assert.equal(world.pushed.at(-1).element.type, require(path.join(project, 'src/run-setup.tsx')).default);
});

test('A site unblock covers its www twin, and a preset unblock lifts the finished Pomodoro block too', async () => {
  reset();
  // Social sites blocked by the preset and by a finished Pomodoro round, which keeps its own tag; one manual block.
  helper('add-many', 'social', 'x.com', 'www.x.com', 'reddit.com', 'www.reddit.com');
  helper('add', 'reddit.com', 'manual');
  helper('start-pomodoro', '1', '1', '1', '4', 'Pomodoro', 'x.com', 'www.x.com', 'reddit.com', 'www.reddit.com');
  helper('pomodoro-checkpoint', 'ui-monitor');
  for (let step = 0; step < 6; step++) { advanceClock(10000); helper('pomodoro-checkpoint', 'ui-monitor'); }
  advanceClock(60001); helper('pomodoro-status');
  assert.equal(helper('list'), 'reddit.com\tmanual,pomodoro,social\nwww.reddit.com\tpomodoro,social\nwww.x.com\tpomodoro,social\nx.com\tpomodoro,social\n');

  // Unblocking x.com reviews both hostnames together; removing only x.com left www.x.com blocked.
  let tree = await mount('blocked-sites');
  await press(row(tree, 'x.com'), 'Review Unblock…');
  assert.deepEqual(world.pushed.at(-1).element.props.operations, [['remove', 'x.com'], ['remove', 'www.x.com']]);
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'reddit.com\tmanual,pomodoro,social\nwww.reddit.com\tpomodoro,social\n');
  assert.match(world.huds.at(-1), /^🔓 Unblocked · reload the page/);

  // Unblock Social also removes the Pomodoro tag from those sites; the manual block stays and is named.
  tree = await mount('block-preset');
  await press(row(tree, 'Social'), 'Unblock Social');
  assert.deepEqual(world.pushed.at(-1).element.props.operations, [
    ['remove-all-with-tag', 'social'], ['remove-tag', 'reddit.com', 'pomodoro'], ['remove-tag', 'www.reddit.com', 'pomodoro'],
  ]);
  await finishReview(world.pushed.at(-1).element);
  assert.equal(helper('list'), 'reddit.com\tmanual\n');
  assert.equal(world.huds.at(-1), '🔓 Unblocked · reddit.com stays blocked by manual');

  // The menu bar lists each site once and unblocks both hostnames.
  helper('add-many', 'video', 'youtube.com', 'www.youtube.com');
  tree = await mount('focus-status');
  assert.equal(menuTitles(tree).filter((title) => /youtube\.com$/.test(title)).length, 1);
  assert.deepEqual(failures(), []);
});
