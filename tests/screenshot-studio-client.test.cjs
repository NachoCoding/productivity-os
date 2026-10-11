const { test } = require('node:test');
const assert = require('node:assert/strict');
const { clientSuite, harness } = require('./native-launcher.test.cjs');

const studio = {
  file: 'screenshot-studio-client.ts', name: 'Screenshot Studio', bundleId: 'com.productivity-os.screenshot-studio', scheme: 'pos-screenshot',
  setup: 'setup-screenshot-studio.sh', launch: 'launchScreenshot', action: 'screenshotAction', list: 'screenshotCommands', app: 'studioApp',
  sample: 'area', background: [],
};
clientSuite(studio);

test('Screenshot Studio exposes its capture commands (quit-if-idle is for the installer only)', () => {
  assert.deepEqual(Array.from(harness(studio.file).screenshotCommands), ['capture', 'area', 'window', 'display', 'repeat', 'delay', 'scroll', 'text', 'record', 'open', 'clipboard', 'settings', 'unlock-pins']);
});
