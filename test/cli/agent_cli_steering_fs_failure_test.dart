import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A fake env whose SESSION-file writes can be failed wholesale or held
/// in flight on demand — the #2248 fs-wedge rig for the steering
/// persistence suites (issue #2249). Boot completes normally; the gates
/// arm after, so the injected wedge pins exactly the steering
/// accept-append path. Non-session writes always pass through.
final class _SteeringFsGateEnv implements ExecutionEnv, RenamableFileSystem {
  _SteeringFsGateEnv(this._delegate);

  final MemoryExecutionEnv _delegate;

  /// When non-null, every steering accept-append parks for this long
  /// before proceeding — the deterministic in-flight persist (issue
  /// #2249 AC3). Bounded on purpose: a parked write holds the session
  /// file lock (the windowed storage serializes writers), so an
  /// UNBOUNDED hold would starve every other writer of the file — a new
  /// wedge class the card explicitly forbids.
  Duration? holdSessionWrites;

  /// When true, every steering accept-append fails — the #2248
  /// `Cannot open file` wedge shape (issue #2249 AC1/AC2).
  bool failSessionWrites = false;

  /// Only the STEERING record writes are gated. Gating the whole
  /// session IO would wedge the run's own end-of-run persist — a new
  /// wedge class, exactly what the card forbids; the #2249 defect is
  /// the steering accept-append path alone.
  bool _isSteeringWrite(String path, String content) =>
      path.startsWith('/sessions/') &&
      content.contains('"customType":"steering"');

  Future<void> _gate() async {
    final hold = holdSessionWrites;
    if (hold != null) await Future<void>.delayed(hold);
  }

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _delegate.renamePath(from, to);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    if (_isSteeringWrite(path, content)) {
      await _gate();
      if (failSessionWrites) {
        return Err(FileError(FileErrorCode.unknown, 'injected fs failure'));
      }
    }
    return _delegate.writeFile(path, content);
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    if (_isSteeringWrite(path, content)) {
      await _gate();
      if (failSessionWrites) {
        return Err(FileError(FileErrorCode.unknown, 'injected fs failure'));
      }
    }
    return _delegate.appendFile(path, content);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}

/// A stream function that blocks one chosen call on a gate (copied from
/// the busy-gate test): the deterministic way to hold a run open while
/// the test steers mid-run input.
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      final token = cancelToken;
      unawaited(() async {
        // Stream the first bytes BEFORE gating (the #1923 contract):
        // bytes flowing means the stream is productive, so a queued
        // steer keeps waiting for the boundary/settle instead of
        // triggering the provider-phase steering interrupt — the #2248
        // productive-then-silent shape these suites need.
        final empty = testAssistant();
        final partial = testAssistant(content: const [TextContent(text: 'st')]);
        stream
          ..push(StartEvent(partial: empty))
          ..push(TextStartEvent(contentIndex: 0, partial: empty))
          ..push(
            TextDeltaEvent(contentIndex: 0, delta: 'st', partial: partial),
          );
        await gate.future;
        emit(
          (token?.isCancelled ?? false) ? _abortedTurn() : turns.removeAt(0),
        );
      }());
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// An aborted completion (the provider-contract abort surface).
List<AssistantMessageEvent> _abortedTurn() {
  final empty = testAssistant();
  final partial = testAssistant(
    content: const [TextContent(text: '')],
    stopReason: StopReason.aborted,
  );
  return [
    StartEvent(partial: empty),
    DoneEvent(reason: StopReason.aborted, message: partial),
  ];
}

/// Waits for the CLI to persist its session (boot complete).
Future<void> waitForSessions(ExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

/// The persisted steering records of the first session, in file order.
Future<List<CustomRecord>> steeringRecords(ExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomRecord && record.customType == 'steering') record,
  ];
}

/// The persisted steering text of a steering record.
String steeringText(CustomRecord record) =>
    (record.data as Map)['text'] as String;

/// The steering-consumed custom records of the first session.
Future<List<CustomRecord>> consumedMarkers(ExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomRecord && record.customType == 'steering_consumed')
        record,
  ];
}

/// Issue #2249: steering persistence under fs failure — the banner must
/// not promise "saved to session" the append did not keep, the esc-drop
/// must not silently destroy the last carrier, and the leftover settle
/// must match the FIFO by IDENTITY so same-text steers keep their
/// consumed markers.
///
/// - AC1: a failed accept-append announces `NOT saved (fs error: …)` and
///   the stall banner never claims a save; the next delivery attempt
///   re-attempts the persist exactly once (bounded — no wedge feeding).
/// - AC2: the esc-drop prints the dropped text verbatim when no record
///   carries it; a healed fs re-attempt lands the record + consumed
///   marker (no resurrection).
/// - AC3: same-text double-steer + settle race keeps one consumed marker
///   per steer — no double delivery after restart.
void main() {
  late MemoryExecutionEnv memoryEnv;
  late _SteeringFsGateEnv env;
  late FakeCliIO io;

  setUp(() {
    memoryEnv = MemoryExecutionEnv(cwd: '/work');
    env = _SteeringFsGateEnv(memoryEnv);
    io = FakeCliIO();
  });

  tearDown(() async {
    await io.close();
  });

  AgentCli buildCli(
    _GatedStream stream, {
    Duration steeringStaleAfter = const Duration(minutes: 2),
    String? sessionName,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 128000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        steeringStaleAfter: steeringStaleAfter,
        sessionName: sessionName,
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  test(
    'AC1: a failed steering accept-append announces NOT saved, the stall '
    'banner never claims a save, and delivery re-attempts the persist '
    'once',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(
        stream,
        steeringStaleAfter: const Duration(milliseconds: 80),
      );
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // Outlast the stale threshold: the accept rides the wedged path
      // (the #2248 shape — the banner prints while the fs is dead).
      await Future<void>.delayed(const Duration(milliseconds: 250));
      env.failSessionWrites = true;
      cli.steerForTest('hold this under fs failure');

      // The failure is announced with the raw injected error — the
      // swallow is gone.
      await io.out.waitUntilContains(
        'NOT saved to session',
        reason: 'the failed accept-append surfaces instead of swallowing',
      );
      final out = io.out.toString();
      expect(out, contains('fs error: '));
      // The stall banner names the DELIVERY truth, never a save claim
      // the fs refused.
      expect(out, contains('1 steering message queued'));
      expect(out, isNot(contains('saved to the session')));
      // No record landed while the wedge holds.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await steeringRecords(env), isEmpty);

      // The fs heals; the boundary delivery re-attempts the persist
      // exactly once and it lands — recovery attribution restored.
      env.failSessionWrites = false;
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      await waitForIt(
        () async => (await steeringRecords(env)).length == 1,
        reason: 'the healed fs lands the record at the delivery attempt',
      );
      expect(await consumedMarkers(env), hasLength(1));
      expect(
        io.out.toString(),
        contains('[btw] steering from you → delivered'),
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC2: an esc-drop with a failed persist prints the dropped text '
    'verbatim — the message is never silently destroyed',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const text = 'the esc drop must print me verbatim';
      final stream = _GatedStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      env.failSessionWrites = true;
      cli.steerForTest(text);
      await io.out.waitUntilContains('NOT saved to session');

      // The esc path: abort drops the leftover steering loudly.
      io.interrupt();
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);

      final out = io.out.toString();
      expect(out, contains('dropped steering was NOT saved to session'));
      // The raw injected failure rides the fs error clause (#2248 raw
      // surfacing) — wrapped by the session layer, never swallowed.
      expect(out, contains('fs error: '));
      expect(out, contains('injected fs failure'));
      expect(out, contains('the text is lost'));
      // The FULL text, verbatim — what was lost is exactly readable.
      expect(out, contains('  • [steering from user] $text'));
      expect(out, contains('[btw] steering from you → aborted'));
      // The text is in no carrier: no steering record ever landed, and
      // the drop wrote no marker against a nonexistent one.
      expect(await steeringRecords(env), isEmpty);
      expect(await consumedMarkers(env), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        stream.calls,
        1,
        reason: 'dropped steering must not start a new run',
      );

      env.failSessionWrites = false;
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC2 border: an fs failure that heals before the esc-drop lands the '
    'record via the bounded drop retry and writes the consumed marker — '
    'no resurrection, no loss',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const text = 'failed then dropped after heal';
      final stream = _GatedStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // The accept-append FAILS (the #2248 wedge), the failure is
      // announced, and THEN the fs heals before the user hits esc.
      env.failSessionWrites = true;
      cli.steerForTest(text);
      await io.out.waitUntilContains('NOT saved to session');
      env.failSessionWrites = false;

      // The esc-drop: the bounded retry at drop lands the record and
      // closes it with the consumed marker — the text was carried, so
      // no lost-text print, and no resurrection on restart.
      io.interrupt();
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);

      final out = io.out.toString();
      expect(out, contains('[btw] steering from you → aborted'));
      expect(out, contains('dropped steering message(s) after interrupt:'));
      expect(
        out,
        isNot(contains('the text is lost')),
        reason: 'the healed fs landed the record at the drop retry',
      );
      await waitForIt(
        () async => (await steeringRecords(env)).length == 1,
        reason: 'the drop retry lands the record',
      );
      await waitForIt(
        () async => (await consumedMarkers(env)).length == 1,
        reason: 'the dropped record is consumed — no resurrection',
      );
      expect(
        (await consumedMarkers(env)).single.data as Map,
        containsPair('id', (await steeringRecords(env)).single.id),
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC3: two same-text steers settled after a restart keep ONE consumed '
    'marker per steer — the identity zip pairs them one-to-one and '
    'nothing re-delivers',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream, sessionName: 'fs-fail-ac3');
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // Two SAME-TEXT steers race the run settle: the settle's identity
      // zip must consume one FIFO entry per drained message object —
      // the old text matching collapsed the pair onto one text slot.
      cli.steerForTest('да');
      cli.steerForTest('да');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Restart affordance: aborts WITHOUT the drop flag, so the settle
      // re-runs the leftovers as a fresh turn. The gate releases the
      // parked provider call — the cancelled token surfaces as the
      // provider-contract aborted completion.
      cli.restartRunForTest();
      stream.gate.complete();
      await waitForIt(
        () => io.out.toString().contains(
          'steering arrived after the last checkpoint',
        ),
        reason: 'the settle ran the leftovers',
      );
      await waitForIt(() => stream.calls >= 2);
      // The fresh turn's prompt carries each steer exactly once.
      final runPrompt = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(runPrompt, contains('[steering from user] да'));
      expect(
        '[steering from user] да'.allMatches(runPrompt).length,
        2,
        reason: 'both steers ran, each exactly once',
      );
      expect(
        '→ delivered'.allMatches(io.out.toString()).length,
        greaterThanOrEqualTo(2),
        reason: 'each steer gets its own delivered transition',
      );
      await waitForIt(
        () async => (await steeringRecords(env)).length == 2,
        reason: 'both accept records landed',
      );
      await waitForIt(
        () async => (await consumedMarkers(env)).length == 2,
        reason: 'one consumed marker per steer, no lost marker',
      );
      final recordIds = (await steeringRecords(env)).map((r) => r.id).toSet();
      final markerIds = (await consumedMarkers(
        env,
      )).map((m) => (m.data as Map)['id']).toSet();
      expect(recordIds, hasLength(2));
      expect(
        markerIds,
        recordIds,
        reason: 'every record is closed by its own marker',
      );

      await waitForIt(() => !cli.isBusy, reason: 'the follow-up run settles');
      io.sendLine('/exit');
      await run;

      // Restart: both records are consumed — recovery must NOT wake the
      // agent into a double delivery.
      io = FakeCliIO();
      final stream2 = _GatedStream([textTurn('third answer')], gateOnCall: -1);
      final cli2 = buildCli(stream2, sessionName: 'fs-fail-ac3');
      final run2 = cli2.run();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(io.out.toString(), isNot(contains('[btw] recovered')));
      expect(stream2.calls, 0, reason: 'no wake — nothing left unconsumed');
      io.sendLine('/exit');
      await run2;
    },
  );

  test(
    'AC3: a same-text pair consumed at the boundary while their accept-'
    'appends are still in flight gets BOTH consumed markers once the '
    'appends resolve — the double-delivery regression',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer a'),
        textTurn('steered answer b'),
      ], gateOnCall: 1);
      final cli = buildCli(stream, sessionName: 'fs-fail-ac3b');
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // Both same-text accept-appends park IN FLIGHT for a bounded 2s.
      env.holdSessionWrites = const Duration(seconds: 2);
      cli.steerForTest('да');
      cli.steerForTest('да');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The run continues: each boundary drains ONE same-text steer by
      // OBJECT IDENTITY, consuming its entry with recordId == null (the
      // append is still parked). The pre-fix code skipped the consumed
      // marker forever on this path — the restart re-delivered the text.
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 3);
      expect(
        '→ delivered'.allMatches(io.out.toString()).length,
        greaterThanOrEqualTo(2),
        reason: 'both steers delivered at boundaries',
      );
      final steerCounts = [
        for (final context in stream.contexts.skip(1))
          '[steering from user] да'
              .allMatches(
                [
                  for (final message in context.messages)
                    if (message is UserMessage) messageText(message),
                ].join('\n'),
              )
              .length,
      ];
      // Contexts accumulate: boundary 1 merged steer #1, boundary 2 the
      // other — one same-text steer per boundary, never aliased.
      expect(steerCounts.take(2), [1, 2]);
      // The bounded hold elapses (the parked appends also release the
      // session file lock the boundaries serialize behind): the appends
      // land, and the resolution must close BOTH consumed entries with
      // their own markers — the ids only exist post-resolution, so
      // markers appearing here is the resolution path doing its job.
      await waitForIt(
        () async => (await steeringRecords(env)).length == 2,
        reason: 'both in-flight accept records landed',
      );
      await waitForIt(
        () async => (await consumedMarkers(env)).length == 2,
        reason: 'a consumed entry still gets its marker on resolution',
      );
      final recordIds = (await steeringRecords(env)).map((r) => r.id).toSet();
      final markerIds = (await consumedMarkers(
        env,
      )).map((m) => (m.data as Map)['id']).toSet();
      expect(
        markerIds,
        recordIds,
        reason: 'each same-text steer keeps its own consumed marker',
      );

      await waitForIt(() => !cli.isBusy, reason: 'the run settles');
      io.sendLine('/exit');
      await run;

      // Restart: everything consumed — no wake, no double delivery.
      io = FakeCliIO();
      final stream2 = _GatedStream([textTurn('third answer')], gateOnCall: -1);
      final cli2 = buildCli(stream2, sessionName: 'fs-fail-ac3b');
      final run2 = cli2.run();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(io.out.toString(), isNot(contains('[btw] recovered')));
      expect(stream2.calls, 0, reason: 'no wake — nothing left unconsumed');
      io.sendLine('/exit');
      await run2;
    },
  );
}
