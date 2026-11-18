@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

/// Issue #2268 — per-turn approval grants must expire at EVERY run-start
/// boundary, not only when the user personally types a message.
///
/// AC1 (TDD): alwaysAsk mode; a skill with `allowed-tools: [bash]` settles;
/// a background-shell job settle while idle starts a notice run; that run's
/// bash call must hit the PROMPT path (pre-fix: the stale grant auto-allowed
/// it — the exact leak).
///
/// AC3 (REG): the armed skill's OWN run keeps its grants (bash auto-allows
/// mid-run, `disallowed-tools` denies within the run), the turn DENY never
/// leaks into the next run, and steering mid-run persists the active run's
/// grants (the steered settle notice is the SAME run).
///
/// AC2: grep guard — the shared `_startRun` funnel clears turn grants and
/// the only grant-carrying call site is the one that just armed them.
///
/// Fake-host determinism: MemoryExecutionEnv + FakeCliIO, no PTY.

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

const _promptMarker = '[approval] allow?';
const _noticeMarker = 'Background shell job ';

/// Routes every model call by STRICT CALL ORDER: runs are serialized (a
/// run-start refuses while busy), so the skill run's turns all precede any
/// fresh machine-started run's turns. A steered settle notice joins the
/// ACTIVE skill run (no new run, no new queue slot); content-based routing
/// cannot make that distinction — the transcript history of ANY later run
/// still carries the skill body marker.
class _RoutingStream {
  _RoutingStream({
    required List<List<AssistantMessageEvent>> skillTurns,
    required List<List<AssistantMessageEvent>> noticeTurns,
  }) : _skillTurns = List.of(skillTurns),
       _noticeTurns = List.of(noticeTurns);

  final List<List<AssistantMessageEvent>> _skillTurns;
  final List<List<AssistantMessageEvent>> _noticeTurns;
  final contexts = <Context>[];
  int _calls = 0;

  int get skillTurnCount => _skillTurns.length;

  /// Model calls that fell past the skill run's scripted turns — in these
  /// tests exactly the fresh machine-started notice runs (a steered notice
  /// consumes a skill-queue slot instead).
  int get freshNoticeCalls => contexts.length - _skillTurns.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final i = _calls++;
    final script = i < _skillTurns.length
        ? _skillTurns[i]
        : i - _skillTurns.length < _noticeTurns.length
        ? _noticeTurns[i - _skillTurns.length]
        : textTurn('unexpected-extra-call.');
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] + [BackgroundShell]: background jobs stay RUNNING until the
/// test finishes them. A foreground bash call inside a tool round rides the
/// yield-aware JOB path too — the run stays busy until its job settles, so
/// a test holds the run busy by simply finishing that job later.
class _ControllableShell implements Shell, BackgroundShell {
  final jobs = <_ControllableJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return Ok(
      ShellExecResult(stdout: 'ran: $command', stderr: '', exitCode: 0),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _ControllableJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _ControllableJob implements ShellJob {
  _ControllableJob({
    required this.id,
    required this.command,
    required this.logPath,
  });

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  int? _exitCode;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => _exitCode;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  @override
  Future<void> stop() async {
    _exitCode ??= 143;
    _settled.complete();
  }

  /// The test's settle trigger: the job exits with [code].
  void finish(int code) {
    if (_settled.isCompleted) return;
    _exitCode = code;
    _settled.complete();
  }
}

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// One env per test: the skills are seeded into and the CLI boots on the
  /// SAME in-memory filesystem, with the test's shell attached.
  Future<(MemoryExecutionEnv, _ControllableShell)> makeEnv({
    _ControllableShell? shell,
  }) async {
    final actualShell = shell ?? _ControllableShell();
    final env = MemoryExecutionEnv(cwd: '/work', shell: actualShell);
    // The deny-list tests read this file through the `read` tool.
    await env.writeFile('/work/notes.txt', 'hello');
    return (env, actualShell);
  }

  Future<void> seedSkill(
    MemoryExecutionEnv env,
    String name, {
    required String body,
    List<String> allow = const [],
    List<String> deny = const [],
  }) => env.writeFile(
    '/work/.fah/skills/$name/SKILL.md',
    '---\n'
        'name: $name\n'
        'description: test skill $name\n'
        '${allow.isEmpty ? '' : 'allowed-tools:\n${[for (final t in allow) '  - $t\n'].join()}'}'
        '${deny.isEmpty ? '' : 'disallowed-tools:\n${[for (final t in deny) '  - $t\n'].join()}'}'
        '---\n'
        '$body\n',
  );

  ToolCall bashCall(
    String command, {
    String id = 'tc-1',
    bool background = false,
  }) => ToolCall(
    id: id,
    name: 'bash',
    arguments: {'command': command, if (background) 'background': true},
  );

  ToolCall readCall(String path, {String id = 'tc-read'}) =>
      ToolCall(id: id, name: 'read', arguments: {'path': path});

  AgentCli cliFor(_RoutingStream stream, MemoryExecutionEnv env) {
    return AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.alwaysAsk,
        skillsAccess: SkillsAccess.granted,
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  group('AC1 — the grant expires at the next run boundary (TDD)', () {
    test('skill allowed-tools:[bash] settles; an idle job-settle notice run '
        'PROMPTs for bash (pre-fix: stale grant auto-allowed it)', () async {
      final (env, shell) = await makeEnv();
      await seedSkill(
        env,
        'deploy',
        body: 'DEPLOY-RUN-MARKER deploy the service',
        allow: ['bash'],
      );
      final stream = _RoutingStream(
        skillTurns: [
          toolTurn([
            bashCall('echo deploy-build', id: 'tc-bg', background: true),
          ]),
          textTurn('DEPLOYED-OK'),
        ],
        noticeTurns: [
          toolTurn([bashCall('echo deploy-status', id: 'tc-notice')]),
          textTurn('NOTICED-OK'),
        ],
      );
      final cli = cliFor(stream, env);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>deploy</name>'),
        reason: 'boot skill index',
      );

      // The skill's OWN run: the grant auto-allows the background bash —
      // no prompt (this half is the AC3 own-run REG too).
      io.sendLine('/skill:deploy');
      await io.out.waitUntilContains('DEPLOYED-OK');
      expect(
        io.out.toString().contains(_promptMarker),
        isFalse,
        reason: 'the armed grant auto-allows bash inside the skill run',
      );

      // The skill run settled; the background job outlives it. Settle it
      // while idle → _deliverJobNotice → the idle _startRun branch.
      await waitForIt(() => !cli.isBusy, reason: 'skill run settles');
      expect(shell.jobs, hasLength(1));
      shell.jobs.single.finish(0);

      // AC1: the notice run's bash call must PROMPT — the stale grant
      // must not govern a run the user never initiated.
      await io.out.waitUntilContains(_promptMarker, reason: 'AC1 prompt path');
      io.sendLine('y');
      // The approved foreground bash rides the yield-aware job path —
      // settle it so the notice run can finish.
      await waitForIt(
        () => shell.jobs.length == 2,
        reason: 'notice run bash job started',
      );
      shell.jobs[1].finish(0);
      await io.out.waitUntilContains('NOTICED-OK');
      expect(io.out.toString(), contains('✓ bash'));

      io.sendLine('/exit');
      await run;
    });
  });

  group('AC3 — deny lists apply within the run, never leak past it', () {
    test(
      'disallowed-tools denies inside the skill run, then expires',
      () async {
        final (env, shell) = await makeEnv();
        await seedSkill(
          env,
          'guarded',
          body: 'GUARDED-RUN-MARKER guarded work',
          allow: ['bash'],
          deny: ['read'],
        );
        final stream = _RoutingStream(
          skillTurns: [
            toolTurn([
              bashCall('echo guarded-build', id: 'tc-bg', background: true),
              readCall('/work/notes.txt'),
            ]),
            textTurn('GUARDED-DONE'),
          ],
          noticeTurns: [
            toolTurn([readCall('/work/notes.txt', id: 'tc-notice-read')]),
            textTurn('READ-AFTER-SETTLE-OK'),
          ],
        );
        final cli = cliFor(stream, env);
        final run = cli.run();
        await waitForIt(
          () => cli.systemPrompt.contains('<name>guarded</name>'),
          reason: 'boot skill index',
        );

        io.sendLine('/skill:guarded');
        await io.out.waitUntilContains('GUARDED-DONE');
        final out = io.out.toString();
        expect(
          out,
          contains('disallowed by the active skill'),
          reason: 'the turn deny blocks read inside the skill run',
        );
        expect(
          _promptMarker.allMatches(out),
          isEmpty,
          reason:
              'bash auto-allows (grant) and read denies (turn deny) — '
              'neither prompts inside the skill run',
        );

        // Settle the job while idle → fresh notice run. The stale DENY must
        // not block the read there: it prompts instead.
        await waitForIt(() => !cli.isBusy, reason: 'skill run settles');
        shell.jobs.single.finish(0);
        await io.out.waitUntilContains(_promptMarker, reason: 'deny expired');
        io.sendLine('y');
        await io.out.waitUntilContains('READ-AFTER-SETTLE-OK');
        expect(
          'disallowed by the active skill'.allMatches(io.out.toString()),
          hasLength(1),
          reason: 'the denial happened only inside the skill run',
        );

        io.sendLine('/exit');
        await run;
      },
    );
  });

  group('border cases', () {
    test('steering mid-run persists the active run\'s grants (a settle notice '
        'steered into the skill run is the SAME run)', () async {
      final (env, shell) = await makeEnv();
      await seedSkill(
        env,
        'deploy',
        body: 'DEPLOY-RUN-MARKER deploy the service',
        allow: ['bash'],
      );
      final stream = _RoutingStream(
        skillTurns: [
          toolTurn([
            bashCall('echo deploy-build', id: 'tc-bg', background: true),
            // A foreground call inside a tool round rides the yield-aware
            // JOB path: the run stays busy until its job settles.
            bashCall('echo long-deploy-step', id: 'tc-held'),
          ]),
          // Consumed AFTER the steered settle notice joined the run.
          textTurn('STEERED-AND-DONE'),
        ],
        noticeTurns: [textTurn('SHOULD-NOT-RUN')],
      );
      final cli = cliFor(stream, env);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>deploy</name>'),
        reason: 'boot skill index',
      );

      io.sendLine('/skill:deploy');
      // Both bash calls are jobs now; the run is blocked in the second
      // (the foreground hold) while the first keeps running detached.
      await waitForIt(
        () => shell.jobs.length == 2,
        reason: 'skill run blocked in its held deploy step; out=${io.out}',
      );

      // Settle the DETACHED job while the run is BUSY (blocked in the
      // hold) → the notice takes the steering queue (border case 1).
      // `steeringArrived` fires synchronously on enqueue — the proof the
      // notice registered against the still-busy run before release.
      final steerAccepted = cli.agent.steeringArrived.first;
      shell.jobs[0].finish(0);
      await steerAccepted.timeout(const Duration(seconds: 10));
      // Release the hold: the tool phase completes and the queued notice
      // is delivered at the step boundary — the SAME run continues.
      shell.jobs[1].finish(0);
      await io.out.waitUntilContains('STEERED-AND-DONE');
      expect(
        stream.contexts.last.messages.any(
          (m) => messageText(m).contains(_noticeMarker),
        ),
        isTrue,
        reason: 'the settle notice steered into the active run',
      );
      final out = io.out.toString();
      expect(out, contains('STEERED-AND-DONE'));
      expect(
        _promptMarker.allMatches(out),
        isEmpty,
        reason: 'the grant persisted through the mid-run steered notice',
      );
      expect(
        stream.freshNoticeCalls,
        0,
        reason: 'the steered notice joined the active run — no fresh run',
      );

      io.sendLine('/exit');
      await run;
    });
  });

  group('AC2 — grep guard: every _startRun entry point clears grants', () {
    test('the shared funnel clears, and only armed runs carry grants', () {
      // 1. The shared funnel itself clears leftover grants at entry.
      final inputSrc = File(
        'lib/src/cli/agent_cli_input.dart',
      ).readAsStringSync();
      final funnel = inputSrc.indexOf('void _startRun(');
      expect(
        funnel,
        greaterThanOrEqualTo(0),
        reason: '_startRun moved — update this guard',
      );
      final rest = inputSrc.substring(funnel + 10);
      final nextMember = RegExp(
        r'\n  (?:void|Future|String|bool|int|late|final|static)',
      ).firstMatch(rest);
      final body = inputSrc.substring(
        funnel,
        // _startRun may be the file's last member — clamp to EOF.
        nextMember == null ? inputSrc.length : funnel + 10 + nextMember.start,
      );
      expect(
        body,
        contains('clearTurnGrants()'),
        reason: 'every run start must expire leftover turn grants',
      );

      // 2. Enumerate the real call sites across the CLI part files.
      final codeLine = RegExp(r'^\s*(?://|\*|///)', multiLine: false);
      var callSites = 0;
      var carrySites = 0;
      var grantSites = 0;
      final filesWithCalls = <String>{};
      for (final entity in Directory('lib/src/cli').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        for (final line in src.split('\n')) {
          if (codeLine.hasMatch(line)) continue;
          if (line.contains('void _startRun(')) continue; // definition
          if (line.contains('_startRun(')) {
            callSites++;
            filesWithCalls.add(entity.path);
          }
          if (line.contains('carryTurnGrants: true')) carrySites++;
          if (line.contains('grantForTurn(')) grantSites++;
        }
      }
      expect(
        callSites,
        greaterThanOrEqualTo(12),
        reason: 'the enumeration itself must never go blind',
      );
      for (final expected in [
        'agent_cli_input.dart',
        'agent_cli_waiting.dart',
        'agent_cli_inbox.dart',
        'agent_cli_steering.dart',
        'agent_cli_run.dart',
        'agent_cli_lifecycle.dart',
        'approval_commands.dart',
        'agent_cli_commands.dart',
        'skill_commands.dart',
      ]) {
        expect(
          filesWithCalls.any((f) => f.endsWith(expected)),
          isTrue,
          reason: 'call-site enumeration lost $expected',
        );
      }

      // 3. The lockstep invariant: a run only carries grants when the very
      // same flow just armed them. One arm site ⇔ one carry site, and both
      // live inside `_runSkillCommand` — the arm and the run it starts.
      expect(
        grantSites,
        carrySites,
        reason:
            'grantForTurn arms and carryTurnGrants: true carries must stay in '
            'lockstep — an unaccompanied carry would silently carry stale '
            'grants into a new run',
      );
      final skillSrc = File(
        'lib/src/cli/skill_commands.dart',
      ).readAsStringSync();
      final methodStart = skillSrc.indexOf('Future<void> _runSkillCommand(');
      final methodEnd = RegExp(
        r'\n  [A-Za-z]',
      ).firstMatch(skillSrc.substring(methodStart + 30));
      final methodBody = skillSrc.substring(
        methodStart,
        methodStart + 30 + methodEnd!.start,
      );
      expect(
        methodBody,
        contains('grantForTurn('),
        reason: 'the arm must stay inside _runSkillCommand',
      );
      expect(
        methodBody,
        contains('carryTurnGrants: true'),
        reason: 'the only carry site must be the run the arm started',
      );
    });
  });
}
