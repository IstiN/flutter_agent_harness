import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

Agent _createAgent() {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: _singleTextResponse('ok'),
    toolRegistry: ToolRegistry(const []),
  );
}

/// A [SessionParseExecutor] whose FIRST parse parks on [gate] — the
/// in-flight open the generation guard must abandon — and parses every
/// later batch inline.
final class _GatedParseExecutor implements SessionParseExecutor {
  _GatedParseExecutor(this.gate);

  final Completer<void> gate;
  int calls = 0;

  @override
  Future<SessionParseResult> parse(SessionParseBatch batch) async {
    calls++;
    if (calls == 1) await gate.future;
    return parseSessionEntryLinesSync(batch);
  }
}

const _iso = '2026-01-01T00:00:00.000Z';

String _header(String id, String timestamp) =>
    '{"type":"session","version":3,"id":"$id","timestamp":"$timestamp",'
    '"cwd":"/work"}\n';

String _userMessage(String id, String text) =>
    '{"type":"message","id":"$id","parentId":null,"timestamp":"$_iso",'
    '"message":{"role":"user","content":[{"type":"text","text":'
    '"$text"}]}}\n';

String _sessionInfo(String id, String name) =>
    '{"type":"session_info","id":"$id","parentId":null,"timestamp":"$_iso",'
    '"name":"$name"}\n';

/// A [FileSystem] that fails the test the moment a session file is read
/// WHOLE (`readTextFile`/`readBinaryFile` — the full-open strategy) — the
/// "readSessionNames never full-opens" detector. Tail scans and header
/// peeks ride `readRange`/`readTextLines` and pass.
final class _NoFullReadFs implements FileSystem, RangedReadFileSystem {
  _NoFullReadFs(this.inner);

  final FileSystem inner;

  Never _refuse(String path) {
    throw StateError(
      'full open detected: whole-file read of $path '
      '(readSessionNames must use the tail scan only)',
    );
  }

  @override
  String get cwd => inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    if (path.endsWith('.jsonl')) _refuse(path);
    return inner.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    if (path.endsWith('.jsonl')) _refuse(path);
    return inner.readBinaryFile(path);
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    if (inner case final RangedReadFileSystem ranged) {
      return ranged.readRange(path, start, end);
    }
    return Err(
      FileError(FileErrorCode.notSupported, 'no ranged reads', path: path),
    );
  }

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => inner.remove(path, recursive: recursive, force: force);
}

void main() {
  test('loadSession generation guard: a stale open never lands its records',
      () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_generation');
    addTearDown(() => tmp.delete(recursive: true));
    // A is older, B newer; both small. A's parse parks on the gate.
    await io.File('${tmp.path}/a.jsonl').writeAsString(
      _header('session-a', '2026-01-01T00:00:00.000Z') +
          _userMessage('a1', 'alpha-old one') +
          _userMessage('a2', 'alpha-old two'),
    );
    await io.File('${tmp.path}/b.jsonl').writeAsString(
      _header('session-b', '2026-01-02T00:00:00.000Z') +
          _userMessage('b1', 'beta-new one') +
          _userMessage('b2', 'beta-new two'),
    );
    final gate = Completer<void>();
    final executor = _GatedParseExecutor(gate);
    final service = AgentService(
      agent: _createAgent(),
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(
        fs: LocalFileSystem(cwd: tmp.path),
        sessionsRoot: tmp.path,
        parseExecutor: executor,
      ),
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    await service.initialize();

    final sessions = await service.listSessions();
    final a = sessions.where((m) => m.id == 'session-a').single;
    final b = sessions.where((m) => m.id == 'session-b').single;

    // Start A's load and let it park inside the gated parse.
    final staleLoad = service.loadSession(a);
    for (var i = 0; i < 500 && executor.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(executor.calls, 1, reason: 'A open never reached the executor');

    // B's load supersedes A while A is parked; B must win completely.
    await service.loadSession(b);
    expect(service.currentSessionId, b.id);
    expect(
      service.messages.map((m) => m.content),
      everyElement(contains('beta-new')),
    );

    // Release A's parse: the stale loader abandons silently — no A record
    // ever lands in B's state.
    gate.complete();
    await staleLoad;
    await Future<void>.delayed(Duration.zero);
    expect(service.currentSessionId, b.id);
    expect(
      service.messages.where((m) => m.content.contains('alpha-old')),
      isEmpty,
    );
  });

  test('findReusableSession: windowed user scan, oversized refused', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    // Oldest: userless. Middle: has a user message (the newest at first).
    await env.writeFile(
      '/sessions/older.jsonl',
      _header('older', '2026-01-01T00:00:00.000Z'),
    );
    await env.writeFile(
      '/sessions/used.jsonl',
      _header('used', '2026-01-02T00:00:00.000Z') +
          _userMessage('u1', 'hello there'),
    );
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      repo: repo,
    );
    // Newest has a user message in the window → never auto-resumed.
    expect(await manager.findReusableSession(), isNull);

    // A newer userless session → resumed (window covers the whole file).
    await env.writeFile(
      '/sessions/empty.jsonl',
      _header('empty', '2026-01-03T00:00:00.000Z'),
    );
    final reused = await manager.findReusableSession();
    expect(reused?.id, 'empty');

    // Over the load budget → refused without reading it.
    final pickyManager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      repo: repo,
      maxSessionLoadBytes: 16,
    );
    expect(await pickyManager.findReusableSession(), isNull);
  });

  test('readSessionNames rides the quick tail scan, never a full open',
      () async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      '/sessions/named.jsonl',
      _header('named', '2026-01-01T00:00:00.000Z') +
          _sessionInfo('n1', 'Alpha'),
    );
    // The LAST session_info carries an empty name → the name is cleared.
    await env.writeFile(
      '/sessions/cleared.jsonl',
      _header('cleared', '2026-01-02T00:00:00.000Z') +
          _sessionInfo('c1', 'Temporary') +
          _sessionInfo('c2', ''),
    );
    // No session_info at all → no entry.
    await env.writeFile(
      '/sessions/anonymous.jsonl',
      _header('anonymous', '2026-01-03T00:00:00.000Z'),
    );
    final repo = JsonlSessionRepo(
      fs: _NoFullReadFs(env),
      sessionsRoot: '/sessions',
    );
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      repo: repo,
    );
    final sessions = await repo.list();
    final names = await manager.readSessionNames(sessions);
    final byId = {for (final s in sessions) s.id: s};
    expect(
      names,
      {byId['named']!.id: 'Alpha'},
      reason: 'cleared (empty last name) and anonymous contribute no entry',
    );
  });

  // -- Issue #1332: resume of a compacted session must not force-compact --
  //
  // The fixture window is 100000; the app wiring prices the 'You are Fa.'
  // system prompt at ceil(11/4) = 3 tokens, so conversationWindow = 99997
  // and the compaction trigger sits at 99997 - 16384 = 83613.

  // An assistant message record with optional provider usage (the
  // generation-time anchor the resume path must re-anchor).
  String assistantMessageLine(
    String id,
    String parentId,
    String text, {
    int? totalTokens,
  }) {
    final usage = totalTokens == null
        ? '{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}'
        : '{"input":${totalTokens - 4000},"output":4000,"cacheRead":0,"cacheWrite":0,"totalTokens":$totalTokens,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}';
    return '{"type":"message","id":"$id","parentId":"$parentId","timestamp":"$_iso",'
        '"message":{"role":"assistant","content":[{"type":"text","text":"$text"}],'
        '"api":"test-api","provider":"test","model":"test-model",'
        '"usage":$usage,"stopReason":"stop","timestamp":1767225600000}}\n';
  }

  String compactionRecordLine(
    String id,
    String parentId,
    String firstKeptEntryId,
    int tokensBefore,
  ) =>
      '{"type":"compaction","id":"$id","parentId":"$parentId","timestamp":"$_iso",'
      '"summary":"structured checkpoint of the earlier work",'
      '"firstKeptEntryId":"$firstKeptEntryId","tokensBefore":$tokensBefore}\n';

  String chainedUserLine(String id, String parentId, String text) =>
      '{"type":"message","id":"$id","parentId":"$parentId","timestamp":"$_iso",'
      '"message":{"role":"user","content":[{"type":"text","text":"$text"}]}}\n';

  String hiddenRangeLine(String id, String parentId, List<String> recordIds) =>
      '{"type":"hidden_range","id":"$id","parentId":"$parentId","timestamp":"$_iso",'
      '"recordIds":[${recordIds.map((r) => '"$r"').join(',')}]\n';

  test('resume of a compacted session re-anchors stale usage — no phantom '
      'force-compact (issue #1332)', () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_1332');
    addTearDown(() => tmp.delete(recursive: true));
    // The exact #1332 shape: a session whose last live run ended AT the
    // compaction trigger (the auto-compact appended the boundary record
    // right after the run's final assistant message), then suspended.
    // The final assistant's usage anchor reports the PRE-compaction
    // request (~102% of the window); the projection after the boundary
    // is tiny.
    const staleAnchorTokens = 102000; // 102% of the 100000 window
    await io.File('${tmp.path}/big.jsonl').writeAsString(
      _header('big', '2026-01-01T00:00:00.000Z') +
          chainedUserLine('u1', 'root', 'old big question one') +
          assistantMessageLine('a1', 'u1', 'old big answer one') +
          chainedUserLine('u2', 'a1', 'recent question') +
          assistantMessageLine(
            'a2',
            'u2',
            'recent answer',
            totalTokens: staleAnchorTokens,
          ) +
          compactionRecordLine('c1', 'a2', 'u2', staleAnchorTokens),
    );
    final agent = _createAgent();
    final service = AgentService(
      agent: agent,
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(
        fs: LocalFileSystem(cwd: tmp.path),
        sessionsRoot: tmp.path,
      ),
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    await service.initialize();

    final big = (await service.listSessions())
        .where((m) => m.id == 'big')
        .single;
    await service.loadSession(big);

    // The phantom basis WOULD force-compact: 102000 > 83613.
    final settings = CompactionSettings.forWindow(99997);
    expect(
      shouldCompact(staleAnchorTokens, 99997, settings),
      isTrue,
      reason: 'fixture sanity: the stale anchor reads over the trigger',
    );

    // The resumed meter reads the REAL projected context: the stale
    // anchor is gone, the estimate sits below the trigger — no
    // compaction fires on resume or on the first turn's gate.
    final meter = estimateRequestTokens(
      agent.state.messages,
      systemPrompt: agent.state.systemPrompt,
      tools: agent.state.tools,
    );
    expect(
      meter,
      lessThan(staleAnchorTokens),
      reason: 'the meter must not anchor at the phantom pre-compaction size',
    );
    expect(
      shouldCompact(meter, 99997, settings),
      isFalse,
      reason: 'a session that fit when suspended must resume under the trigger',
    );
    // The projection kept the kept-region records and folded the covered
    // region (no summary+source double-count).
    expect(
      agent.state.messages.map((m) => m.toString().contains('old big')),
      everyElement(isFalse),
    );
    expect(
      agent.state.messages.whereType<AssistantMessage>().last.usage.totalTokens,
      0,
      reason: 'loaded anchors are re-anchored at zero (CLI resume parity)',
    );

    // End to end: the first turn after resume must NOT compact — the run
    // completes, and no new compaction record lands in the session file.
    await service.sendText('next turn please');
    await service.waitForIdle();
    final fileText = await io.File('${tmp.path}/big.jsonl').readAsString();
    expect(
      'type":"compaction'.allMatches(fileText).length,
      1,
      reason: 'exactly the fixture compaction — resume + one turn added none',
    );
  });

  test('a session genuinely over-window on resume still reads over the '
      'trigger (issue #1332 AC3)', () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_1332_over');
    addTearDown(() => tmp.delete(recursive: true));
    // Kept region (~85k chars/4 tokens, u2+a2) genuinely exceeds the
    // trigger (83613) with NO stale anchor inflating it — the resume must
    // still read over-window so the compaction path stays armed.
    final bigText = 'x' * 170000;
    await io.File('${tmp.path}/over.jsonl').writeAsString(
      _header('over', '2026-01-01T00:00:00.000Z') +
          chainedUserLine('u1', 'root', 'old big question one') +
          assistantMessageLine('a1', 'u1', 'old big answer one') +
          chainedUserLine('u2', 'a1', bigText) +
          assistantMessageLine('a2', 'u2', bigText) +
          compactionRecordLine('c1', 'a2', 'u2', 200000),
    );
    final agent = _createAgent();
    final service = AgentService(
      agent: agent,
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(
        fs: LocalFileSystem(cwd: tmp.path),
        sessionsRoot: tmp.path,
      ),
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    await service.initialize();

    final over = (await service.listSessions())
        .where((m) => m.id == 'over')
        .single;
    await service.loadSession(over);

    final meter = estimateRequestTokens(
      agent.state.messages,
      systemPrompt: agent.state.systemPrompt,
      tools: agent.state.tools,
    );
    expect(
      shouldCompact(meter, 99997, CompactionSettings.forWindow(99997)),
      isTrue,
      reason: 'a genuinely over-window resume still trips the compaction gate',
    );
  });

  test('structured projection does not double-count the hidden region on '
      'resume (issue #1332 candidate 2)', () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_1332_struct');
    addTearDown(() => tmp.delete(recursive: true));
    // A structured-compacted branch: the big source records are hidden in
    // place. The resume must project markers, not replay the source
    // region under its checkpoint.
    final bigText = 'y' * 100000;
    await io.File('${tmp.path}/struct.jsonl').writeAsString(
      _header('struct', '2026-01-01T00:00:00.000Z') +
          chainedUserLine('u1', 'root', bigText) +
          assistantMessageLine('a1', 'u1', bigText) +
          hiddenRangeLine('h1', 'a1', ['u1', 'a1']) +
          chainedUserLine('u2', 'h1', 'recent question') +
          assistantMessageLine('a2', 'u2', 'recent answer'),
    );
    final agent = _createAgent();
    final service = AgentService(
      agent: agent,
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(
        fs: LocalFileSystem(cwd: tmp.path),
        sessionsRoot: tmp.path,
      ),
      watchExternalSessions: false,
    );
    addTearDown(service.dispose);
    await service.initialize();

    final struct = (await service.listSessions())
        .where((m) => m.id == 'struct')
        .single;
    await service.loadSession(struct);

    final meter = estimateRequestTokens(
      agent.state.messages,
      systemPrompt: agent.state.systemPrompt,
      tools: agent.state.tools,
    );
    // Double-counted raw replay would price ~50k tokens; the marker
    // projection prices a few dozen.
    expect(meter, lessThan(1000));
    expect(
      agent.state.messages.map((m) => m.toString().contains('yyyy')),
      everyElement(isFalse),
      reason: 'the hidden source region never replays into the context',
    );
  });
}
