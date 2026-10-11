const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
const vm = require('node:vm');
const exported = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/lib.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, { exports: exported, require, URL });
test('URL normalization and domain validation', () => {
  for (const [input, expected] of [[' HTTPS://Example.COM:443/path?q=1 ', 'example.com'], ['example.com.', 'example.com'], ['www.example.com/path', 'www.example.com'], ['https://user:pass@example.com', ''], ['bad domain', ''], ['münchen.de', 'xn--mnchen-3ya.de'], ['ftp://example.com', ''], ['', '']]) {
    assert.equal(exported.normalizeDomain(input), expected);
  }
  for (const input of ['-bad.com', 'localhost', 'a..com', '127.0.0.1', '[::1]', 'Example.com', `${'a'.repeat(64)}.com`, `${('a'.repeat(60)+'.').repeat(5)}com`]) assert.equal(exported.domainRegex.test(input), false);
  for (const input of ['127.0.0.1', 'http://[::1]/', 'localhost']) assert.equal(exported.domainRegex.test(exported.normalizeDomain(input)), false);
  assert.equal(exported.domainRegex.test('good-domain.example.com'), true);
});
test('manual blocks cover the bare domain and its www variant', () => {
  for (const [input, expected] of [
    ['linkedin.com', ['linkedin.com', 'www.linkedin.com']],
    ['www.linkedin.com', ['linkedin.com', 'www.linkedin.com']],
    ['news.ycombinator.com', ['news.ycombinator.com', 'www.news.ycombinator.com']],
    ['www.www.example.com', ['www.example.com', 'www.www.example.com']],
    // "com" alone is not a hostname, so only the typed name is blocked.
    ['www.com', ['www.com']],
    // A 253-character name has no room for a www prefix.
    [`${('a'.repeat(61)+'.').repeat(4)}abcde`, [`${('a'.repeat(61)+'.').repeat(4)}abcde`]],
  ]) {
    // Spread: arrays from the vm context have a different Array prototype than the test’s.
    assert.deepEqual([...exported.hostVariants(input)], expected, input);
    for (const name of exported.hostVariants(input)) assert.equal(exported.domainRegex.test(name), true, name);
  }
});
test('countdown rounding and expiry', () => {
  for (const [ms, expected] of [[-1, '0m'], [1, '1m'], [60000, '1m'], [3600000, '1h'], [3600001, '1h 1m'], [86400000, '24h']]) assert.equal(exported.formatRemaining(ms), expected);
});

const diagnostics = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/diagnostics.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, { exports: diagnostics, require });
test('diagnostics never report a mixed public/loopback result as blocked', () => {
  assert.equal(diagnostics.addressesAreBlocked(['127.0.0.1', '::1']), true);
  assert.equal(diagnostics.addressesAreBlocked(['127.0.0.1', '142.250.1.1']), false);
  assert.equal(diagnostics.addressesAreBlocked(['2607:f8b0::1']), false);
  assert.equal(diagnostics.addressesAreBlocked([]), false);
});

test('JS domain regex stays in sync with the helper', () => {
  const helper = fs.readFileSync('assets/blocker.sh', 'utf8');
  const perl = helper.match(/\$d =~ \/\\A(.+?)\\z\//);
  assert.ok(perl, 'could not find the Perl domain regex in assets/blocker.sh');
  const js = exported.domainRegex.source.replace(/^\^\(\?=\.\{1,253\}\$\)/, '^').replace(/^\^/, '').replace(/\$$/, '');
  assert.equal(perl[1].replace(/\(\?:/g, '('), js);
  const perlRegex = new RegExp(`^${perl[1].replace(/\(\?:/g, '(')}$`);
  for (const input of ['-bad.com', 'localhost', 'a..com', `${'a'.repeat(64)}.com`, 'good-domain.example.com', 'a.b.c.io', 'x.c']) {
    assert.equal(perlRegex.test(input), exported.domainRegex.test(input), input);
  }
});

const amphetamine = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/amphetamine-time.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, { exports: amphetamine, require, Date });
test('Amphetamine durations parse and format', () => {
  for (const [input, expected] of [[undefined, 0], ['', 0], [' 90 ', 90], ['007', 7], ['1.5', null], ['-1', null], ['abc', null]]) assert.equal(amphetamine.parseWholeNumber(input), expected);
  for (const [seconds, expected] of [[0, '00:00min'], [59, '00:59min'], [61.9, '01:01min'], [3599, '59:59min'], [3600, '01:00h'], [90061, '25:01h'], [-5, '00:00min']]) assert.equal(amphetamine.formatRemainingSeconds(seconds), expected);
  for (const [minutes, expected] of [[0, '0m'], [45, '45m'], [60, '1h'], [90, '1h 30m'], [1440, '1d'], [1505, '1d 1h 5m'], [10080, '7d']]) assert.equal(amphetamine.formatShortDuration(minutes), expected);
  for (const [minutes, expected] of [[0, 'less than a minute'], [1, '1 minute'], [60, '1 hour'], [61, '1 hour and 1 minute'], [1505, '1 day, 1 hour, and 5 minutes'], [10080, '1 week'], [20222, '2 weeks, 1 hour, and 2 minutes']]) assert.equal(amphetamine.formatDurationBreakdown(minutes), expected);
  const now = new Date('2026-01-01T10:00:00Z');
  assert.equal(amphetamine.minutesUntil(new Date('2026-01-01T10:00:01Z'), now), 1);
  assert.equal(amphetamine.minutesUntil(new Date('2026-01-01T11:30:00Z'), now), 90);
  assert.equal(amphetamine.minutesUntil(now, now), undefined);
  assert.equal(amphetamine.minutesUntil(new Date('2026-01-01T09:00:00Z'), now), undefined);
});

test('manifest stays in sync with presets, icons and entry points', () => {
  const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const presets = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/presets.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText, { exports: presets, require: (name) => require(require("node:path").resolve("src", name)) });
  const quickFocus = manifest.commands.find((command) => command.name === 'quick-focus');
  assert.deepEqual(quickFocus.arguments[0].data.map((item) => item.value), [...presets.presets.map((preset) => preset.name), 'custom']);
  assert.deepEqual(quickFocus.arguments[0].data.slice(0, -1).map((item) => item.title), [...presets.presets.map((preset) => preset.title)]);
  for (const command of manifest.commands) {
    assert.ok(fs.existsSync(`assets/${command.icon}`), `missing icon for ${command.name}`);
    assert.ok(fs.existsSync(`src/${command.name}.ts`) || fs.existsSync(`src/${command.name}.tsx`), `missing entry point for ${command.name}`);
  }
  assert.ok(fs.existsSync(`assets/${manifest.icon}`));
  assert.ok(fs.existsSync('assets/menubar-divider'), 'run npm run build:helper');
});
test('focus minutes are whole numbers from 1 to 1440', () => {
  for (const [input, expected] of [['30', 30], [' 1 ', 1], ['1440', 1440], ['0', undefined], ['1441', undefined], ['1.5', undefined], ['-5', undefined], ['', undefined], ['abc', undefined]]) assert.equal(exported.parseFocusMinutes(input), expected, input);
});

// Objects made inside the VM have their own prototypes; JSON round-trips make them comparable.
const plain = (value) => JSON.parse(JSON.stringify(value));
const round = (extra = {}) => ({ phase: 'focus', paused: false, remainingMs: 60000, endsAt: 1060000, focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, roundsPerSet: 4, completedRounds: 0, label: 'Deep', domains: ['a.com'], ...extra });

test('status replies are validated, and numbers Perl printed as strings still count', () => {
  const status = exported.parseStatus(JSON.stringify({ version: 4, session: { endsAt: '1700000000000', label: 'Deep' }, pomodoro: round({ paused: true, pauseReason: 'monitor', endsAt: null, remainingMs: '1500000', stalled: true }), entries: [{ domain: 'a.com', tag: 'manual,pomodoro' }], stateDamaged: false }));
  assert.deepEqual(plain(status), { version: '4', session: { endsAt: 1700000000000, label: 'Deep' }, pomodoro: round({ paused: true, pauseReason: 'monitor', endsAt: null, remainingMs: 1500000, stalled: true }), entries: [{ domain: 'a.com', tag: 'manual,pomodoro' }], stateDamaged: false });
  // Helper v4 adds `stalled`; a reply without it (or a damaged-state reply) reads as not stalled / healthy.
  assert.deepEqual(plain(exported.parseStatus('{"version":4,"session":null,"pomodoro":null,"entries":[],"stateDamaged":true}')), { version: '4', session: null, pomodoro: null, entries: [], stateDamaged: true });
  for (const bad of ['', 'null', '{}', '[]', '{"version":4,"entries":[{"domain":1,"tag":"x"}]}', '{"version":4,"entries":[],"session":{"endsAt":-1,"label":"x"}}', '{"version":4,"entries":[],"session":{"endsAt":"soon","label":"x"}}', JSON.stringify({ version: 4, entries: [], pomodoro: round({ phase: 'nap' }) }), JSON.stringify({ version: 4, entries: [], pomodoro: round({ domains: 'a.com' }) })]) {
    assert.throws(() => exported.parseStatus(bad), /unexpected response/, bad);
  }
  assert.throws(() => exported.parseStatus('{"version":9,"entries":[]}'), (error) => error.code === 'SETUP_REQUIRED' && /not supported/.test(error.message));
});

test('helper failures are classified: sudo asking for a password means setup is needed', () => {
  const failure = (stderr) => exported.helperError({ code: 1, stdout: '', stderr }, 'fallback');
  assert.equal(exported.needsSetup(failure('sudo: a password is required\n')), true);
  assert.equal(exported.needsSetup(failure('sudo: /Library/PrivilegedHelperTools/productivity-os/blocker.sh: command not found')), true);
  const locked = failure('{"code":"FOCUS_LOCKED","message":"Finish the current focus round before changing website protection."}');
  assert.deepEqual([locked.code, locked.message, exported.needsSetup(locked)], ['FOCUS_LOCKED', 'Finish the current focus round before changing website protection.', false]);
  assert.equal(failure('').message, 'fallback');
  for (const [error, text] of [[new Error('boom'), 'boom'], ['Error: plain', 'plain'], [{ message: 'shaped' }, 'shaped'], [undefined, 'undefined']]) assert.equal(exported.errorMessage(error), text);
});

test('focus locks follow the helper: sessions until they end, running rounds until theirs, paused rounds open-ended', () => {
  const now = 1000000;
  const lock = (status) => { const value = exported.focusLock({ session: null, pomodoro: null, ...status }, now); return value && plain(value); };
  assert.equal(lock({}), undefined);
  assert.equal(lock({ session: { endsAt: now, label: 'x' } }), undefined);
  assert.deepEqual(lock({ session: { endsAt: now + 5000, label: 'x' } }), { until: now + 5000 });
  assert.deepEqual(lock({ session: { endsAt: now + 5000, label: 'x' }, pomodoro: round() }), { until: 1060000 });
  assert.deepEqual(lock({ session: { endsAt: now + 90000, label: 'x' }, pomodoro: round() }), { until: now + 90000 });
  assert.deepEqual(lock({ pomodoro: round({ paused: true, endsAt: null }) }), { until: null });
  // A running round whose end has passed is locked until the helper credits it; its end is unknown.
  assert.deepEqual(lock({ pomodoro: round({ endsAt: now - 1 }) }), { until: null });
  for (const phase of ['shortBreak', 'longBreak', 'ready']) assert.equal(lock({ pomodoro: round({ phase }) }), undefined, phase);
  assert.equal(exported.describeLock({ until: null }), 'Locked during focus');
  assert.match(exported.describeLock({ until: now }), /^Locked until \S/);
  // start-focus is also refused while any Pomodoro plan exists.
  assert.equal(exported.canStartFocus({ session: null, pomodoro: null, entries: [] }), true);
  assert.equal(exported.canStartFocus({ session: null, pomodoro: round({ phase: 'ready', remainingMs: 0, endsAt: null }), entries: [] }), false);
});

test('cached status follows confirmed changes the way the helper applies them', () => {
  const status = { version: '4', session: { endsAt: 5, label: 'x' }, pomodoro: round({ phase: 'ready' }), entries: [{ domain: 'a.com', tag: 'focus,manual' }, { domain: 'b.com', tag: 'social' }], stateDamaged: false };
  assert.deepEqual(plain(exported.withBlocks(status, ['c.com', 'a.com'], 'news')).entries, [{ domain: 'a.com', tag: 'focus,manual,news' }, { domain: 'b.com', tag: 'social' }, { domain: 'c.com', tag: 'news' }]);
  assert.deepEqual(plain(exported.withoutBlocks(status, [['end-focus']])), { ...status, session: null, entries: [{ domain: 'a.com', tag: 'manual' }, { domain: 'b.com', tag: 'social' }] });
  assert.deepEqual(plain(exported.withoutBlocks(status, [['remove-all-with-tag', 'social'], ['remove-tag', 'a.com', 'manual']])).entries, [{ domain: 'a.com', tag: 'focus' }]);
  assert.deepEqual(plain(exported.withoutBlocks(status, [['remove', 'a.com']])).entries, [{ domain: 'b.com', tag: 'social' }]);
  assert.deepEqual(plain(exported.withoutBlocks(status, [['remove-everything']])), { ...status, session: null, entries: [] });
  // Ending a stalled round drops the plan and keeps every site block.
  assert.deepEqual(plain(exported.withoutBlocks(status, [['end-pomodoro']])), { ...status, pomodoro: null });
  // start-focus replaces the focus blocks with the new session's.
  assert.deepEqual(plain(exported.withFocusSession(status, { endsAt: 9, label: 'y' }, ['b.com'])), { ...status, session: { endsAt: 9, label: 'y' }, entries: [{ domain: 'a.com', tag: 'manual' }, { domain: 'b.com', tag: 'focus,social' }] });
});

test('a stalled round is only ever ended in a review of its own', async () => {
  await assert.rejects(exported.requestUnblock([['end-pomodoro'], ['end-focus']]), /own/);
  await assert.rejects(exported.requestUnblock([]), /Choose/);
});

test('Pomodoro descriptions count down from the end time and say when a round stalled', () => {
  // The VM has its own clock, so end times are set relative to the real one.
  assert.equal(exported.describePomodoro(null), '25-minute focus · 5-minute breaks');
  assert.equal(exported.describePomodoro(round({ endsAt: Date.now() + 60000, remainingMs: 999999 })), 'Focus · 1m left');
  assert.equal(exported.describePomodoro(round({ paused: true, endsAt: null, remainingMs: 1500000 })), 'Focus paused · 25m left');
  assert.equal(exported.describePomodoro(round({ paused: true, endsAt: null, remainingMs: 1500000, stalled: true })), 'Focus stalled · 25m left');
  assert.equal(exported.describePomodoro(round({ phase: 'longBreak', endsAt: Date.now() + 120000 })), 'Long break · 2m left');
  assert.equal(exported.describePomodoro(round({ phase: 'ready', endsAt: null })), 'Ready for the next round');
});

test('manifest titles and descriptions say what each command does', () => {
  const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const byName = Object.fromEntries(manifest.commands.map((command) => [command.name, command]));
  assert.equal(manifest.commands.length, 36);
  assert.equal(byName['health-breaks'].title, 'Health Break Settings');
  assert.notEqual(byName['focus-status'].title, 'Focus Status');
  // Posture coaching is its own command; Pomodoro does not claim it.
  for (const name of ['pomodoro', 'start-pomodoro']) assert.ok(!/posture|camera/i.test([byName[name].description, ...(byName[name].keywords ?? [])].join(' ')), name);
  // The Pomodoro commands no longer wear the menu bar's or each other's icon.
  assert.equal(new Set(['pomodoro', 'start-pomodoro', 'focus-status'].map((name) => byName[name].icon)).size, 3);
  const screenshots = manifest.commands.filter((command) => command.name.startsWith('capture-') || command.name === 'screenshot-studio');
  assert.equal(new Set(screenshots.map((command) => command.description)).size, screenshots.length);
  // Every keep-awake start states the shared rule.
  for (const name of ['amphetamine-quick-start', 'amphetamine-configure', 'lock-keep-awake']) assert.match(byName[name].description, /no time limit[\s\S]*replaces a running session/, name);
  // Start Keep Awake takes no duration: Amphetamine's default session, and a running session is left alone.
  assert.match(byName['amphetamine-start'].description, /Amphetamine's default[\s\S]*leaves a running session alone/);
});
