// manifest.json v2.1 permission-profile tests (issue #30 AC): core permission
// set exact + sorted, second tier in optional_permissions only, forbidden
// permissions absent everywhere, commands/omnibox wired, anchor keys intact.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const manifest = JSON.parse(readFileSync(join(here, '..', 'manifest.json'), 'utf8'));

const CORE = [
  'alarms', 'bookmarks', 'contextMenus', 'cookies', 'debugger',
  'downloads', 'history', 'identity', 'idle', 'notifications', 'offscreen',
  'power', 'scripting', 'sessions', 'sidePanel', 'storage',
  'system.cpu', 'system.display', 'system.memory', 'system.storage',
  'tabGroups', 'tabs', 'webNavigation',
];
const OPTIONAL = [
  'declarativeNetRequest', 'desktopCapture', 'pageCapture', 'readingList',
  'search', 'tabCapture', 'topSites', 'tts', 'userScripts',
];
const FORBIDDEN = ['browsingData', 'privacy', 'proxy', 'management', 'gcm', 'devtools', 'passwords'];

test('permissions are exactly the core set, each once, sorted', () => {
  assert.deepEqual(manifest.permissions, CORE);
  assert.deepEqual([...manifest.permissions].sort(), manifest.permissions, 'permissions not sorted');
  assert.equal(new Set(manifest.permissions).size, manifest.permissions.length, 'duplicate permission');
});

test('optional_permissions are exactly the second tier, sorted, disjoint from permissions', () => {
  assert.deepEqual(manifest.optional_permissions, OPTIONAL);
  assert.deepEqual([...manifest.optional_permissions].sort(), manifest.optional_permissions, 'optional_permissions not sorted');
  assert.equal(manifest.permissions.filter((p) => manifest.optional_permissions.includes(p)).length, 0, 'tier overlap');
});

test('forbidden permissions appear in neither list nor host_permissions', () => {
  const everywhere = [...manifest.permissions, ...manifest.optional_permissions, ...manifest.host_permissions];
  for (const bad of FORBIDDEN) {
    assert.equal(everywhere.includes(bad), false, `forbidden permission present: ${bad}`);
  }
});

test('host_permissions stay <all_urls>, optional_host_permissions added', () => {
  assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  assert.deepEqual(manifest.optional_host_permissions, ['<all_urls>']);
});

test('commands registers ask-fa with a suggested_key', () => {
  // commands is a name→spec OBJECT in the manifest (an array is a manifest
  // parse error: "Invalid value for 'commands'" — the extension then never
  // loads and no service worker registers).
  const cmd = manifest.commands['ask-fa'];
  assert.ok(cmd, 'ask-fa command missing');
  assert.equal(cmd.description, 'Ask fa about the current page');
  assert.match(cmd.suggested_key.default, /^(Ctrl|Command|Alt|MacCtrl)\+/);
});

test('omnibox keyword is fa', () => {
  assert.equal(manifest.omnibox.keyword, 'fa');
});

test('v1 anchors intact: side_panel, background, mv3, chrome floor, identity fields', () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.side_panel.default_path, 'panel/panel.html');
  assert.equal(manifest.background.service_worker, 'sw/main.js');
  assert.equal(manifest.minimum_chrome_version, '116');
  assert.ok(manifest.key, 'key missing');
  assert.equal(manifest.name, 'fa — browser agent');
  assert.deepEqual(manifest.icons['16'], 'icons/icon-16.png');
  assert.deepEqual(manifest.action.default_icon, 'icons/icon-32.png');
  assert.equal(manifest.content_scripts[0].js[0], 'content/content.js');
});

test('version bumped to 0.2.0 and description is the v2.1 product line', () => {
  assert.equal(manifest.version, '0.2.0');
  assert.equal(
    manifest.description,
    'fa — your agent in this browser: the full fa app in the side panel, page powers for the agent.',
  );
});
