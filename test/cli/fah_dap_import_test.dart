// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// `fa dap import <invite>` (issue #955): the CLI side of the app's
/// add-agent flow — the owner copies the AC-B17 invite out of the app and
/// hands it to the agent; the command persists the channel keypair and
/// the hub url without ever echoing the private key.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/dap_invite_import.dart';
import 'package:test/test.dart';

import '../../bin/fah_dap_command.dart' show runDapCommand;

void main() {
  const pub = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='; // 32 bytes
  const priv = 'QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ='; // 32 bytes
  const invite = 'wss://hub.fa1.dev/ws?channel=vvv#pub=$pub&priv=$priv';

  group('parseDapInviteImport', () {
    test('round-trips the app invite shape', () {
      final parsed = parseDapInviteImport(invite);
      expect(parsed.hubUrl, 'wss://hub.fa1.dev/ws?channel=vvv');
      expect(parsed.channel, 'vvv');
      expect(parsed.pub, pub);
      expect(parsed.priv, priv);
    });

    test('strips the fragment from the hub url (keys never travel)', () {
      final parsed = parseDapInviteImport(invite);
      expect(parsed.hubUrl, isNot(contains('priv')));
      expect(parsed.hubUrl, isNot(contains('pub=')));
    });

    test('ws:// allowed for a local hub', () {
      final parsed = parseDapInviteImport(
        'ws://127.0.0.1:8787/ws?channel=c#pub=$pub&priv=$priv',
      );
      expect(parsed.hubUrl, startsWith('ws://127.0.0.1:8787'));
    });

    for (final (name, raw, reason) in [
      ('http scheme', 'https://h/ws?channel=c#pub=$pub&priv=$priv', 'wss'),
      ('no host', 'wss://?channel=c#pub=$pub&priv=$priv', 'host'),
      ('no channel', 'wss://h/ws#pub=$pub&priv=$priv', 'channel'),
      ('no fragment', 'wss://h/ws?channel=c', 'fragment'),
      ('bad pub', 'wss://h/ws?channel=c#pub=AA==&priv=$priv', '32 bytes'),
      ('not base64', 'wss://h/ws?channel=c#pub=%%%&priv=$priv', 'base64'),
      ('empty', '', 'wss'),
    ]) {
      test('rejects $name', () {
        expect(
          () => parseDapInviteImport(raw),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
        );
      });
    }
  });

  group('fa dap import', () {
    late Directory home;
    late List<String> lines;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('dap-import-test');
      lines = [];
    });
    tearDown(() async {
      if (await home.exists()) await home.delete(recursive: true);
    });

    Future<int> run(List<String> args) => runDapCommand(
      args,
      home: home.path,
      environment: const {},
      out: lines.add,
    );

    test('persists the keypair + hub url; the priv never prints', () async {
      expect(await run(['import', invite]), 0);

      final channels =
          jsonDecode(
                await File('${home.path}/.dap/channels.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(channels['vvv'], {'pub': pub, 'priv': priv});

      final config =
          jsonDecode(await File('${home.path}/.dap/config.json').readAsString())
              as Map<String, dynamic>;
      expect(config['url'], 'wss://hub.fa1.dev/ws?channel=vvv');
      expect(config['channels'], contains('vvv'));

      final transcript = lines.join('\n');
      expect(transcript, contains('#vvv'));
      expect(transcript, isNot(contains(priv))); // I2: priv never echoes
    });

    test('keeps an existing hub url, reports the difference', () async {
      await File('${home.path}/.dap/config.json').create(recursive: true);
      await File(
        '${home.path}/.dap/config.json',
      ).writeAsString('{"url":"ws://127.0.0.1:8787/ws"}');

      expect(await run(['import', invite]), 0);

      final config =
          jsonDecode(await File('${home.path}/.dap/config.json').readAsString())
              as Map<String, dynamic>;
      expect(config['url'], 'ws://127.0.0.1:8787/ws'); // not clobbered
      expect(lines.join('\n'), contains('keeps its hub url'));
    });

    test('invalid invite exits 1 with the reason, writes nothing', () async {
      expect(await run(['import', 'https://nope']), 1);
      expect(lines.single, contains('scheme'));
      expect(await File('${home.path}/.dap/channels.json').exists(), isFalse);
    });

    test('missing argument prints usage', () async {
      expect(await run(['import']), 1);
      expect(lines.single, contains('usage'));
    });
  });
}
