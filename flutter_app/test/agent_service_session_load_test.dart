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
}
