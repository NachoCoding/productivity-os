const { test } = require('node:test');
const assert = require('node:assert/strict');
const { clientSuite, harness } = require('./native-launcher.test.cjs');

const health = {
  file: 'health-breaks-client.ts', name: 'Health Breaks', bundleId: 'com.productivity-os.health-breaks', scheme: 'pos-health',
  setup: 'setup-health-breaks.sh', launch: 'launchHealth', action: 'healthAction', list: 'healthCommands', app: 'healthApp',
  sample: 'settings', background: ['pomodoro-start', 'break', 'preview'],
};
clientSuite(health);

test('Health Breaks keeps every command, including Pomodoro Settings', () => {
  assert.deepEqual(Array.from(harness(health.file).healthCommands), ['settings', 'break', 'preview', 'pomodoro', 'pomodoro-start', 'pomodoro-settings', 'posture']);
});

test('Health Breaks: Start Pomodoro stays silent (open -g) even right after an update', async () => {
  const h = harness(health.file, { installed: { id: 'B1', exe: 'exe-1', presets: 'presets-1' }, loaded: true });
  await h.launchHealth('pomodoro-start');
  assert.deepEqual(h.commands()[0], ['/bin/bash', '/bundle/assets/setup-health-breaks.sh', 'update']);
  assert.deepEqual(h.commands().at(-1), ['/usr/bin/open', '-g', '-a', '/user/Applications/Health Breaks.app', 'pos-health://pomodoro-start']);
});

test('Health Breaks: an unstamped install is updated when only the bundled Pomodoro presets changed', async () => {
  const legacy = { id: undefined, exe: 'exe-1', presets: 'presets-1' };
  const h = harness(health.file, { bundled: legacy, installed: { ...legacy, presets: 'presets-0' }, running: true });
  await h.launchHealth('pomodoro');
  assert.deepEqual(h.commands()[0], ['/bin/bash', '/bundle/assets/setup-health-breaks.sh', 'update']);
  assert.deepEqual(h.commands().at(-1), ['/usr/bin/open', '-a', '/user/Applications/Health Breaks.app', 'pos-health://pomodoro']);
});
