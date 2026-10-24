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

import '../support/nwbgy7a_fixture.dart';

/// The task prompt IT-1 (and IT-2) replay: the requirements its
/// scripted ledger quotes verbatim.
const _fixtureTaskPrompt =
    'Fixture task: create script.py, make it executable, run it.';

/// The task prompt IT-3 replays: the requirements its scripted ledger
/// quotes verbatim. The gate contract calls a requirement/ledger
/// mismatch a protocol violation, so the replay's task text matches
/// what the ledger claims was asked for.
const _parityTaskPrompt =
    "Fixture task: create mean.sh that prints each station's mean "
    'temperature from stations.csv, and verify the output.';

/// The task prompt IT-4 replays (gh-1834): the requirements its scripted
/// ledger quote verbatim — the happy path AND both rejection rules.
const _conformanceTaskPrompt =
    'Fixture task: create tool.sh that uppercases the given file with '
    '--upper and lowercases it with --lower; the two flags are mutually '
    'exclusive and MUST be rejected together, and a missing file must '
    'error. Verify the happy path and both rejections.';

/// Produces the IT-4 fixture: tool.sh (the reference behavior: one of
/// --upper/--lower; the two are mutually exclusive — both together exit 2
/// with a refusal error; a missing file exits 3) plus its two-line
/// dataset. Raw string: the `\n` escapes must reach printf verbatim.
const _conformanceProduceCommand =
    r"printf '#!/usr/bin/env sh\n"
    r'mode=none\nfile=\n'
    r'for a in "$@"; do\n'
    r' case "$a" in\n'
    r'   --upper|--lower)\n'
    r'     if [ "$mode" != none ] && [ "$mode" != "$a" ]; then echo '
    r'"incompatible flags" >&2; exit 2; fi\n'
    r'     mode=$a ;;\n'
    r'   *) file=$a ;;\n'
    r' esac\n'
    r'done\n'
    r'[ -n "$file" ] || { echo usage >&2; exit 2; }\n'
    r'[ -f "$file" ] || { echo "missing file" >&2; exit 3; }\n'
    r'if [ "$mode" = upper ]; then tr "[a-z]" "[A-Z]" < "$file"; else '
    r'tr "[A-Z]" "[a-z]" < "$file"; fi\n'
    r"' > tool.sh && chmod +x tool.sh && printf 'Alpha\nbeta\n' > words.txt";

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

  /// Runs one scripted CLI session and returns every raw session JSONL line
  /// written under the run's session root. Headless (`fa -p` shape,
  /// `headlessRun: true`) is the unattended attendance the FinalizeGate
  /// keys on (gh-1516) — IT-1 exercises the full contract there; IT-2 pins
  /// the interactive REPL (any approval mode, autopilot included) staying
  /// gate-free. [prompt] is the task text the FinalizeGate ledger must
  /// quote verbatim — IT-3 overrides it so its task text matches its
  /// mean.sh ledger (a requirement/ledger mismatch is a gate violation).
  Future<List<String>> runScripted(
    ApprovalMode approvalMode,
    List<_Turn> script, {
    bool headless = false,
    String prompt = _fixtureTaskPrompt,
  }) async {
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
        headlessRun: headless,
      ),
      io: _HeadlessIo(),
    );
    if (headless) {
      final code = await cli.runHeadless(prompt);
      expect(code, 0);
    } else {
      final run = cli.run();
      // Drive the fixture prompt once the REPL is reading, then exit after
      // the script's last assistant turn has landed (each scripted POST
      // advances the mock's cursor).
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 300)).then((_) {
          _HeadlessIo.last?.sendLine(prompt);
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (mock.bodies.length < script.length &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      _HeadlessIo.last?.sendLine('/exit');
      await run.timeout(const Duration(seconds: 90));
    }
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

  List<Map<String, dynamic>> recordsOf(List<String> lines) => [
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
      ], headless: true);
      final records = recordsOf(lines);

      // AC3: the verification commands ACTUALLY executed — the session's
      // tool records show the check failing, the fix landing, and the
      // re-check passing (the loop is visible, not narrated).
      final transcript = const JsonEncoder.withIndent(' ').convert(records);
      expect(transcript, contains('test -x script.py'));
      expect(transcript, contains('chmod +x script.py'));
      expect(transcript.toLowerCase(), contains('exited with code 1'));

      // The produced state is correct: the fix landed on disk.
      final mode = File('${tempDir.path}/script.py').statSync().modeString();
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
      expect(
        [for (final item in items) (item as Map)['status']],
        ['pass', 'fixed', 'pass'],
      );
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
      final lines = await runScripted(
        // gh-1516: autopilot in an interactive REPL is attended — the
        // regression this ticket fixes.
        ApprovalMode.unattended,
        [
          const _Turn.toolCalls([
            (id: 'call_1', name: 'bash', arguments: 'echo interactive-run'),
          ]),
          const _Turn.text('done — no checklist'),
        ],
      );
      final records = recordsOf(lines);
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

  test('IT-3: the grader-parity check catches a cwd-dependent entry point '
      'before finalize (gh-1605)', () async {
    // The modernize-scientific-stack__nwbgy7a replay: a produced entry
    // point whose output depends on the CWD (it resolves its dataset
    // relatively). The scripted agent runs it in-session — the output
    // looks right — then re-runs it the way the verifier will (neutral
    // cwd) and watches Station 102 collapse to the stale fallback
    // value. The divergence must land in the persisted ledger as a
    // `fail` item BEFORE the run finalizes — not as a pass. The task
    // prompt names the same requirements the scripted ledger quotes
    // (_parityTaskPrompt) — a requirement/ledger mismatch is exactly
    // what the gate contract forbids.
    final appDir = '${tempDir.path}/app';
    final lines = await runScripted(
      ApprovalMode.unattended,
      [
        // Turn 1: build the fixture — dataset + stale bundled fallback +
        // the entry point that resolves the dataset via the CWD. The
        // fixture is the shared nwbgy7a evidence shape
        // (test/support/nwbgy7a_fixture.dart) — the REG scenarios in
        // test/agent/finalize_gate_grader_parity_test.dart write the very
        // same files from Dart.
        _Turn.toolCalls([
          (
            id: 'call_1',
            name: 'bash',
            arguments: 'mkdir -p app && cd app && ${nwbgy7aProduceCommand()}',
          ),
        ]),
        // Turn 2: the in-session verification — looks right (30.3).
        const _Turn.toolCalls([
          (id: 'call_2', name: 'bash', arguments: 'cd app && bash mean.sh'),
        ]),
        // Turn 3: the grader-parity re-run — neutral cwd, fresh
        // subprocess: the relative dataset resolves to the stale table.
        _Turn.toolCalls([
          (
            id: 'call_3',
            name: 'bash',
            arguments: 'cd / && bash $appDir/mean.sh',
          ),
        ]),
        // Turn 4: the final answer — the parity item reads `fail`, the
        // run does NOT claim the entry point verified.
        const _Turn.text(
          'Ran the parity check: divergence detected.\n'
          '```task-ledger\n'
          '- requirement: create mean.sh that prints each station\'s mean '
          'temperature from stations.csv\n'
          '  command: cd app && bash mean.sh\n'
          '  expected: Station 102 mean temperature: 30.3 C\n'
          '  actual: Station 102 mean temperature: 30.3 C\n'
          '  status: pass\n'
          '- requirement: '
          'grader parity: mean.sh output matches under a fresh cwd + '
          'clean env\n'
          '  command: cd / && bash <app>/mean.sh\n'
          '  expected: Station 102 mean temperature: 30.3 C\n'
          '  actual: Station 102 mean temperature: 15.5 C\n'
          '  status: fail\n'
          '```\n',
        ),
      ],
      headless: true,
      prompt: _parityTaskPrompt,
    );
    final records = recordsOf(lines);
    final transcript = const JsonEncoder.withIndent(' ').convert(records);

    // Both invocations actually executed — the in-session run and the
    // neutral-cwd parity re-run (the divergence is witnessed, not
    // narrated).
    expect(transcript, contains('cd app && bash mean.sh'));
    expect(transcript, contains('cd / && bash '));
    expect(transcript, contains('30.3'));
    expect(transcript, contains('15.5'));
    expect(
      transcript.contains(
        "prints each station's mean temperature "
        'from stations.csv',
      ),
      isTrue,
      reason: "the ledger quotes IT-3's task requirement verbatim",
    );

    // The persisted ledger carries the divergence as a `fail` item.
    final ledgerRecords = records
        .where(
          (record) =>
              record['type'] == 'custom' &&
              record['customType'] == 'task_ledger',
        )
        .toList();
    expect(ledgerRecords, hasLength(1));
    final items = (ledgerRecords.single['data'] as Map)['items'] as List;
    expect(
      [for (final item in items) (item as Map)['status']],
      ['pass', 'fail'],
    );
    expect(
      transcript.contains('Station 102 mean temperature: 15.5 C'),
      isTrue,
      reason: 'the ledger records the diverged parity output as actual',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('IT-4: a parity-style run quotes its negative + combination checks '
      'in the persisted ledger (gh-1834)', () async {
    // The gh-1834 shape: the task pins reference behavior including
    // REJECTION rules — the two flags are mutually exclusive and must
    // be refused together, a missing file must error. The scripted
    // agent runs the happy path AND the combination/negative probes,
    // and the final checklist quotes them: the persisted task_ledger
    // then carries the rejection rows with real commands, not just
    // happy paths (the gate's step 2.6 conformance coverage).
    final lines = await runScripted(
      ApprovalMode.unattended,
      [
        // Turn 1: produce the artifact + dataset. tool.sh implements the
        // reference behavior: --upper / --lower mutually exclusive (both
        // together exit 2), missing file exits 3.
        _Turn.toolCalls([
          (id: 'call_1', name: 'bash', arguments: _conformanceProduceCommand),
        ]),
        // Turn 2: the happy path.
        const _Turn.toolCalls([
          (
            id: 'call_2',
            name: 'bash',
            arguments: './tool.sh --upper words.txt',
          ),
        ]),
        // Turn 3: the combination probe — both flags must be refused.
        const _Turn.toolCalls([
          (
            id: 'call_3',
            name: 'bash',
            arguments: './tool.sh --upper --lower words.txt; echo rc=\$?',
          ),
        ]),
        // Turn 4: the negative probe — a missing file must error.
        const _Turn.toolCalls([
          (
            id: 'call_4',
            name: 'bash',
            arguments: './tool.sh --upper nope.txt; echo rc=\$?',
          ),
        ]),
        // Turn 5: the final checklist — the happy path AND both
        // rejection rows, each quoting its real command and outcome.
        const _Turn.text(
          'Happy path and both rejections verified.\n'
          '```task-ledger\n'
          '- requirement: create tool.sh that uppercases the given file '
          'with --upper and lowercases it with --lower\n'
          '  command: ./tool.sh --upper words.txt\n'
          '  expected: ALPHA\n'
          '  actual: ALPHA\n'
          '  status: pass\n'
          '- requirement: the two flags are mutually exclusive and MUST '
          'be rejected together\n'
          '  command: ./tool.sh --upper --lower words.txt; echo rc=\$?\n'
          '  expected: non-zero exit, refusal error\n'
          '  actual: rc=2, incompatible flags\n'
          '  status: pass\n'
          '- requirement: a missing file must error\n'
          '  command: ./tool.sh --upper nope.txt; echo rc=\$?\n'
          '  expected: non-zero exit\n'
          '  actual: rc=3, missing file\n'
          '  status: pass\n'
          '```\n',
        ),
      ],
      headless: true,
      prompt: _conformanceTaskPrompt,
    );
    final records = recordsOf(lines);
    final transcript = const JsonEncoder.withIndent(' ').convert(records);

    // The probes ACTUALLY executed — the combination refusal and the
    // missing-file error are witnessed tool results, not narration.
    expect(transcript, contains('./tool.sh --upper --lower words.txt'));
    expect(transcript, contains('./tool.sh --upper nope.txt'));
    expect(transcript, contains('rc=2'));
    expect(transcript, contains('rc=3'));
    expect(transcript, contains('incompatible flags'));

    // The persisted ledger carries the negative + combination rows:
    // the conformance checklist is not happy-path-only (AC3).
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
    expect(
      [for (final item in items) (item as Map)['status']],
      ['pass', 'pass', 'pass'],
    );
    expect(
      ((items[1] as Map)['command'] as String).contains('--upper --lower'),
      isTrue,
      reason: 'the combination check rides the persisted ledger',
    );
    expect(
      ((items[2] as Map)['command'] as String).contains('nope.txt'),
      isTrue,
      reason: 'the negative check rides the persisted ledger',
    );
    expect(
      transcript.contains(
        'the two flags are mutually exclusive and MUST be rejected '
        'together',
      ),
      isTrue,
      reason: 'the ledger quotes the rejection requirement verbatim',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
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
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    for (final chunk in _chunks(turn)) {
      request.response.write('data: $chunk\n\n');
    }
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }

  List<String> _chunks(_Turn turn) {
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
            'id': 'chatcmpl-tool',
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
                      'function': {
                        'arguments': jsonEncode({'command': call.arguments}),
                      },
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
  bool get isInteractive => true;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => const Stream<void>.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) {}

  @override
  void writeln(String text) {}

  void sendLine(String line) => _lines.add(line);
}
