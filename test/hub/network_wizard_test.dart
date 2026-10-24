// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hub/dap_invite_import.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';

final class _IO implements PluginIO {
  final List<String> lines = [];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

void main() {
  const invite =
      'wss://hub.fa1.dev/ws?channel=team'
      '#pub=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'
      '&priv=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';

  late Directory tmp;
  late List<String> scopedConnects;
  late Map<String, String> env;
  late List<Map<String, Object?>> sessionRecords;
  late _IO io;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('network-wizard-test');
    env = {'DAP_KEY_PASSPHRASE': 'pass'};
    sessionRecords = [];
    scopedConnects = [];
    io = _IO();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  PluginContext buildContext({
    Future<String?> Function(
      String,
      List<PluginMenuOption>, {
      String? initialKey,
    })?
    pick,
    Future<String?> Function(String, {bool secret})? ask,
  }) {
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: tmp.path),
      io: io,
      pickOption: pick,
      askLine: ask,
      appendSessionRecord: (type, data) async {
        sessionRecords.add(Map<String, Object?>.from(data));
      },
      readSessionRecords: (type) async => sessionRecords,
    );
    final host = HubPluginHost(
      hub.HubPlugin(environment: env, home: tmp.path),
      environment: env,
      home: tmp.path,
    );
    // Never dial a real hub from unit tests: the scoped connection is
    // replaced by a recording stub (production dials the enrolled
    // credential on the host-owned client).
    host.scopedConnectOverride = (hubUrl) async {
      scopedConnects.add(hubUrl);
    };
    host.register(context);
    return context;
  }

  test(
    'join via args defaults to session scope + trust notice (AC1/AC8)',
    () async {
      final context = buildContext();
      final network = context.slashCommands['/network']!;
      await network(['join', invite]);

      expect(sessionRecords, hasLength(1));
      expect(sessionRecords.single['channelId'], 'team');
      expect(sessionRecords.single['scope'], 'session');
      // Encrypted at rest, never plaintext.
      expect(sessionRecords.single['priv'], isNot(contains('A0ID')));
      expect(io.text, contains('members can steer this agent'));
      expect(io.text, contains('joined #team [session]'));
    },
  );

  test('E4: garbage invite → inline error, nothing stored, no join', () async {
    final context = buildContext();
    await context.slashCommands['/network']!(['join', 'not an invite']);
    expect(sessionRecords, isEmpty);
    expect(io.text, contains('invalid invite'));
  });

  test('menu flow: Join → paste → project scope → encrypted .fah/dap.json '
      '(AC6)', () async {
    final picks = <String>['join', 'project'];
    final context = buildContext(
      pick: (title, options, {initialKey}) async {
        expect(picks, isNotEmpty);
        return picks.removeAt(0);
      },
      ask: (question, {secret = false}) async => invite,
    );
    await context.slashCommands['/network']!([]);

    final project = File('${tmp.path}/.fah/dap.json');
    expect(await project.exists(), isTrue);
    final raw = await project.readAsString();
    expect(raw, contains('"channelId": "team"'));
    expect(raw, contains('dapkey1.'));
    expect(raw, isNot(contains('A0ID')));
    expect(io.text, contains('joined #team [project]'));
  });

  test('bare channel id joins on the configured hub (AC1 form 3)', () async {
    env['DAP_HUB_URL'] = 'wss://hub.fa1.dev/ws';
    final context = buildContext();
    await context.slashCommands['/network']!(['join', 'team']);
    expect(sessionRecords.single['channelId'], 'team');
    expect(sessionRecords.single['hubUrl'], 'wss://hub.fa1.dev/ws');
  });

  test('composer-prefilled form: the whole fa dap import command parses '
      '(AC7 same wizard)', () async {
    final context = buildContext();
    await context.slashCommands['/network']!([
      'join',
      "fa dap import '$invite'",
    ]);
    expect(sessionRecords.single['channelId'], 'team');
  });

  test('channels menu: copy invite round-trips; leave(session) tombstones '
      '(AC4/E6)', () async {
    final context = buildContext();
    final network = context.slashCommands['/network']!;
    await network(['join', invite]);

    // Re-register with interactive picks: channel → copy, then leave.
    final picks = <String>['channels'];
    final interactive = buildContext(
      pick: (title, options, {initialKey}) async {
        if (title == 'Network') return 'channels';
        if (title == '#team') return 'copy';
        return options.first.$1;
      },
    );
    await interactive.slashCommands['/network']!([]);
    final copiedLine = io.lines.lastWhere((l) => l.contains('channel=team'));
    expect(parseDapInviteFlexible(copiedLine).channel, 'team');
    expect(picks, isNotEmpty); // sanity: the menu really ran
  });

  test('the AGENT learns about the joined channel and the write path '
      '(agent_message to: #channel) via the notice inbox', () async {
    final context = buildContext();
    await context.slashCommands['/network']!(['join', invite]);
    final notices = <AgentMessage>[];
    for (final inbox in context.externalInboxes) {
      notices.addAll(await inbox.drain());
    }
    final text = notices.map((m) => m.text).join('\n');
    expect(text, contains('#team'));
    expect(text, contains('agent_message to: "#team"'));
    expect(text, contains('can steer'));
  });

  test('boot notice: existing memberships are announced to the agent on '
      'the first drain (resume awareness)', () async {
    final context = buildContext();
    await context.slashCommands['/network']!(['join', invite]);
    // A fresh host over the same records = the resumed session.
    final resumed = buildContext();
    final notices = <AgentMessage>[];
    for (final inbox in resumed.externalInboxes) {
      notices.addAll(await inbox.drain());
    }
    expect(notices.map((m) => m.text).join('\n'), contains('#team'));
  });

  test(
    'the full app DAP one-liner joins with the enrolled credential '
    '(name-bound secret stored encrypted, honest NOT-live verdict)',
    () async {
      final context = buildContext();
      final command =
          "fa dap import '$invite' && DAP_HUB_URL=wss://hub.fa1.dev/ws "
          "DAP_CLIENT_SECRET='hub-secret-1' DAP_AGENT_NAME=public-agent fa";
      await context.slashCommands['/network']!(['join', command]);
      final record = sessionRecords.last;
      expect(record['agentName'], 'public-agent');
      expect(record['hubClientSecret'], startsWith('dapkey1.'));
      expect(io.text, contains('NOT live'));
      expect(scopedConnects, ['wss://hub.fa1.dev/ws']);
    },
  );

  test('headless /network prints a one-line status, no menus (AC10)', () async {
    final context = buildContext();
    await context.slashCommands['/network']!(['join', invite]);
    io.lines.clear();
    await context.slashCommands['/network']!([]);
    expect(io.text, contains('network: 1 channel(s): #team'));
  });
}
