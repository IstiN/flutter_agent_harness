/// Unit tests for the pure hub-auth seams in `lib/src/hub/local_hub.dart`
/// (exported via `lib/io.dart`): state-file parsing/writing, the upgrade
/// credential extraction, and the state-file path resolution. No sockets —
/// the live-socket auth matrix lives in `local_hub_test.dart`
/// (integration-tagged).
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  group('defaultHubStateFile', () {
    test('DAP_HUB_STATE_FILE wins outright', () {
      final file = defaultHubStateFile(
        home: '/home/u',
        environment: {'DAP_HUB_STATE_FILE': '/tmp/custom.json'},
      );
      expect(file.path, '/tmp/custom.json');
    });

    test('home override builds ~/.dap/hub.json', () {
      final file = defaultHubStateFile(home: '/home/u', environment: const {});
      expect(file.path, '/home/u/.dap/hub.json');
    });

    test('a trailing-slash home is not doubled', () {
      final file = defaultHubStateFile(home: '/home/u/', environment: const {});
      expect(file.path, '/home/u/.dap/hub.json');
    });
  });

  group('readHubState / readHubStateSecret', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hub_state_unit');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('missing file = empty state', () {
      final state = readHubState(File('${dir.path}/nope.json'));
      expect(state.masterSecret, isNull);
      expect(state.clients, isEmpty);
    });

    test('invalid json = empty state', () async {
      final file = File('${dir.path}/bad.json');
      await file.writeAsString('not json {');
      expect(readHubStateSecret(file), isNull);
    });

    test('non-map json = empty state', () async {
      final file = File('${dir.path}/list.json');
      await file.writeAsString('[1,2,3]');
      expect(readHubState(file).masterSecret, isNull);
    });

    test('valid state round-trips through writeHubState', () async {
      final file = File('${dir.path}/hub.json');
      await writeHubState(
        file,
        masterSecret: 'pw',
        clients: const {'agent-a': 'tok-a', 'agent-b': 'tok-b'},
      );
      final state = readHubState(file);
      expect(state.masterSecret, 'pw');
      expect(state.clients, {'agent-a': 'tok-a', 'agent-b': 'tok-b'});
      expect(readHubStateSecret(file), 'pw');
    });

    test('non-string client values are dropped', () async {
      final file = File('${dir.path}/mixed.json');
      await file.writeAsString(
        '{"masterSecret":"pw","clients":{"a":"tok","b":42}}',
      );
      final state = readHubState(file);
      expect(state.clients, {'a': 'tok'});
    });
  });

  group('hubUpgradeCredential', () {
    test('no header and no token = null', () {
      expect(hubUpgradeCredential(null, const {}), isNull);
    });

    test('Bearer header wins over the query token', () {
      expect(
        hubUpgradeCredential('Bearer header-secret', const {
          'dap_token': 'query-secret',
        }),
        'header-secret',
      );
    });

    test('query token alone (browser path)', () {
      expect(
        hubUpgradeCredential(null, const {'dap_token': 'query-secret'}),
        'query-secret',
      );
    });

    test('malformed header falls through to the query token', () {
      expect(hubUpgradeCredential('Basic abc', const {'dap_token': 'q'}), 'q');
      expect(hubUpgradeCredential('Basic abc', const {}), isNull);
    });

    test('empty values count as absent', () {
      expect(hubUpgradeCredential('Bearer ', const {}), isNull);
      expect(hubUpgradeCredential(null, const {'dap_token': ''}), isNull);
    });
  });

  group('hubAuthVerdict', () {
    test('open hub allows everything (never master)', () {
      expect(hubAuthVerdict(null, null, const []), (
        allowed: true,
        isMaster: false,
      ));
      expect(hubAuthVerdict('anything', null, const []), (
        allowed: true,
        isMaster: false,
      ));
    });

    test('the master password is allowed and marked master', () {
      expect(hubAuthVerdict('pw', 'pw', const []), (
        allowed: true,
        isMaster: true,
      ));
    });

    test('an enrolled client secret is allowed but not master', () {
      expect(hubAuthVerdict('tok', 'pw', const ['tok']), (
        allowed: true,
        isMaster: false,
      ));
    });

    test('unknown or missing credentials are rejected', () {
      expect(hubAuthVerdict(null, 'pw', const ['tok']), (
        allowed: false,
        isMaster: false,
      ));
      expect(hubAuthVerdict('wrong', 'pw', const ['tok']), (
        allowed: false,
        isMaster: false,
      ));
    });
  });

  group('hubEnrollDecision', () {
    var seq = 0;
    String nextSecret() => 'issued-\${seq++}';

    test('open hub issues a ceremonial secret, nothing to persist', () {
      final d = hubEnrollDecision(
        isProtected: false,
        isMaster: false,
        newSecret: nextSecret,
      );
      expect(d.reply['t'], 'enrolled');
      expect(
        d.reply,
        containsPair(
          'sec'
          'ret',
          isA<String>(),
        ),
      );
      expect(d.issueSecret, isNull);
    });

    test('protected hub master enroll issues + persists', () {
      final d = hubEnrollDecision(
        isProtected: true,
        isMaster: true,
        newSecret: nextSecret,
      );
      expect(d.reply['t'], 'enrolled');
      expect(d.issueSecret, isNotNull);
      expect(
        d.reply['sec'
            'ret'],
        d.issueSecret,
      );
    });

    test('protected hub non-master enroll is refused', () {
      final d = hubEnrollDecision(
        isProtected: true,
        isMaster: false,
        newSecret: nextSecret,
      );
      expect(d.reply['t'], 'error');
      expect(d.reply['code'], 'unauthorized');
      expect(d.issueSecret, isNull);
    });
  });
}
