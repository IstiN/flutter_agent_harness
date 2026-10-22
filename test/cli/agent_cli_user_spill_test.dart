// Issue #1760 — CLI driver tests for the user-message intake spill:
// an oversized interactive prompt is bounded before the request and the
// session (verbatim body on disk only), a mid-run accepted steer spills at
// ACCEPT while the delivery FIFO still consumes (the identity contract
// survives the guard), and the kill switches keep an oversized prompt
// byte-identical legacy.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An oversized prompt: 200000+ chars → estimate 50000+ tokens over the
/// 0.5 × (100000 − 16384) budget, and far past the 16384-byte floor.
final _prompt = 'task: digest this\n${'x' * 200000}';

/// The steering attribution prefix (agent_cli_steering.dart's
/// `steeringAttributionPrefix` — a library-private const there).
const _steeringAttributionPrefix = '[steering from user] ';

/// Small active config (all user knobs default: floor 16384 bytes,
/// fraction 0.5 of the live budget).
const _spills = SpillsConfig();

void main() {
  test('AC2: an oversized interactive prompt is bounded before the request; '
      'the verbatim body lives only in the spill file', () async {
    final rig = await _rig(turns: [textTurn('done')], spills: _spills);
    rig.io.sendLine(_prompt);
    await _settle(rig, 1, 'the spilled turn settles');
    await _exit(rig);

    // The request context carries the replacement, never the body.
    final sent = _lastUserText(rig.stream.contexts.last);
    expect(sent, contains('.fah/spills/'));
    expect(sent, contains('user-1.md'));
    expect(sent, contains('Read it in parts with the read tool'));
    expect(sent, isNot(contains(_prompt)));
    // The session record persists the replacement (spill note with the
    // path), never the raw body. The JSONL escapes newlines, so the
    // unescaped escape-free x-run is the honest raw-body probe.
    final jsonl = await _sessionJsonl(rig);
    expect(jsonl, isNot(contains('x' * 3000)));
    expect(jsonl, contains('user-1.md'));
    // The verbatim prompt is on disk at the #678 layout, byte-exact.
    expect(await _readText(rig.env, await _userSpillPath(rig, 1)), _prompt);
  });

  test('AC4: a mid-run accepted steer spills at accept and the delivery FIFO '
      'still consumes (the identity contract survives the guard)', () async {
    final stream = _GatedStream([
      textTurn('first answer'),
      textTurn('steered answer'),
    ], gateOnCall: 1);
    final rig = await _rig(stream: stream, turns: const [], spills: _spills);
    rig.io.sendLine('go');
    await waitForIt(() => stream.calls >= 1 && rig.cli.isBusy);
    await rig.cli.steerForTest(_prompt);

    // The accepted-steer record landed with the REPLACEMENT text (the
    // session never carries the raw body).
    await waitForItAsync(
      () async => (await steeringRecords(rig.env)).length == 1,
      reason: 'the steering record persisted at accept',
    );
    final record = (await steeringRecords(rig.env)).single;
    expect(steeringText(record), contains('user-1.md'));
    expect(steeringText(record), isNot(contains('x' * 3000)));
    // The spill file already exists at accept time — with the attribution
    // prefix (the verbatim text the model would have received).
    expect(
      await _readText(rig.env, await _userSpillPath(rig, 1)),
      "$_steeringAttributionPrefix$_prompt",
    );

    // Release the gate: the steer delivers at the boundary — the consumed
    // marker only fires when the FIFO's identical-object delivery worked.
    stream.gate.complete();
    await waitForItAsync(
      () async => (await consumedMarkers(rig.env)).length == 1,
      reason: 'the guarded steer delivered through the FIFO',
    );
    await _settle(rig, 2, 'the steered turn settles');
    await _exit(rig);

    // The steered request carried the bounded replacement too.
    final sent = _lastUserText(rig.stream.contexts.last);
    expect(sent, contains('user-1.md'));
    expect(sent, isNot(contains(_prompt)));
  });

  test('AC8 golden: absent spills, enabled:false and userThreshold:0 keep an '
      'oversized prompt byte-identical legacy', () async {
    final disabled = await _legacySessionJsonl(
      const SpillsConfig(enabled: false),
    );
    final absent = await _legacySessionJsonl(null);
    final userOff = await _legacySessionJsonl(
      const SpillsConfig(userThreshold: 0),
    );

    // Sanity: legacy keeps the oversized prompt inline in all three runs
    // (the escape-free x-run matches the JSONL content verbatim).
    expect(disabled, contains('x' * 3000));
    expect(disabled, absent);
    expect(disabled, userOff);
  });
}

/// A stream function that blocks one chosen call on a gate (the
/// deterministic way to hold a run open while the test steers mid-run).
class _GatedStream implements _StreamLike {
  _GatedStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  @override
  final contexts = <Context>[];

  @override
  int get calls => contexts.length;

  @override
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(gate.future.then((_) => emit(turns.removeAt(0))));
    } else if (turns.isEmpty) {
      stream.end();
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// One wired CLI run: in-memory env + scripted LLM, built exactly like the
/// #678 fixture (openai-completions, classic compaction, memory
/// maintenance suppressed). [stream] is either the plain replay fake or
/// the gated variant — both record contexts.
class _Rig {
  _Rig(this.env, this.io, this.stream, this.cli, this.run);

  final MemoryExecutionEnv env;
  final FakeCliIO io;
  final _StreamLike stream;
  final AgentCli cli;
  final Future<void> run;

  int get calls => stream.calls;

  List<Context> get contexts => stream.contexts;
}

abstract interface class _StreamLike {
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  });

  int get calls;

  List<Context> get contexts;
}

final class _PlainStream implements _StreamLike {
  _PlainStream(this._inner);

  final FakeStreamFunction _inner;

  @override
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) => _inner.call(model, context, cancelToken: cancelToken);

  @override
  int get calls => _inner.calls;

  @override
  List<Context> get contexts => _inner.contexts;
}

Future<_Rig> _rig({
  required List<List<AssistantMessageEvent>> turns,
  SpillsConfig? spills,
  _GatedStream? stream,
}) async {
  final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
  // Suppress session-start memory maintenance so the scripted turns feed
  // only the turn under test (same pattern as agent_cli_test).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final io = FakeCliIO();
  final resolved = stream ?? _PlainStream(FakeStreamFunction(turns));
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      spills: spills,
    ),
    io: io,
    streamFunction: resolved.call,
  );
  final run = cli.run();
  return _Rig(env, io, resolved, cli, run);
}

String _lastUserText(Context context) {
  for (final message in context.messages.reversed) {
    if (message is UserMessage) {
      final content = message.content;
      return content is String
          ? content
          : [
              for (final block in content as List<ContentBlock>)
                if (block is TextContent) block.text,
            ].join();
    }
  }
  fail('no user message in the captured context');
}

JsonlSessionRepo _repo(MemoryExecutionEnv env) =>
    JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');

Future<String> _readText(MemoryExecutionEnv env, String path) async {
  final result = await env.readTextFile(path);
  if (result.isErr) fail('reading $path failed: ${result.errorOrNull}');
  return result.valueOrNull!;
}

Future<String> _sessionJsonl(_Rig rig) async {
  final meta = (await _repo(rig.env).list(cwd: '/work')).single;
  return _readText(rig.env, meta.path);
}

/// The spill path for user-message spill [n], with the session id resolved
/// from the session file name.
Future<String> _userSpillPath(_Rig rig, int n) async {
  final sessionId = (await _repo(rig.env).list(cwd: '/work')).first.id;
  return '/work/.fah/spills/$sessionId/user-$n.md';
}

/// The persisted steering records of the first session (copied from the
/// #437 persistence suite).
Future<List<CustomRecord>> steeringRecords(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomRecord && record.customType == 'steering') record,
  ];
}

String steeringText(CustomRecord record) =>
    (record.data as Map)['text'] as String;

/// The steering-consumed custom records of the first session.
Future<List<CustomRecord>> consumedMarkers(MemoryExecutionEnv env) async {
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

/// Polls an async [condition] like [waitForIt]: 25s of 5ms polling.
Future<void> waitForItAsync(
  Future<bool> Function() condition, {
  String? reason,
}) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

Future<void> _settle(_Rig rig, int minCalls, String reason) => waitForIt(
  () => rig.stream.calls >= minCalls && !rig.cli.isBusy,
  reason: reason,
);

Future<void> _exit(_Rig rig) async {
  rig.io.sendLine('/exit');
  await rig.run;
  await rig.io.close();
}

/// Runs the oversized-prompt scenario once under [spills] (null = no
/// config section at all) and returns the session JSONL with the
/// run-varying ids and timestamps normalized away.
Future<String> _legacySessionJsonl(SpillsConfig? spills) async {
  final rig = await _rig(turns: [textTurn('done')], spills: spills);
  rig.io.sendLine(_prompt);
  await _settle(rig, 1, 'the legacy run settles');
  await _exit(rig);
  return _normalize(await _sessionJsonl(rig));
}

String _normalize(String jsonl) => jsonl
    .replaceAllMapped(
      RegExp(
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      ),
      (_) => 'UUID',
    )
    .replaceAllMapped(RegExp(r'"timestamp":"[^"]*"'), (_) => '"timestamp":"T"')
    .replaceAllMapped(RegExp(r'"timestamp":\d+'), (_) => '"timestamp":0')
    .replaceAllMapped(RegExp(r'"at":"[^"]*"'), (_) => '"at":"T"')
    .replaceAllMapped(
      RegExp(r'skills index scanned at [0-9T:.\-+]+Z'),
      (_) => 'skills index scanned at T',
    )
    .replaceAllMapped(
      RegExp(r'"([a-zA-Z]*[hH]ash)":"[0-9a-f]{8,}"'),
      (m) => '"${m.group(1)}":"H"',
    )
    .replaceAllMapped(
      RegExp(r'"(id|parentId)":"[0-9a-f]{8,}"'),
      (m) => '"${m.group(1)}":"X"',
    )
    .replaceAllMapped(
      RegExp(r'"systemPromptChars":\d+'),
      (_) => '"systemPromptChars":0',
    );
