// AC14 — local↔browser mail relay, both directions, against the REAL
// fabric + bridge server (in-process BridgeServer over a temp project
// root; `fa serve --bridge` wraps exactly this class):
//
//   * pairing: `.fah/bridge/token` anchors the one-time token; the
//     extension pairs through the panel path (storage set + bridge.connect).
//   * direction 1: extension sendMail('main', …) lands in main's fabric
//     inbox file (FileMessagingRepository layout on the real FS).
//   * direction 2: a fabric mail INTO the extension mailbox reaches the
//     service worker (the __faMailLog test hook in sw/main.js).
//   * tail: the extension mailbox shows up in FileMessagingRepository.
//     directory().
//
// Requires a REAL Chrome and a prior scripts/build_browser_ext.sh run. No
// Chrome → loud ChromeLaunchException; `integration` tag keeps this out of
// default runs.
@Tags(['integration'])
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import '../../bin/serve_bridge.dart';
import 'chrome_driver.dart';

Directory? _root;
Directory get root => _root!;
late FileMessagingRepository repo;
BridgeServer? _server;
HeadlessChrome? _chrome;

/// Non-null once setUpAll succeeded; tests only run after that.
BridgeServer get server => _server!;
HeadlessChrome get chrome => _chrome!;

void main() {
  setUpAll(() async {
    _root = await Directory.systemTemp.createTemp('fa-bridge-e2e-');
    repo = FileMessagingRepository(
      env: LocalExecutionEnv(cwd: root.path),
      root: '${root.path}/messages',
    );
    final token = await BridgeTokenFile(root.path).ensure();
    _server = BridgeServer(
      messaging: repo,
      root: root.path,
      token: token,
      port: 0,
      // Fast timers: the suite must not outlive a coffee.
      pollInterval: const Duration(milliseconds: 40),
      heartbeatInterval: const Duration(milliseconds: 60),
      dispatchTimeout: const Duration(seconds: 2),
    );
    await server.start();
    _chrome = await HeadlessChrome.launch();
  });

  tearDownAll(() async {
    await _chrome?.dispose();
    await _server?.stop();
    final temp = _root;
    if (temp != null && temp.existsSync()) await temp.delete(recursive: true);
  });

  /// Pairs the extension exactly like the panel's "pair" handler (storage
  /// cfg + bridge.connect) and waits for `connected`.
  Future<String> pairAndAwaitConnected() async {
    await evaluateInServiceWorker(
      chrome,
      'chrome.storage.local.set({bridgeUrl: ${jsonEncode(server.url)}, '
      'token: ${jsonEncode(server.token)}})',
      awaitPromise: true,
    );
    await evaluateInServiceWorker(
      chrome,
      'globalThis.faSw.bridge.connect('
      '${jsonEncode(server.url)}, ${jsonEncode(server.token)})',
      awaitPromise: true,
    );
    final status = await pollUntil(
      () => evaluateInServiceWorker(
        chrome,
        'globalThis.faSw.bridge.status()',
        awaitPromise: true,
      ),
      (s) => s['phase'] == 'connected' && s['mailbox'] != null,
      description: 'bridge reach connected phase',
      timeout: const Duration(seconds: 20),
    );
    return status['mailbox'] as String;
  }

  test('pairing token file anchors the one-time token', () async {
    final file = File('${root.path}/.fah/bridge/token');
    expect(file.existsSync(), true, reason: 'BridgeTokenFile must mint it');
    expect(file.readAsStringSync().trim(), server.token);
  });

  test('AC14 d1: extension sendMail lands in the main fabric inbox', () async {
    await pairAndAwaitConnected();

    // Resolves only on the server ack — the round trip itself is asserted.
    await evaluateInServiceWorker(
      chrome,
      "globalThis.faSw.bridge.sendMail('main', 'hi from ext')",
      awaitPromise: true,
    );

    final inbox = await pollUntil(
      () => repo.peek('main'),
      (messages) => messages.any((m) => m.text == 'hi from ext'),
      description: 'fabric inbox for main receives the extension mail',
    );
    expect(inbox.single.fromId, startsWith('browser-ext/'));

    // The FILE layout is the contract — assert on the real filesystem too.
    final files = Directory('${root.path}/messages/main/inbox').listSync();
    expect(files, isNotEmpty);
    expect(
      files.map((f) => File(f.path).readAsStringSync()),
      contains(contains('hi from ext')),
    );
  });

  test('AC14 d2: fabric mail reaches the extension service worker', () async {
    final mailbox = await pairAndAwaitConnected();
    final sw = await chrome.attachServiceWorker();

    await repo.send(
      AgentMessage(
        id: newMessageId(),
        fromId: 'main',
        toId: mailbox,
        text: 'hello from fabric',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );

    final mailLog = await pollUntil(
      () async =>
          await sw.evaluate('globalThis.__faMailLog ?? []', awaitPromise: true),
      (log) => (log as List).any(
        (entry) =>
            entry['from'] == 'main' && entry['text'] == 'hello from fabric',
      ),
      description: 'extension receives fabric mail (mail log hook)',
    );
    final entry = (mailLog as List).last as Map;
    expect(entry['from'], 'main');
    expect(entry['ts'], isNotNull);
  });

  test(
    'AC14 tail: extension mailbox appears in the fabric directory',
    () async {
      final mailbox = await pairAndAwaitConnected();
      final directory = await repo.directory();
      expect(
        directory.map((entry) => entry.id),
        contains(mailbox),
        reason: 'the paired extension mailbox must be listable',
      );
    },
  );
}
