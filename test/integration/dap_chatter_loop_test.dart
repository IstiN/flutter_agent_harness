/// Mid-run steering chatter loop (integration, PTY, real CLI).
///
/// Live incident (owner, 2026-08-31): the CLI "hangs" — spinner forever,
/// ESC dead, typed input never submits — while it KEEPS exchanging hub
/// messages (/stats still answers: slash commands bypass the busy queue).
/// Cause: agent_loop's inner `while (hasMoreToolCalls ||
/// pendingMessages.isNotEmpty)` extends the run on EVERY steered message
/// with no cap; a hub peer that answers every dap_dm closes a
/// self-sustaining loop, so the run never settles and plain typed lines
/// queue forever behind the endless run.
///
/// Repro shape (all local): the mock completions endpoint answers every
/// steered `from <id>: …` user message with a dap_dm TOOL CALL back to
/// the sender; the test peer auto-replies to every inbound DM. That is
/// the closed loop. The contract under test: the run must SETTLE within
/// bounds — a typed user line must submit and be answered afterwards.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

import '../hub/fake_hub.dart';
import 'pty_harness.dart';

const timeout = Timeout(Duration(seconds: 240));

/// Mock completions endpoint that closes the chatter loop: any user
/// message of the form `from <16-hex>: …#N` gets a dap_dm tool call back
/// to that sender; anything else gets plain text echoing its `#N` marker.
class LoopMockProvider {
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
      var toolTarget = '';
      var marker = 'без номера';
      var alreadyReplied = false;
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final messages = decoded['messages'] as List;
        for (final message in messages.reversed) {
          final role = (message as Map)['role'];
          if (role == 'assistant') {
            final toolCalls = message['tool_calls'];
            if (toolCalls is List && toolCalls.isNotEmpty) {
              alreadyReplied = true;
            }
            continue;
          }
          if (role != 'user') continue;
          final content = message['content'];
          final lastUser = content is String ? content : '$content';
          final hex = RegExp(r'from ([0-9a-f]{16}):').firstMatch(lastUser);
          if (hex != null) toolTarget = hex.group(1)!;
          final n = RegExp(r'#(\d+)').firstMatch(lastUser);
          if (n != null) marker = '#${n.group(1)}';
          break;
        }
        // An explicit typed STOP wins over backlog mail: wake-cap pending
        // hub mail is delivered as steering inside the typed run (by
        // design), landing AFTER the typed prompt — a last-message pick
        // would answer the backlog and never the typed line.
        for (final message in messages) {
          final role = (message as Map)['role'];
          if (role != 'user') continue;
          final content = message['content'];
          final text = content is String ? content : '$content';
          final stop = RegExp(r'СТОП #(\d+)').firstMatch(text);
          if (stop != null) {
            marker = '#${stop.group(1)}';
            toolTarget = '';
          }
        }
      } on Object {
        // keep defaults
      }
      if (alreadyReplied) toolTarget = '';
      final res = req.response;
      res.statusCode = 200;
      res.headers.set('content-type', 'text/event-stream');
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

      if (toolTarget.isNotEmpty) {
        event({
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_loop',
              'type': 'function',
              'function': {
                'name': 'dap_dm',
                'arguments': jsonEncode({
                  'to': toolTarget,
                  'text': 'авто-ответ $marker',
                }),
              },
            },
          ],
        });
      } else {
        event({'content': 'Ответ $marker.'});
        event({}, 'stop');
      }
      out.write('data: [DONE]\n\n');
      res.add(utf8.encode(out.toString()));
      await res.close();
    }
  }
}

/// Compact wedge forensics: plugin state (~/.dap), session JSONL tail +
/// per-type record counts, ANSI-stripped [mail] line census.
Future<void> _dumpWedgeDiagnostics(
  FaCliHarness harness,
  Directory home,
  int messageIndex,
) async {
  printOnFailure('=== WEDGE FORENSICS (message #$messageIndex) ===');
  // The wedge-time probe `_anyPluginInboxPending` (lib/src/cli/
  // agent_cli_inbox.dart) routes to bin/fah_hub_plugin.dart
  // `_hasPendingHubMail`, which reads the hub plugin's IN-MEMORY inbox
  // map (fah_hub_client HubMessagingRepository._inboxes) — there is no
  // on-disk inbox to list. The observable plugin state under the test
  // home is ~/.dap (identity keys, config); dump it verbatim.
  try {
    final dapDir = Directory('${home.path}/.dap');
    if (!dapDir.existsSync()) {
      printOnFailure('plugin state: ${dapDir.path} does not exist');
    } else {
      printOnFailure('plugin state under ${dapDir.path}:');
      final entries = dapDir.listSync(recursive: true).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        final kind = entity is Directory ? 'dir ' : 'file';
        final size = entity is File ? entity.lengthSync() : 0;
        final rel = entity.path.substring(dapDir.path.length + 1);
        printOnFailure('  $kind $rel (${size}B)');
      }
    }
  } on Object catch (error) {
    printOnFailure('plugin state dump failed: $error');
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
      printOnFailure('session tail (${lines.length} lines, last 6):');
      for (final line in lines.skip(lines.length - 6)) {
        printOnFailure(
          '  ${line.length > 240 ? '${line.substring(0, 240)}…' : line}',
        );
      }
    }
    final counts = <String, int>{};
    var messageRecords = 0;
    for (final file in files) {
      for (final line in await file.readAsLines()) {
        if (line.isEmpty) continue;
        Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on Object {
          counts.update('unparsable', (n) => n + 1, ifAbsent: () => 1);
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;
        final recordType = decoded['type'];
        if (recordType != 'message') {
          counts.update('$recordType', (n) => n + 1, ifAbsent: () => 1);
          continue;
        }
        messageRecords++;
        final message = decoded['message'] as Map<String, dynamic>?;
        final role = message?['role'];
        if (role == 'user' || role == 'toolResult') {
          counts.update(role, (n) => n + 1, ifAbsent: () => 1);
        } else if (role == 'assistant') {
          final blockTypes = <String>{
            for (final block in (message?['content'] as List? ?? const []))
              if (block is Map<String, dynamic>)
                block['type'] as String? ?? '?',
          };
          if (blockTypes.contains('toolCall')) {
            counts.update('toolCall', (n) => n + 1, ifAbsent: () => 1);
          }
          if (blockTypes.contains('text')) {
            counts.update('assistant-text', (n) => n + 1, ifAbsent: () => 1);
          }
          if (blockTypes.isEmpty) {
            counts.update('assistant-empty', (n) => n + 1, ifAbsent: () => 1);
          }
        } else {
          counts.update('other:$role', (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    printOnFailure(
      'session records: ${files.length} file(s), $messageRecords message '
      'records — '
      '${counts.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
    );
  } on Object catch (error) {
    printOnFailure('session dump failed: $error');
  }
  final ansi = RegExp('\x1B\\[[0-9;?]*[ -/]*[@-~]');
  final clean = harness.rawOutput.replaceAll(ansi, '');
  final lines = clean
      .split('\n')
      .map(
        (line) =>
            line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
      )
      .toList();
  final mailLines = [
    for (final line in lines)
      if (line.contains('[mail]')) line,
  ];
  printOnFailure(
    '[mail] total: ${mailLines.length}, '
    'dap_dm count: ${RegExp(r'\[dap_dm\] done').allMatches(clean).length}',
  );
  printOnFailure('[mail] first 3:');
  for (final line in mailLines.take(3)) {
    printOnFailure('  $line');
  }
  if (mailLines.length > 8) {
    printOnFailure('[mail] … ${mailLines.length - 8} more …');
  }
  printOnFailure('[mail] last 5:');
  for (final line in mailLines.skip(
    mailLines.length > 5 ? mailLines.length - 5 : 0,
  )) {
    printOnFailure('  $line');
  }
}

void main() {
  test(
    'a steered hub chatter loop must not wedge the run forever: the run '
    'settles and later typed input submits',
    timeout: timeout,
    () async {
      final provider = LoopMockProvider();
      await provider.start();
      final hub = FakeHub();
      await hub.start();

      final home = await Directory.systemTemp.createTemp('fah-loop-repro-');
      addTearDown(() async {
        await home.delete(recursive: true);
      });

      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': home.path,
          'OPENAI_API_KEY': 'mock-key',
          'DAP_HUB_URL': hub.url.toString(),
          'DAP_MASTER_SECRET': 'test-master',
          'DAP_AGENT_NAME': 'loop_cli',
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

      // The looping peer: answers EVERY inbound DM with the next number,
      // which the mock bounces back as another dap_dm — the closed loop.
      var counter = 0;
      final peer = HubClient(
        config: HubConfig(url: hub.url.toString(), name: 'loop_peer'),
        identity: await HubIdentity.generate(),
      );
      peer.inbound.listen((message) {
        if (message.channel != null) return; // DMs only
        counter++;
        unawaited(peer.sendDm(cliAgentId, 'сообщение #$counter — ответь'));
      });
      await peer.connect();
      addTearDown(peer.disconnect);
      addTearDown(hub.stop);
      addTearDown(provider.stop);

      // Prime the loop with one DM; the chatter then sustains itself.
      await peer.sendDm(cliAgentId, 'сообщение #1 — ответь');

      // Let the loop spin — a wedged run churns here forever.
      await Future<void>.delayed(const Duration(seconds: 20));

      // CONTRACT 1: the chatter must die — the busy row disappears (the
      // run settled; the inbox wake-streak cap finishes the tail).
      final idleDeadline = DateTime.now().add(const Duration(seconds: 45));
      var idle = false;
      while (DateTime.now().isBefore(idleDeadline)) {
        final screen = harness.screenText;
        if (!screen.contains('Working') && !screen.contains('⠧')) {
          idle = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final screenDump = harness.screenText;
      if (!idle) {
        await _dumpWedgeDiagnostics(harness, home, 0);
        printOnFailure('CONTRACT-2: not executed (run never settled)');
      }
      expect(
        idle,
        isTrue,
        reason:
            'the chatter run never settled; '
            'screen tail: …${screenDump.substring(screenDump.length - 400)}',
      );

      // CONTRACT 2: after settling, a typed line submits and is answered
      // (by now the chatter is dead, so this user message is the only
      // pending one — the mock answers it with plain text).
      var contract2 = 'not executed';
      try {
        harness.sendText('СТОП #999');
        await harness.waitForOutput(settleMs: 300);
        harness.sendEnter();
        await harness.waitForText(
          'Ответ #999.',
          timeout: const Duration(seconds: 30),
        );
        contract2 = 'submitted and answered (Ответ #999. seen within 30s)';
      } on Object catch (error) {
        contract2 = 'FAILED: $error';
        rethrow;
      } finally {
        printOnFailure('CONTRACT-2 (typed input submits): $contract2');
      }
    },
  );
}
