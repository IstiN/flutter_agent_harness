// Issue #2117 — the console dial against a live AgentCli: the stall
// banner obeys the level gate (default warn hides the `info:` variant),
// `/log` switches live, and both sinks redact + level-tag their lines.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A stream that wedges the first call until aborted (the #514 harness).
AssistantMessageEventStream wedgedCall(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  unawaited(
    (cancelToken?.onCancel ?? Completer<void>().future).then((_) {
      stream
        ..push(
          ErrorEvent(
            reason: StopReason.aborted,
            error: testAssistant(
              stopReason: StopReason.aborted,
              errorMessage: 'Request was aborted',
            ),
          ),
        )
        ..end();
    }),
  );
  return stream;
}

const _wedgedModel = Model(
  id: 'test-model',
  api: 'openai-completions',
  provider: 'test-provider',
  baseUrl: 'https://llama.test/v1',
  contextWindow: 128000,
  maxTokens: 4096,
);

void main() {
  group('the stall banner obeys the console dial (issue #2117)', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
    });

    tearDown(() async {
      await io.close();
    });

    Future<AgentCli> boot({
      ResolvedLogSettings logging = const ResolvedLogSettings(),
      List<String> preLines = const [],
    }) async {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _wedgedModel,
          apiKey: 'sk-test',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          steeringStaleAfter: const Duration(milliseconds: 80),
          logging: logging,
        ),
        io: io,
        streamFunction: wedgedCall,
      );
      final run = cli.run();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await waitForIt(
        () async => (await repo.list(cwd: '/work')).isNotEmpty,
        reason: 'session persisted',
      );
      for (final line in preLines) {
        io.sendLine(line);
      }
      io.sendLine('start');
      await waitForIt(() => cli.isBusy, reason: 'run started');
      addTearDown(() async {
        try {
          io.sendLine('/exit');
          await waitForIt(() => !cli.isBusy, reason: 'run aborted on exit');
        } on Object {
          // The test already failed — never mask it with a teardown error.
        }
      });
      unawaited(run);
      return cli;
    }

    Future<void> wedge(AgentCli cli) async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cli.checkPendingSteeringHealthForTest();
    }

    test(
      'the interactive default (warn) hides the passive info variant',
      () async {
        final cli = await boot();
        await wedge(cli);

        expect(io.out.toString(), isNot(contains('agent stalled')));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('an explicit info config level shows it byte-for-byte', () async {
      final cli = await boot(
        logging: const ResolvedLogSettings(consoleLevel: LogLevel.info),
      );
      await wedge(cli);

      final out = io.out.toString();
      expect(out, contains('info: agent stalled — no response for'));
      expect(out, contains('/restart starts a fresh run, esc aborts'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('/log info switches the console sink live, no restart', () async {
      final cli = await boot(preLines: ['/log info']);
      await wedge(cli);

      expect(io.out.toString(), contains('log: console level info (was warn)'));
      expect(io.out.toString(), contains('info: agent stalled'));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('/log command (issue #2117 AC4)', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;
    late AgentCli cli;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
      cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'sk-test',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
    });

    tearDown(() async {
      await io.close();
    });

    test('bare /log prints the current level', () async {
      await cli.handleLineForTest('/log');
      expect(io.out.toString(), contains('log: console level warn'));
    });

    test('a valid level switches and reports the old one', () async {
      await cli.handleLineForTest('/log debug');
      expect(
        io.out.toString(),
        contains('log: console level debug (was warn)'),
      );
      await cli.handleLineForTest('/log');
      expect(io.out.toString(), contains('log: console level debug'));
    });

    test(
      'an invalid level answers loudly and keeps the current level',
      () async {
        await cli.handleLineForTest('/log verbose');
        expect(io.out.toString(), contains('/log must be one of'));
        await cli.handleLineForTest('/log');
        expect(io.out.toString(), contains('log: console level warn'));
      },
    );

    test('the switch actually gates subsequent lines', () async {
      await cli.handleLineForTest('/log off');
      cli.logConsoleForTest(LogLevel.warn, LogCategory.lifecycle, 'silenced');
      expect(io.out.toString(), isNot(contains('silenced')));
      await cli.handleLineForTest('/log debug');
      cli.logConsoleForTest(LogLevel.debug, LogCategory.tool, ' audible');
      expect(io.out.toString(), contains(' audible'));
    });
  });

  group('fa.log level tags, gate, and redaction (issue #2117 AC3/AC6)', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
    });

    tearDown(() async {
      await io.close();
    });

    Future<String> readLog() async =>
        (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

    Future<AgentCli> boot({
      ResolvedLogSettings logging = const ResolvedLogSettings(),
      RedactionPipeline? pipeline,
    }) async {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'sk-test',
          env: env,
          sessionRoot: '/sessions',
          homeDir: '/home',
          providerKind: 'openai-completions',
          logging: logging,
          redactionPipeline: pipeline,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
      io.sendLine('/exit');
      await run;
      return cli;
    }

    test('the default file shape gains ONLY the level tag', () async {
      final cli = await boot();
      cli.logDiagnosticForTest('burst line of one');
      await cli.flushDiagnosticLog();

      final log = await readLog();
      final line = log
          .split('\n')
          .where((l) => l.contains('burst line'))
          .single;
      expect(
        line,
        matches(
          RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+ info burst line of one$',
          ),
        ),
        reason: 'ISO timestamp + level tag + the untouched message',
      );
    });

    test(
      'the file gate drops below-level lines and keeps at-level ones',
      () async {
        final cli = await boot(
          logging: const ResolvedLogSettings(fileLevel: LogLevel.warn),
        );
        cli.logDiagnosticForTest('quiet info line');
        cli.logDiagnosticForTest('loud warn line', level: LogLevel.warn);
        await cli.flushDiagnosticLog();

        final log = await readLog();
        expect(log, isNot(contains('quiet info line')));
        expect(log, contains('loud warn line'));
      },
    );

    test('every rendered file line passes the redaction pipeline', () async {
      final cli = await boot(
        pipeline: RedactionPipeline(
          registeredSecrets: ['sk-supersecret-token-42'],
        ),
      );
      cli.logDiagnosticForTest('planted sk-supersecret-token-42 payload');
      await cli.flushDiagnosticLog();

      final log = await readLog();
      expect(log, isNot(contains('sk-supersecret-token-42')));
      expect(log, contains('[REDACTED:Registered-Secret]'));
    });

    test('a configured format renders the pattern on the file sink', () async {
      final cli = await boot(
        logging: const ResolvedLogSettings(
          format: LogPattern('F[{level}] {msg}'),
        ),
      );
      cli.logDiagnosticForTest('patterned');
      await cli.flushDiagnosticLog();

      expect((await readLog()), contains('F[info] patterned'));
    });

    test('the console sink redacts and formats (AC3 property)', () async {
      final cli = await boot(
        logging: const ResolvedLogSettings(
          consoleLevel: LogLevel.trace,
          format: LogPattern('{level}/{cat}: {msg}'),
        ),
        pipeline: RedactionPipeline(
          registeredSecrets: ['sk-supersecret-token-42'],
        ),
      );
      cli.logConsoleForTest(
        LogLevel.trace,
        LogCategory.provider,
        'raw sk-supersecret-token-42 payload',
      );

      final out = io.out.toString();
      expect(
        out,
        contains('trace/provider: raw [REDACTED:Registered-Secret] payload'),
      );
      expect(out, isNot(contains('sk-supersecret-token-42')));
    });

    test('the console gate (interactive default) hides info chatter', () async {
      final cli = await boot();
      cli.logConsoleForTest(LogLevel.info, LogCategory.lifecycle, 'chatter');
      cli.logConsoleForTest(LogLevel.warn, LogCategory.lifecycle, 'kept warn');
      final out = io.out.toString();
      expect(out, isNot(contains('chatter')));
      expect(out, contains('kept warn'));
    });
  });
}
