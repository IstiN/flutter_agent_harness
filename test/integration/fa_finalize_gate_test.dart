// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1412 IT-1: the FinalizeGate end-to-end with the fake-agent harness —
/// a scripted mock-LLM "agent" runs the real CLI with REAL bash against a
/// fixture task, and deliberately "forgets" the executable bit first. The
/// run must persist a hidden `task_ledger` session record whose
/// verification commands actually executed (the `test -x` fail → fix →
/// re-verify loop is visible in the session tool records), and the
/// produced state must end up correct.
///
/// IT-2 half: the same harness under an interactive approval mode
/// persists NO ledger (the contract is unattended-only).
///
/// Real HTTP + real processes: tagged `integration`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;
  late _ScriptedMock mock;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('fa-finalize-gate-');
    tempDir = Directory(await tempDir.resolveSymbolicLinks());
    env = LocalExecutionEnv(cwd: tempDir.path);
    mock = _ScriptedMock();
    await mock.start();
  });

  tearDown(() async {
    await mock.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Runs one scripted CLI session headlessly and returns every raw session
  /// JSONL line written under the run's session root.
  Future<List<String>> runScripted(
    ApprovalMode approvalMode,
    List<_Turn> script,
  ) async {
    final sessionRoot = '${tempDir.path}/fah-sessions';
    mock.script = script;
    final cli = AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: 'test-model',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'http://127.0.0.1:${mock.port}/v1',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: sessionRoot,
        approvalMode: approvalMode,
      ),
      io: _HeadlessIo(),
    );
    final run = cli.run();
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300)).then((_) {
        _HeadlessIo.last?.sendLine(
          'Fixture task: create script.py, make it executable, run it.',
        );
      }),
    );
    await run.timeout(const Duration(seconds: 90));
    final lines = <String>[];
    final root = Directory(sessionRoot);
    if (root.existsSync()) {
      for (final entry in root.listSync(recursive: true)) {
        if (entry is File && entry.path.endsWith('.jsonl')) {
          lines.addAll(entry.readAsLinesSync().where((l) => l.isNotEmpty));
        }
      }
    }
    return lines;
  }

  List<Map<String, dynamic>> _records(List<String> lines) => [
    for (final line in lines)
      if (jsonDecode(line) case final Map<String, dynamic> record) record,
  ];

  test(
    'IT-1: the fix loop runs, the ledger records it, the state is correct',
    () async {
      final lines = await runScripted(ApprovalMode.unattended, [
        // Turn 1: create the script — deliberately WITHOUT the exec bit.
        const _Turn.toolCalls([
          (
            id: 'call_1',
            name: 'bash',
            arguments:
                "printf '#!/usr/bin/env python3\\nprint(\"hi\")\\n' > script.py",
          ),
        ]),
        // Turn 2: the FinalizeGate verification — the exec-bit check FAILS.
        const _Turn.toolCalls([
          (id: 'call_2', name: 'bash', arguments: 'test -x script.py'),
        ]),
        // Turn 3: the fix.
        const _Turn.toolCalls([
          (id: 'call_3', name: 'bash', arguments: 'chmod +x script.py'),
        ]),
        // Turn 4: re-verify — passes now.
        const _Turn.toolCalls([
          (id: 'call_4', name: 'bash', arguments: 'test -x script.py'),
        ]),
        // Turn 5: the final answer with the task ledger.
        const _Turn.text(
          'All requirements verified against the produced state.\n'
          '```task-ledger\n'
          '- requirement: create script.py with a shebang\n'
          '  command: test -f script.py && head -1 script.py\n'
          '  expected: shebang present\n'
          '  actual: shebang present\n'
          '  status: pass\n'
          '- requirement: script.py is executable\n'
          '  command: test -x script.py\n'
          '  expected: exit 0\n'
          '  actual: exit 0 after chmod +x (first check failed)\n'
          '  status: fixed\n'
          '- requirement: running script.py prints hi\n'
          '  command: ./script.py\n'
          '  expected: hi\n'
          '  actual: hi\n'
          '  status: pass\n'
          '```\n',
        ),
      ]);
      final records = _records(lines);

      // AC3: the verification commands ACTUALLY executed — the session's
      // tool records show the check failing, the fix landing, and the
      // re-check passing (the loop is visible, not narrated).
      final transcript = const JsonEncoder.withIndent(' ').convert(records);
      expect(transcript, contains('test -x script.py'));
      expect(transcript, contains('chmod +x script.py'));
      expect(transcript, contains('exit code 1'));

      // The produced state is correct: the fix landed on disk.
      final mode = File('${tempDir.path}/script.py').statSync().mode.valueString;
      expect(mode.contains('x'), isTrue, reason: 'script.py mode $mode');

      // AC2: exactly one hidden task_ledger record; the checklist covers
      // the task's explicit requirements; the forgotten exec bit reads as
      // `fixed` (the near-miss telemetry the bench summary consumes).
      final ledgerRecords = records
          .where(
            (record) =>
                record['type'] == 'custom' &&
                record['customType'] == 'task_ledger',
          )
          .toList();
      expect(ledgerRecords, hasLength(1));
      final items = (ledgerRecords.single['data'] as Map)['items'] as List;
      expect(items, hasLength(3));
      expect([for (final item in items) (item as Map)['status']], [
        'pass',
        'fixed',
        'pass',
      ]);
      expect(
        transcript.contains('create script.py with a shebang'),
        isTrue,
        reason: 'the ledger quotes the task requirements verbatim',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'IT-2: the same harness in interactive mode persists NO ledger',
    () async {
      final lines = await runScripted(ApprovalMode.yolo, [
        const _Turn.toolCalls([
          (id: 'call_1', name: 'bash', arguments: 'echo interactive-run'),
        ]),
        const _Turn.text('done — no checklist'),
      ]);
      final records = _records(lines);
      expect(
        records.where(
          (record) =>
              record['type'] == 'custom' &&
              record['customType'] == 'task_ledger',
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// One scripted assistant turn: tool calls or a final text answer.
class _Turn {
  const _Turn.toolCalls(this.calls) : text = null;

  const _Turn.text(this.text) : calls = null;

  final List<({String id, String name, String arguments})>? calls;
  final String? text;
}

/// A scriptable OpenAI-compatible SSE mock: POST #n replays script[n].
final class _ScriptedMock {
  HttpServer? _server;
  final List<String> bodies = [];

  /// The scripted turns; a run past the end replays a plain text turn.
  List<_Turn> script = const [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      try {
        await _handle(request);
      } on HttpException {
        // The CLI under test vanishing mid-request is part of the script.
      } on SocketException {
        // Same abort class (gh-1310).
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'object': 'list', 'data': []}));
      await request.response.close();
      return;
    }
    if (request.method != 'POST' ||
        !request.uri.path.endsWith('/chat/completions')) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await utf8.decoder.bind(request).join();
    bodies.add('x');
    final n = bodies.length - 1;
    final turn = n < script.length ? script[n] : const _Turn.text('done');
    request.response.headers.contentType = ContentType('text', 'event-stream');
    for (final chunk in _chunks(turn)) {
      request.response.write('data: $chunk\n\n');
    }
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }

  static List<String> _chunks(_Turn turn) {
    if (turn.text != null) {
      return [
        jsonEncode({
          'id': 'chatcmpl-text',
          'object': 'chat.completion.chunk',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': turn.text},
              'finish_reason': null,
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
        }),
      ];
    }
    final chunks = <String>[];
    for (var i = 0; i < turn.calls!.length; i++) {
      final call = turn.calls![i];
      chunks
        ..add(
          jsonEncode({
            'id': 'chatcmpl-$n',
            'object': 'chat.completion.chunk',
            'choices': [
              {
                'index': 0,
                'delta': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'index': i,
                      'id': call.id,
                      'type': 'function',
                      'function': {'name': call.name, 'arguments': ''},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add(
          jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [
                    {
                      'index': i,
                      'function': {'arguments': jsonEncode(call.arguments)},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          }),
        );
    }
    chunks.add(
      jsonEncode({
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
        ],
      }),
    );
    return chunks;
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

/// A minimal headless CliIO: feeds one prompt line, swallows output.
class _HeadlessIo implements CliIO {
  static _HeadlessIo? last;

  final _lines = StreamController<String>();

  _HeadlessIo() {
    last = this;
  }

  @override
  bool get isInteractive => false;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => const Stream<void>.empty();

  @override
  Stream<void> get keys => const Stream<void>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) {}

  @override
  void writeln(String text) {}

  void sendLine(String line) => _lines.add(line);
}
