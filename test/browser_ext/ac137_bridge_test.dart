// Issue #137 acceptance — the generic chrome.* bridge against a REAL
// headless Chrome (the fake-chrome VM suite in browser_ext/dart/test
// covers the unit/fake tier; this file pins the browser-side truth):
//
//   AC1: the manifest declares every Tier-1/2 permission from the issue
//        and Chrome loads it without permission/manifest warnings.
//   AC2: the runtime catalog equals the manifest-granted namespaces —
//        reflection ⊆ declared ∧ declared ⊆ reflection (for permissions
//        that own a chrome.* namespace), plus the namespace detail shape
//        (methods with arity, events).
//   AC3: a read-path call with NO curated tool (chrome.idle.queryState)
//        succeeds end-to-end through the SW bridge.
//   AC6/E7: a trimmed-manifest build (no `history`) hides the namespace
//        from the catalog and turns calls into structured api_missing
//        data errors — never a throw, the sibling namespace still works.
//
// The seams (faAgentV2.bridgeCatalog/bridgeCall, agent_main.dart) are the
// RAW bridge — the agent-facing tiers/gates/hygiene ride the
// browser_api/browser_api_catalog tools and are pinned by the e2e spec
// (browser_ext/e2e/bridge.spec.ts) plus the VM suite.
//
// Requires a REAL Chrome and a prior `bash scripts/build_browser_ext.sh`
// (sw/agent.js is a build artifact). No Chrome → loud ChromeLaunchException;
// the `integration`+`browser-ext` tags keep this out of default runs.
@Tags(['integration', 'browser-ext'])
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'chrome_driver.dart';

/// The compiled embedded agent is a build artifact (gitignored).
void _requireBuiltAgent() {
  final agentJs = File('browser_ext/sw/agent.js');
  if (!agentJs.existsSync()) {
    fail(
      'browser_ext/sw/agent.js is missing — run '
      '`bash scripts/build_browser_ext.sh` first',
    );
  }
}

/// Manifest permissions as a set (comments stripped — jsonDecode is not
/// lenient, Chrome's parser is).
Set<String> _manifestPermissions([String? extensionPath]) {
  final source = File(
    '${extensionPath ?? _repoRoot()}/browser_ext/manifest.json',
  ).readAsStringSync();
  final json = source.replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
  final manifest = jsonDecode(json) as Map<String, dynamic>;
  return {
    for (final p in manifest['permissions'] as List) p as String,
  };
}

String _repoRoot() {
  var dir = Directory.current.resolveSymbolicLinksSync();
  for (var i = 0; i < 6; i++) {
    if (Directory('$dir/browser_ext').existsSync()) return dir;
    dir = '$dir/..';
  }
  throw StateError('repo root with browser_ext/ not found');
}

// -- the AC2 permission⇄namespace vocabulary ---------------------------------

/// MV3 namespaces materialized without any permission entry (manifest
/// keys or always-present surfaces). Reflection roots outside the declared
/// permissions may only come from here.
const Set<String> _alwaysPresentNamespaces = {
  'runtime', // always present; bridge-DENIED for calls (self-preservation)
  'i18n',
  'extension', // legacy shell, always materialized
  'action', // manifest `action` key, not a permission
  'commands', // manifest `commands` key
  'omnibox', // manifest `omnibox` key
};

/// Declared permissions that enable no `chrome.<root>` namespace of their
/// own (capability flags or sub-namespace transports).
const Set<String> _permissionsWithoutNamespace = {
  'unlimitedStorage', // quota lift only
  'clipboardRead', // navigator.clipboard + content scripts
  'clipboardWrite',
  'nativeMessaging', // rides chrome.runtime.sendNativeMessage
};

/// The catalog root a declared permission must surface as, or null when
/// the permission owns no namespace.
String? _rootOf(String permission) => switch (permission) {
  'system.cpu' ||
  'system.memory' ||
  'system.display' ||
  'system.storage' => 'system',
  _ => _permissionsWithoutNamespace.contains(permission)
      ? null
      : permission,
};

// -- bridge seams -------------------------------------------------------------

/// `faAgentV2.bridgeCatalog([ns])` → the raw envelope.
Future<Map<String, dynamic>> bridgeCatalog(
  HeadlessChrome chrome, [
  String? ns,
]) async => (await evaluateInServiceWorker(
    chrome,
    ns == null
        ? 'globalThis.faAgentV2.bridgeCatalog()'
        : 'globalThis.faAgentV2.bridgeCatalog(${jsonEncode(ns)})',
    awaitPromise: true,
  ))! as Map<String, dynamic>;

/// `faAgentV2.bridgeCall(path, args)` → the raw envelope.
Future<Map<String, dynamic>> bridgeCall(
  HeadlessChrome chrome,
  String path,
  List<Object?> args,
) async => (await evaluateInServiceWorker(
    chrome,
    'globalThis.faAgentV2.bridgeCall(${jsonEncode(path)}, '
    '${jsonEncode(args)})',
    awaitPromise: true,
  ))! as Map<String, dynamic>;

HeadlessChrome? _chrome;

/// Non-null once setUpAll succeeded; tests only run after that.
HeadlessChrome get chrome => _chrome!;

void main() {
  setUpAll(() async {
    _requireBuiltAgent();
    _chrome = await HeadlessChrome.launch();
  });

  tearDownAll(() => _chrome?.dispose());

  test('AC1: manifest declares every Tier-1/2 permission', () {
    final declared = _manifestPermissions();
    // Tier 1 (issue #137): `commands` and `omnibox` are manifest KEYS, not
    // permission entries — checked as JSON keys below.
    const tier1 = {
      'browsingData', 'clipboardRead', 'clipboardWrite', 'contentSettings',
      'declarativeNetRequest', 'fontSettings', 'privacy', 'readingList',
      'search', 'tabGroups', 'tts', 'webRequest',
    };
    const tier2 = {'nativeMessaging', 'proxy', 'tabCapture', 'management'};
    expect(declared.containsAll(tier1), isTrue,
        reason: 'missing Tier-1: ${tier1.difference(declared)}');
    expect(declared.containsAll(tier2), isTrue,
        reason: 'missing Tier-2: ${tier2.difference(declared)}');
    final manifest = jsonDecode(
      File('browser_ext/manifest.json')
          .readAsStringSync()
          .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), ''),
    ) as Map<String, dynamic>;
    expect(manifest.containsKey('commands'), isTrue);
    expect(manifest.containsKey('omnibox'), isTrue);
  });

  test('AC1: Chrome loads the maximized manifest without warnings', () {
    // Unrecognized permissions / manifest keys print on stderr at load —
    // a clean load is silent about them (boot itself is pinned by
    // ac_load_and_agent_test: SW target + no console errors).
    expect(
      RegExp(
        r"permission '.*' is unknown|unrecognized manifest key",
        caseSensitive: false,
      ).hasMatch(chrome.capturedStderr),
      isFalse,
      reason: 'Chrome warned about the manifest:\n${chrome.capturedStderr}',
    );
  });

  test('AC2: catalog equals the manifest-granted namespaces (both ways)',
      () async {
    final catalog = (await bridgeCatalog(chrome))['namespaces'] as List;
    final roots = {for (final n in catalog) n as String};
    final declared = _manifestPermissions();

    // reflection ⊆ declared (modulo the always-present surfaces)
    final undeclared = roots
        .difference(declared)
        .difference(_alwaysPresentNamespaces);
    expect(undeclared, isEmpty,
        reason: 'catalog advertises undeclared namespaces: $undeclared');

    // declared ⊆ reflection (for permissions that own a namespace)
    final missing = [
      for (final p in declared)
        if (_rootOf(p) != null && !roots.contains(_rootOf(p))) p,
    ];
    expect(missing, isEmpty,
        reason: 'declared permissions absent from the catalog: $missing');
  });

  test('AC2: a namespace query lists methods + arity + events', () async {
    final detail = await bridgeCatalog(chrome, 'tabs');
    expect(detail['ok'], isTrue);
    final methods = (detail['methods'] as Map).cast<String, dynamic>();
    expect(methods.containsKey('query'), isTrue);
    expect(methods.containsKey('update'), isTrue);
    expect(methods['query'], isA<int>()); // arity (fn.length)
    expect((detail['events'] as List), contains('onUpdated'));
  });

  test('AC3: read path end-to-end — chrome.idle.queryState (no curated tool)',
      () async {
    final envelope = await bridgeCall(chrome, 'idle.queryState', [60]);
    expect(envelope['ok'], isTrue,
        reason: 'bridge call failed: ${envelope['error']}');
    final result = envelope['result'] as Map<String, dynamic>;
    expect(result.containsKey('state'), isTrue);
  });

  test('AC6: a bad method path is a structured error, never a throw',
      () async {
    final envelope = await bridgeCall(chrome, 'tabs.definitelyNotAMethod', []);
    expect(envelope['ok'], isFalse);
    expect((envelope['error'] as Map)['code'], 'api_missing');
  });

  // E7/AC6: the trimmed-manifest build — MV3 hides ungranted namespaces,
  // so the catalog cannot advertise them and calls error as data.
  group('trimmed manifest (E7)', () {
    final trimmedRoot = Directory.systemTemp.createTempSync('fa-ext-trim-');
    HeadlessChrome? trimmed;

    setUpAll(() async {
      _copyTree(
        Directory('${_repoRoot()}/browser_ext'),
        Directory('${trimmedRoot.path}/browser_ext'),
      );
      final manifest = File('${trimmedRoot.path}/browser_ext/manifest.json');
      manifest.writeAsStringSync(
        manifest.readAsStringSync().replaceFirst(
          RegExp(r'\n\s*"history",'),
          '',
        ),
      );
      trimmed = await HeadlessChrome.launch(
        extensionPath: '${trimmedRoot.path}/browser_ext',
      );
    });

    tearDownAll(() async {
      await trimmed?.dispose();
      deleteDirBestEffort(trimmedRoot);
    });

    test('catalog hides the trimmed namespace (truthful by construction)',
        () async {
      final catalog = (await bridgeCatalog(trimmed!))['namespaces'] as List;
      final roots = {for (final n in catalog) n as String};
      expect(roots.contains('history'), isFalse);
      expect(roots.contains('bookmarks'), isTrue); // sibling survived
    });

    test('a call on the ungranted namespace errors as data (AC6)', () async {
      final envelope = await bridgeCall(trimmed!, 'history.search', [
        {'text': ''},
      ]);
      expect(envelope['ok'], isFalse);
      expect((envelope['error'] as Map)['code'], 'api_missing');
    });

    test('the still-granted sibling keeps working', () async {
      final envelope = await bridgeCall(trimmed!, 'bookmarks.search', ['']);
      expect(envelope['ok'], isTrue,
          reason: 'bridge call failed: ${envelope['error']}');
    });
  });
}

/// Recursive tree copy (the trimmed build copies the built extension).
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final dest = '${to.path}/${entity.uri.pathSegments.last}';
    switch (entity) {
      case File():
        entity.copySync(dest);
      case Directory():
        _copyTree(entity, Directory(dest));
    }
  }
}
