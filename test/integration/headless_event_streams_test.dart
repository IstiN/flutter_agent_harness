/// Headless structured-output E2E — stream-json + HEP v1 (gh-1730 CI fix).
///
/// The PTY/CLI integration leg is the ONLY runner whose coverage feeds the
/// `lib/src/cli` ratchet (`scripts/check_cli_coverage.py`), and neither
/// `--output-format stream-json` (issue #695) nor `--output events`
/// (issue #155) had any integration-taged suite — the headless event
/// writers measured 0% and the 18.42% ratchet red'd on run-to-run PTY
/// variance. This file drives the REAL [AgentCli.runHeadless] with both
/// writers (in-process, scripted turns + a real tool round-trip) and one
/// true subprocess boot of the CLI against the mock LLM server, pinning:
///
/// - stream-json: session header is the FIRST stdout line, `agent_settled`
///   the last, tool rounds visible as `tool_execution_start`/`end`, every
///   line valid NDJSON;
/// - HEP: `hep_header` first, ordered frame families, the terminal
///   `turn_done` carries the final answer text.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';
import 'pty_harness.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AgentCli _cliFor(StreamFunction streamFunction) => AgentCli(
  config: AgentCliConfig(
    model: _model,
    apiKey: '[REDACTED:Sensitive Value]',
    env: MemoryExecutionEnv(cwd: '/work'),
    sessionRoot: '/sessions',
  ),
  io: SplitChannelCliIO(),
  streamFunction: streamFunction,
);

void main() {
  group('stream-json headless run (issue #695, integration)', () {
    test(
      'session header first, tool round visible, agent_settled last',
      () async {
        final fake = FakeStreamFunction([
          toolTurn([
            ToolCall(
              id: 'c1',
              name: 'read',
              arguments: const {'path': 'notes.txt'},
            ),
          ]),
          textTurn('done reading'),
        ]);
        final lines = <String>[];
        final writer = StreamJsonWriter(emit: lines.add);

        final code = await _cliFor(
          fake.call,
        ).runHeadless('read notes.txt', streamJson: writer);

        expect(code, 0);
        expect(lines, isNotEmpty);

        final parsed = [
          for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
        ];
        // The session header is the first line of the stream and the run
        // settles last — the wire contract pi/claude-code consumers parse.
        expect(parsed.first['type'], 'session');
        expect(parsed.first['id'], isNotNull);
        expect(parsed.first['cwd'], '/work');
        expect(parsed.last['type'], 'agent_settled');
        expect(
          parsed.map((e) => e['type']),
          containsAllInOrder([
            'session',
            'agent_start',
            'tool_execution_start',
            'tool_execution_end',
            'agent_settled',
          ]),
        );
        // The tool round rides the stream with its call identity.
        final toolStart = parsed.firstWhere(
          (e) => e['type'] == 'tool_execution_start',
        );
        expect(toolStart['toolName'], 'read');
        expect(toolStart['toolCallId'], 'c1');
      },
    );
  });

  group('HEP v1 headless run (issue #155, integration)', () {
    test(
      'hep_header first, ordered frames, terminal turn_done answers',
      () async {
        final fake = FakeStreamFunction([
          toolTurn([
            ToolCall(
              id: 'c2',
              name: 'read',
              arguments: const {'path': 'notes.txt'},
            ),
          ]),
          textTurn('done reading'),
        ]);
        final frames = <String>[];
        final hep = HepWriter(emit: frames.add, fahVersion: 'test');

        final code = await _cliFor(
          fake.call,
        ).runHeadless('read notes.txt', hep: hep);

        expect(code, 0);
        expect(frames, isNotEmpty);

        final parsed = [
          for (final line in frames) jsonDecode(line) as Map<String, dynamic>,
        ];
        expect(parsed.first['type'], 'hep_header');
        expect(parsed.first['hep'], 'v1');
        expect(parsed.first['session'], isNotNull);
        expect(
          parsed.map((f) => f['type']),
          containsAllInOrder([
            'hep_header',
            'agent_start',
            'tool_start',
            'turn_done',
          ]),
        );
        final last = parsed.last;
        expect(last['type'], 'turn_done');
        expect(last['message'], 'done reading');
      },
    );
  });

  test('stream-json subprocess boot: stdout is pure NDJSON (mock server)', () async {
    final tempHome = Directory.systemTemp.createTempSync('stream_json_home_');
    addTearDown(() => tempHome.deleteSync(recursive: true));
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    final workspace = Directory.systemTemp.createTempSync('stream_json_ws_');
    addTearDown(() => workspace.deleteSync(recursive: true));

    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('plain stream reply');

    // Same convention as headless_log_file_test: temp HOME, --cwd, FA_BIN
    // AOT seam on CI (JIT fallback locally).
    final command = faCliCommand([
      '--provider',
      'openai-completions',
      '--base-url',
      server.baseUrl,
      '--model',
      'mock-model',
      '--cwd',
      workspace.path,
      '--output-format',
      'stream-json',
      '-p',
      'hi',
    ], jitPrefix: const ['dart', 'run', 'bin/fah.dart']);
    final result = await Process.run(
      command.first,
      command.sublist(1),
      workingDirectory: Directory.current.path,
      environment: {'OPENAI_API_KEY': 'mock', 'HOME': tempHome.path},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 8));

    expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');

    final lines = (result.stdout as String)
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    expect(lines, isNotEmpty);
    final parsed = [
      for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
    ];
    expect(parsed.first['type'], 'session');
    expect(parsed.last['type'], 'agent_settled');
    // Stdout carries ONLY the NDJSON stream — prose never leaks into it.
    expect(
      parsed.map((e) => e['type']),
      containsAllInOrder(['session', 'agent_start', 'agent_settled']),
    );
  });
}
