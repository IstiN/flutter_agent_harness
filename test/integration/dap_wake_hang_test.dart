/// DAP wake-turn hang reproduction (integration, PTY, real CLI).
///
/// Owner report 2026-08-31: with the hub plugin connected, a mail-wake
/// turn occasionally wedges — spinner runs, ESC does nothing, no tool
/// calls appear; WITHOUT the plugin the CLI never hangs. Reproduces the
/// live sequence: a hub peer sends a series of DMs, each wakes the CLI
/// into a turn that must answer; a wake that never finishes (or that
/// ignores ESC) fails the test.
///
/// Moving parts:
/// - mock OpenAI-completions SSE server (deterministic answers, no keys;
///   echoes the "#N" marker of the last user message so every turn has a
///   unique completion marker to wait for)
/// - FakeHub from test/hub — the CLI's DAP plugin connects to it
/// - a package HubClient peer that DMs the CLI agent
/// - the REAL `dart bin/fah.dart` in a PTY (pty_harness)
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

import '../hub/fake_hub.dart';
import 'pty_harness.dart';

const timeout = Timeout(Duration(seconds: 300));

/// Deterministic SSE chat-completions endpoint. Answers embed the "#N"
/// marker found in the last user message of the request.
class MockProvider {
  HttpServer? _server;

  String get baseUrl => 'http://127.0.0.1:${_server!.port}/v1';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _serve() async {
    await for (final req in _server!) {
      final body = await utf8.decoder.bind(req).join();
      String marker = 'без номера';
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final messages = decoded['messages'] as List;
        for (final message in messages.reversed) {
          final role = (message as Map)['role'];
          if (role == 'user') {
            final content = message['content'];
            final text = content is String ? content : '$content';
            final match = RegExp(r'#(\d+)').firstMatch(text);
            if (match != null) marker = '#${match.group(1)}';
            break;
          }
        }
      } on Object {
        // unparseable body: keep the default marker
      }
      final res = req.response;
      res.statusCode = 200;
      res.headers.set('content-type', 'text/event-stream');
      const filler =
          'Принято, обработано. Ответ по существу: данные получены, '
          'действий не требуется, жду следующих сообщений.';
      final body_ = StringBuffer();
      for (var i = 0; i < 10; i++) {
        final chunk = i == 0 ? 'Ответ $marker. ' : filler;
        body_
          ..write('data: ')
          ..write(
            jsonEncode({
              'id': 'mock',
              'object': 'chat.completion.chunk',
              'choices': [
                {
                  'delta': {'content': chunk},
                  'index': 0,
                },
              ],
            }),
          )
          ..write('\n\n');
      }
      body_
        ..write('data: ')
        ..write(
          jsonEncode({
            'id': 'mock',
            'object': 'chat.completion.chunk',
            'choices': [
              {'delta': {}, 'finish_reason': 'stop', 'index': 0},
            ],
          }),
        )
        ..write('\n\ndata: [DONE]\n\n');
      res.add(utf8.encode(body_.toString()));
      await res.close();
    }
  }
}

/// Captures the wedged-process forensics: child CPU/state, the tail of
/// the newest session JSONL (which phase persisted last), and the last
/// screen bytes. Printed to the test log before the hard failure.
Future<void> _dumpWedgeDiagnostics(
  FaCliHarness harness,
  Directory home,
  int messageIndex,
) async {
  printOnFailure('=== WEDGE FORENSICS (message #$messageIndex) ===');
  try {
    final pgrep = await Process.run('pgrep', ['-f', 'bin/fah.dart']);
    final pids = (pgrep.stdout as String)
        .split(RegExp(r'\s+'))
        .where((id) => id.isNotEmpty)
        .toList();
    if (pids.isEmpty) {
      printOnFailure('ps: no bin/fah.dart process alive (already dead?)');
    } else {
      final ps = await Process.run('ps', [
        '-o',
        'pid,pcpu,etime,stat,command',
        '-p',
        pids.join(','),
      ]);
      printOnFailure('ps:\n${ps.stdout}');
    }
  } on Object catch (error) {
    printOnFailure('ps failed: $error');
  }
  try {
    final sessionsRoot = Directory('${home.path}/.fah/sessions');
    final files = sessionsRoot.existsSync()
        ? (sessionsRoot
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.jsonl'))
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            ))
        : const <File>[];
    if (files.isEmpty) {
      printOnFailure('sessions: none under ${sessionsRoot.path}');
    } else {
      final lines = await files.first.readAsLines();
      printOnFailure(
        'session tail (${files.first.path}, ${lines.length} lines):',
      );
      for (final line in lines.skip(lines.length - 4)) {
        printOnFailure(
          '  ${line.length > 300 ? '${line.substring(0, 300)}…' : line}',
        );
      }
    }
  } on Object catch (error) {
    printOnFailure('session dump failed: $error');
  }
  final raw = harness.rawOutput;
  final tailStart = raw.length > 600 ? raw.length - 600 : 0;
  printOnFailure('terminal tail: …${raw.substring(tailStart)}');
}

void main() {
  test(
    'mail-wake turns never wedge: 12 hub DMs each wake and answer; ESC '
    'recovers a stalled wake',
    timeout: timeout,
    () async {
      final provider = MockProvider();
      await provider.start();
      final hub = FakeHub();
      await hub.start();

      final home = await Directory.systemTemp.createTemp('fah-dap-repro-');
      addTearDown(() async {
        await home.delete(recursive: true);
      });

      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': home.path,
          'OPENAI_API_KEY': 'mock-key',
          'DAP_HUB_URL': hub.url.toString(),
          'DAP_MASTER_SECRET': 'test-master',
          'DAP_AGENT_NAME': 'repro_cli',
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

      // Boot: banner + the hub connect line carrying our agent id.
      await harness.waitForBoot();
      final connected = await harness.waitForText(
        '[hub] connected as ',
        timeout: const Duration(seconds: 60),
      );
      final cliAgentId = RegExp(
        r'\[hub\] connected as ([0-9a-f]{16})',
      ).firstMatch(connected)![1]!;

      // The peer that DMs the CLI (a second real package client).
      final peer = HubClient(
        config: HubConfig(url: hub.url.toString(), name: 'repro_peer'),
        identity: await HubIdentity.generate(),
      );
      await peer.connect();
      addTearDown(peer.disconnect);
      addTearDown(hub.stop);
      addTearDown(provider.stop);

      // The live-incident sequence, exactly as the owner's log: a typed
      // user prompt, then a wave of hub DMs each waking a turn that must
      // answer with the SAME marker, then the next typed prompt. Typed
      // lines reset the inbox wake-streak cap (10 agent-chat wakes), so
      // this measures the REAL wedge — a wake that starts and never
      // finishes — not the by-design ping-pong cap.
      Future<void> expectMarker(String marker, {int seconds = 15}) async {
        try {
          await harness.waitForText(
            marker,
            timeout: Duration(seconds: seconds),
          );
        } on TimeoutException {
          harness.sendEscape();
          await harness.waitForOutput(settleMs: 500);
          await _dumpWedgeDiagnostics(harness, home, 0);
          fail('WEDGE REPRODUCED waiting for "$marker".');
        }
      }

      for (var batch = 1; batch <= 3; batch++) {
        // Typed user prompt (resets the wake cap), like "кто онлайн…".
        harness.sendText('волна #$batch — проверка связи');
        await harness.waitForOutput(settleMs: 300);
        harness.sendEnter();
        await expectMarker('Ответ #$batch.');

        // The mail wave: 6 hub DMs, each waking one answering turn.
        for (var i = 1; i <= 6; i++) {
          final n = batch * 10 + i;
          await peer.sendDm(cliAgentId, 'сообщение #$n — ответь коротко');
          await expectMarker('Ответ #$n.');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    },
  );
}
