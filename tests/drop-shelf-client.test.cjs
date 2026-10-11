const { test } = require('node:test');
const assert = require('node:assert/strict');
const { clientSuite, harness } = require('./native-launcher.test.cjs');

const shelf = {
  file: 'drop-shelf-client.ts', name: 'Drop Shelf', bundleId: 'com.productivity-os.drop-shelf', scheme: 'pos-shelf',
  setup: 'setup-drop-shelf.sh', launch: 'launchShelf', action: 'shelfAction', list: 'shelfCommands', app: 'shelfApp',
  sample: 'new', background: [],
};
clientSuite(shelf);

test('Drop Shelf exposes exactly its three commands (quit-if-idle is for the installer only)', () => {
  assert.deepEqual(Array.from(harness(shelf.file).shelfCommands), ['new', 'clipboard', 'settings']);
});
