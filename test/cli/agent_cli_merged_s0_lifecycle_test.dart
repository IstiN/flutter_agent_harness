// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 (E21) — gh-2407 review threads 1+6: the CLI host wiring
/// around the merged hand-over's S0 store must hold on the REAL host
/// path (not only the store unit tests): after a post-run merged pass
/// the request snapshot is INVALIDATED, so the next pre-flight selects
/// `standalone` (`selectCompactionMode` over `snapshotValid: false`) —
/// and the invalidation is UNCONDITIONAL: any run may have appended
/// (a ladder kill can land after the records were written), so a run
/// that reported NO pass still drops S0.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Window 12000, reserve 2000 → hard trigger 10000; keep-recent 2000.
/// One ~11k-token read pushes the transcript over the trigger (the
/// post-run hard funnel fires) while staying under the window (no
/// over-window relief noise).
///
/// gh-2423: the always-on working-set surface rides every request (see
/// [gh2423ContextIncludesTokens]), so the window grows by that measured
/// delta — the trigger moves with the overhead (the fixture's transcript
/// crosses it at the same point) and the over-the-window distance is
/// exactly what it was.
final _window = 12000 + gh2423ContextIncludesTokens;

Model get _tinyModel => Model(
  id: 'tiny-window',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

final _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

AssistantMessageEventStream _streamOf(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    // ~10.6k tokens: with the request overhead (~1.9k at the overhead
    // density, gh-2411 — the #2416 slim manifest shrank the seam's fixed
    // footprint, so the fixture grew to hold the same under-window band)
    // the transcript crosses the post-run trigger and stays UNDER the 12k
    // window — the post-run funnel fires, the over-window guard does not.
    env.writeFile('big1.txt', List.filled(1060, 'x' * 40).join('\n'));
  });

  tearDown(() => io.close());

  AgentCli buildCli(StreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      // gh-2411: overflow through messages, not overhead.
      systemPrompt: tinyPrompt,
      runtimeTools: tinyTools(const ['read']),
      model: _tinyModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionSettings: _settings,
    ),
    io: io,
    streamFunction: stream,
  );

  Future<Session> openSession() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    return repo.open(sessions.single);
  }

  test('E21: after a merged post-run pass the store is invalidated — the '
      'next pre-flight selects standalone', () async {
    final handOverCalls = <Context>[];
    AssistantMessageEventStream stream(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      if (isHandOverCall(context)) {
        handOverCalls.add(context);
        return _streamOf(
          textTurn(handOverReplyFor(context, text: 'checkpoint: counted')),
        );
      }
      final sentMainCalls = mainCallsOf(context);
      if (sentMainCalls == 1) {
        return _streamOf(
          toolTurn([
            ToolCall(id: 't1', name: 'read', arguments: {'path': 'big1.txt'}),
          ]),
        );
      }
      return _streamOf(textTurn('done: counted the words'));
    }

    final cli = buildCli(stream);
    final exitCode = await cli.runHeadless('count the words');
    expect(exitCode, 0, reason: io.out.toString());
    expect(handOverCalls, hasLength(1), reason: 'the merged hand-over ran');

    final entries = await (await openSession()).getEntries();
    expect(
      entries.whereType<CompactCheckpointRecord>(),
      isNotEmpty,
      reason: 'the merged pass appended the transfer checkpoint',
    );

    // E21 — the post-run hook invalidated S0: the next pre-flight's
    // mode table reads `snapshotValid: false` → standalone.
    final store = cli.agent.requestSnapshots;
    expect(store.current, isNull, reason: 'S0 must drop with the projection');
    expect(
      selectCompactionMode(
        engine: CompactionEngine.structured,
        snapshotValid: store.validFor(cli.agent.state.model) != null,
        separateDigestRole: false,
      ),
      CompactionMode.standalone,
    );
  });

  test('gh-2407 thread 1: a FAILED compaction run still invalidates S0 — '
      'the host cannot prove nothing appended', () async {
    AssistantMessageEventStream stream(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      if (isHandOverCall(context)) {
        // The merged call fails: the run reports NO pass, nothing is
        // appended — and the store still drops (any run may have
        // appended; the next send re-captures S0 anyway).
        throw StateError('hand-over backend down');
      }
      if (mainCallsOf(context) == 1) {
        return _streamOf(
          toolTurn([
            ToolCall(id: 't1', name: 'read', arguments: {'path': 'big1.txt'}),
          ]),
        );
      }
      return _streamOf(textTurn('done: counted the words'));
    }

    final cli = buildCli(stream);
    final exitCode = await cli.runHeadless('count the words');
    expect(exitCode, 0, reason: 'a failed compaction never kills the turn');

    final entries = await (await openSession()).getEntries();
    expect(entries.whereType<CompactCheckpointRecord>(), isEmpty);
    expect(entries.whereType<HiddenRangeRecord>(), isEmpty);

    // The old `if (hooks.reportedPass)` condition kept S0 here — the
    // exact gap the review flagged (a ladder kill can land AFTER the
    // appends; the host cannot distinguish the cases).
    final store = cli.agent.requestSnapshots;
    expect(store.current, isNull);
    expect(store.validFor(cli.agent.state.model), isNull);
  });
}

/// How many MAIN (agent-loop) requests [context] carries — 1-based
/// ordinal of the current call, 0 for the compaction-family calls that
/// the content routing answers before this helper.
int mainCallsOf(Context context) {
  final last = context.messages.lastOrNull;
  final isFirstMain =
      last is UserMessage &&
      messageText(last).contains('count the words') &&
      context.messages.length == 1;
  if (isFirstMain) return 1;
  return 2;
}
