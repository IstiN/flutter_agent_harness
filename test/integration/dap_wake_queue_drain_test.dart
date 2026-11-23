/// Composer-queue drain after a NON-submit run settles (integration, PTY).
///
/// CI red on 3f16ab28 (PTY/CLI integration shard 1/3,
/// `dap_chatter_loop_test.dart` CONTRACT-2): the chatter loop's wake run
/// settles, the typed `СТОП #999` lands in the composer queue
/// (`⏵ queued (1)`), and it sits there forever — CONTRACT-2 times out
/// waiting for `Ответ #999.`. Mechanism: the queue is drained by
/// `_handleTuiQueue` bound to `_handleTuiSubmit` — a run started by the
/// INBOX WAKE (hub DM) has no pending submit future, so when it settles
/// nothing drains the queue. Locally the race hides (the run settles
/// before CONTRACT-2 types, so the busy gate never queues the line);
/// under CI load CONTRACT-1's screen-based idle check lands in a
/// between-turns gap, Enter hits the busy gate, and the queue orphans.
///
/// This test pins the contract DETERMINISTICALLY: the first (DM wake)
/// turn is held open by a gate while the typed line is submitted (the
/// busy gate is provably engaged — `queued (1)` is asserted on screen),
/// then the gate releases and the wake run settles. The queued line must
/// submit and be answered with NO further user input — the every-trigger
/// settle edge must drain the composer queue.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

import '../hub/fake_hub.dart';
import 'pty_harness.dart';

const timeout = Timeout(Duration(seconds: 180));

/// Mock completions endpoint. The FIRST non-stop request (the hub-DM wake
/// turn) is held open until [release] — the run stays provably busy while
/// the test types. A request whose last user message carries `СТОП #999`
/// (the typed queued line, delivered by the queue drain) answers
/// immediately with plain text.
class WakeQueueMockProvider {
  HttpServer? _server;
  final _gate = Completer<void>();

  String get baseUrl => 'http://127.0.0.1:${_server!.port}/v1';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async => _server?.close(force: true);

  /// Releases the held wake turn — the run settles.
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<void> _serve() async {
    await for (final req in _server!) {
      final body = await utf8.decoder.bind(req).join();
      var isTypedStop = false;
      try {
        final messages = (jsonDecode(body) as Map)['messages'] as List;
        for (final message in messages.reversed) {
          if ((message as Map)['role'] != 'user') continue;
          final content = message['content'];
          final text = content is String ? content : '$content';
          if (text.contains('СТОП #999')) isTypedStop = true;
          break;
        }
      } on Object {
        // unparsable — treat as the wake turn
      }
      if (!isTypedStop) {
        // The DM wake turn: hold until the typed line is provably queued.
        await _gate.future.timeout(
          const Duration(seconds: 120),
          onTimeout: () {},
        );
      }
      final res = req.response;
      res.statusCode = 200;
      res.headers.set('content-type', 'text/event-stream');
      final marker = isTypedStop ? '#999' : 'dm';
      final payload = isTypedStop ? 'Ответ #999.' : 'dm turn answered';
      final out = StringBuffer();
      void event(Map<String, dynamic> delta, [String? finish]) {
        out
          ..write('data: ')
          ..write(
            jsonEncode({
              'id': 'mock',
              'object': 'chat.completion.chunk',
              'choices': [
                {'delta': delta, 'index': 0, 'finish_reason': ?finish},
              ],
            }),
          )
          ..write('\n\n');
      }

      event({'content': payload});
      event({}, 'stop');
      out.write('data: [DONE]\n\n');
      res.add(utf8.encode(out.toString()));
      await res.close();
      // Silence the unused-marker analyzer path: marker only aids logs.
      assert(marker.isNotEmpty);
    }
  }
}

void main() {
  test(
    'a queued typed line drains when a hub-DM wake run settles '
    '(no further user submit)',
    timeout: timeout,
    () async {
      final provider = WakeQueueMockProvider();
      await provider.start();
      final hub = FakeHub();
      await hub.start();

      final home = await Directory.systemTemp.createTemp('fah-wake-queue-');
      addTearDown(() async {
        await home.delete(recursive: true);
      });

      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': home.path,
          'OPENAI_API_KEY': 'mock-key',
          'DAP_HUB_URL': hub.url.toString(),
          'DAP_MASTER_SECRET': 'test-master',
          'DAP_AGENT_NAME': 'wake_queue_cli',
        },
        args: [
          '--provider',
          'openai-completions',
          '--base-url',
          provider.baseUrl,
          '--model',
          'repro-model',
        ],
        columns: 100,
        rows: 30,
      );
      addTearDown(harness.close);

      await harness.waitForBoot();
      final connected = await harness.waitForText(
        '[hub] connected as ',
        timeout: const Duration(seconds: 60),
      );
      final cliAgentId = RegExp(
        r'\[hub\] connected as ([0-9a-f]{16})',
      ).firstMatch(connected)![1]!;

      final peer = HubClient(
        config: HubConfig(url: hub.url.toString(), name: 'wake_peer'),
        identity: await HubIdentity.generate(),
      );
      await peer.connect();
      addTearDown(peer.disconnect);
      addTearDown(hub.stop);
      addTearDown(provider.stop);

      // One DM → the inbox wake path starts a run (NOT a TUI submit).
      await peer.sendDm(cliAgentId, 'сообщение #1 — ответь');
      await harness.waitForText(
        'Working',
        timeout: const Duration(seconds: 30),
      );

      // The run is provably busy: typing mid-run hits the composer's busy
      // gate and queues the line.
      harness.sendText('СТОП #999');
      await harness.waitForOutput(settleMs: 300);
      harness.sendEnter();
      await harness.waitForText(
        'queued (1)',
        timeout: const Duration(seconds: 15),
      );

      // Release the wake turn; the run settles (no chatter loop — one
      // turn). The queued line must now submit ON ITS OWN.
      provider.release();
      final answered = await harness.waitForText(
        'Ответ #999.',
        timeout: const Duration(seconds: 45),
      );
      expect(answered, contains('Ответ #999.'));
    },
  );
}
