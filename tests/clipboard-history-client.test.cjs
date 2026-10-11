const { test } = require('node:test');
const assert = require('node:assert/strict');
const { clientSuite, harness } = require('./native-launcher.test.cjs');

const clipboard = {
  file: 'clipboard-history-client.ts', name: 'Clipboard History', bundleId: 'com.productivity-os.clipboard-history', scheme: 'pos-clipboard',
  setup: 'setup-clipboard-history.sh', launch: 'launchClipboard', action: 'clipboardAction', list: 'clipboardCommands', app: 'clipboardApp',
  sample: 'history', background: [],
};
clientSuite(clipboard);

test('Clipboard History exposes exactly its two commands', () => {
  assert.deepEqual(Array.from(harness(clipboard.file).clipboardCommands), ['history', 'settings']);
});
