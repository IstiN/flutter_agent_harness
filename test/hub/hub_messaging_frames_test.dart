// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Frame-level coverage for `HubMessagingRepository`'s inbound dispatch
/// (gh-1888 rework): `joined` and `error` hub frames plus PUBLIC channel
/// mail (the raw base64 JSON text contract). The CRAP ratchet measures
/// the merged unit-suite lcov; these branches were invisible to the
/// FakeHub protocol tests because the production `LocalHub` answers
/// joins promptly and never emits foreign channel payloads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

const timeout = Timeout(Duration(seconds: 30));

Duration testBackoff(int attempt) => const Duration(milliseconds: 5);

/// Raw-socket hub speaking just enough DAP to steer the repository:
/// hello → welcome; join `ok-channel` → joined (+ a pushed PUBLIC channel
/// message from a fabricated peer); join `denied-channel` → access_denied.
final class _FrameHub {
  HttpServer? _server;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    unawaited(_serve());
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      unawaited(_handle(await WebSocketTransformer.upgrade(request)));
    }
  }

  Future<void> _handle(WebSocket ws) async {
    try {
      await for (final data in ws) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        switch (frame['op'] as String?) {
          case 'hello':
            final digest = await Sha256().hash(
              base64Decode(frame['pubkey'] as String),
            );
            final agentId = digest.bytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .substring(0, 16);
            ws.add(jsonEncode({'op': 'welcome', 'agentId': agentId}));
          case 'join':
            final channel = frame['channel'] as String?;
            if (channel == 'denied-channel') {
              ws.add(
                jsonEncode({
                  'op': 'error',
                  'code': 'access_denied',
                  'msg': 'not invited',
                }),
              );
            } else {
              ws.add(jsonEncode({'op': 'joined', 'channel': channel}));
              // A PUBLIC payload from a fabricated peer: raw base64 of the
              // JSON text contract (what a keyless member decodes).
              ws.add(
                jsonEncode({
                  'op': 'msg',
                  'id': 'cm-1',
                  'channel': channel,
                  'from': 'fabricated-peer',
                  'ts': 1700000000000,
                  'ciphertext': base64Encode(
                    utf8.encode(jsonEncode({'text': 'hello room'})),
                  ),
                }),
              );
            }
          case 'flush':
            ws.add(jsonEncode({'op': 'flushed', 'count': 0}));
        }
      }
    } on Object {
      // socket gone — test teardown
    }
  }
}

void main() {
  late _FrameHub hub;
  late HubMessagingRepository repo;

  setUp(() async {
    hub = _FrameHub();
    await hub.start();
  });

  tearDown(() async {
    await repo.stop();
    await hub.stop();
  });

  test(
    'joined frame completes joinChannel; PUBLIC channel mail drains',
    () async {
      repo = HubMessagingRepository(
        url: hub.url,
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      await repo.start();
      await repo.joinChannel('ok-channel');
      // The hub pushed a PUBLIC channel message right after the join.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      List<AgentMessage> mail;
      do {
        mail = await repo.drain('main');
        if (mail.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (DateTime.now().isBefore(deadline));
      expect(mail, hasLength(1));
      expect(mail.single.toId, '#ok-channel');
      expect(mail.single.text, 'hello room');
      expect(mail.single.fromId, 'fabricated-peer');
    },
  );

  test('an access_denied error frame fails the pending join with a clear '
      'error', () async {
    repo = HubMessagingRepository(
      url: hub.url,
      transport: const IoHubTransport(),
      backoff: testBackoff,
    );
    await repo.start();
    await expectLater(
      repo.joinChannel('denied-channel'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('hub denied channel join'),
        ),
      ),
    );
  });
}
