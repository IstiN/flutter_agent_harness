import 'dart:async';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

Agent _createAgent(String modelId) {
  return Agent(
    model: Model(
      id: modelId,
      api: 'openai-completions',
      provider: 'openai-completions',
      baseUrl: 'https://api.test/v1',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    streamFunction: _singleTextResponse('ok'),
    toolRegistry: ToolRegistry(const []),
  );
}

/// `AgentService.loadSession` restores the session's OWN model: the last
/// `model_change` record at the leaf (every provider/model switch in the
/// CLI and the app appends one). The default chat model only applies to
/// NEW sessions.

/// fileInfo stalls until [release] completes: lets a test dispose the
/// service INSIDE the watcher's await gap (gh-2391 CI: the in-flight
/// `_checkSessionFileGrew` resumed after dispose and bumped
/// [AgentService.externalSessionRevision] on a dead notifier).
class _GatedEnv implements ExecutionEnv {
  _GatedEnv(this._inner);

  final MemoryExecutionEnv _inner;

  /// Null = pass-through; set by [arm] to stall the next fileInfo call
  /// until [release].
  Completer<void>? _gate;

  /// Stalls the NEXT fileInfo call (the watcher's in-flight check parks
  /// here — dispose happens while it waits).
  void arm() {
    _gate = Completer<void>();
  }

  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _gate = null;
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) {
    final gate = _gate;
    if (gate == null) return _inner.fileInfo(path);
    return gate.future.then((_) => _inner.fileInfo(path));
  }

  // The rest delegates verbatim (the service session paths below touch a
  // fixed, small member set).
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = false,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);

  @override
  Future<Result<void, FileError>> writeBinaryFile(String path, Uint8List c) =>
      _inner.writeBinaryFile(path, c);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);

  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) => _inner.readRange(path, start, end);

  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _inner.renamePath(from, to);

  @override
  String get cwd => _inner.cwd;

  Future<Result<void, FileError>> createFileExclusive(String path) async => Err(
    FileError(FileErrorCode.notFound, 'unsupported in the gated test env'),
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async => Err(
    ExecutionError(
      ExecutionErrorCode.shellUnavailable,
      'unsupported in the gated test env',
    ),
  );
}

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  AgentService service(String modelId) {
    return AgentService(
      agent: _createAgent(modelId),
      env: env,
      sessionsRoot: '/sessions',
    );
  }

  test('loadSession restores the effective model from model_change', () async {
    // Seed a service + session, then simulate a model switch by appending
    // a model_change record directly (what /model & reconfigure do).
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.open(meta);
    await session.appendModelChange(
      provider: 'openai-completions',
      modelId: 'session-model-x',
    );

    // A FRESH service with a different default model opens the session —
    // it must adopt the session's model, not keep its default.
    final opener = service('other-default');
    await opener.initialize();
    await opener.loadSession(meta);
    expect(
      opener.modelId,
      'session-model-x',
      reason: 'the session model_change model wins over the default',
    );
  });

  test('a cross-kind provider keeps the configured model (no crash)', () async {
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.open(meta);
    await session.appendModelChange(provider: 'anthropic', modelId: 'claude-x');

    final opener = service('my-default');
    await opener.initialize();
    await opener.loadSession(meta);
    // The provider kind does not match the connection — keep the default.
    expect(opener.modelId, 'my-default');
  });

  test('a session without model_change keeps the model it ran with', () async {
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;

    final opener = service('plain-default');
    await opener.initialize();
    await opener.loadSession(meta);
    // No model_change record, but the assistant messages carry the model
    // they were produced with — the session's own model still wins over
    // the opener's default.
    expect(opener.modelId, 'default-model');
  });

  test(
    'external appends to the session file reload into the transcript',
    () async {
      // The scenario: a `fa` CLI runs the SAME session while the app has it
      // open — its appends must appear without reopening the session.
      final seed = service('default-model');
      await seed.initialize();
      await seed.sendText('hello');
      await seed.waitForIdle();
      final meta = (await seed.listSessions()).single;

      final opener = service('default-model');
      await opener.initialize();
      await opener.loadSession(meta);
      final before = opener.messages.length;
      var revised = -1;
      opener.externalSessionRevision.addListener(() => revised++);

      // Let the watcher's FIRST tick establish its byte baseline before
      // the external append (the CLI would write much later in real usage).
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      // The CLI appends to the same session file (its own repo handle, the
      // way a real fa process writes) — a user turn plus an answer.
      final cliRepo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final cliSession = await cliRepo.open(meta);
      await cliSession.appendMessage(UserMessage.text('from the cli'));
      await cliSession.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'cli answer')],
          api: 'openai-completions',
          provider: 'openai-completions',
          model: 'default-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      );

      // The watcher polls every 2s; give it a couple of rounds.
      for (var i = 0; i < 40 && revised < 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        revised,
        greaterThanOrEqualTo(0),
        reason: 'external append bumped the revision',
      );
      expect(opener.messages.length, greaterThan(before));
      expect(
        opener.messages.any((m) => m.content.contains('from the cli')),
        isTrue,
        reason: 'the CLI-written user turn is visible',
      );
    },
  );

  test('a watcher tick that resumes after dispose never bumps the '
      'revision (no dead-notifier write)', () async {
    // Seed a session file with the plain env, then reopen it under the
    // gated env (the watcher arms itself on load).
    final seed = service('default-model');
    await seed.initialize();
    await seed.sendText('hello');
    await seed.waitForIdle();
    final meta = (await seed.listSessions()).single;

    final gated = _GatedEnv(env);
    final watchService = AgentService(
      agent: _createAgent('default-model'),
      env: gated,
      sessionsRoot: '/sessions',
    );
    await watchService.initialize();
    await watchService.loadSession(meta);
    // Tick 1 (fires ~2s in) establishes the byte baseline on the live
    // service (the gate is still pass-through).
    await Future<void>.delayed(const Duration(milliseconds: 2600));

    // Park the NEXT tick inside fileInfo BEFORE disposing it: the check
    // passes its entry (alive), stalls at the gate, and only resumes once
    // the service is disposed — exactly the gh-2391 CI window.
    gated.arm();
    await Future<void>.delayed(const Duration(milliseconds: 1800));

    // Append externally so the stalled tick, once resumed, SEES a growth.
    final cliRepo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final cliSession = await cliRepo.open(meta);
    await cliSession.appendMessage(UserMessage.text('from the cli'));

    var revised = -1;
    watchService.externalSessionRevision.addListener(() => revised++);

    // Dispose while the next tick is stalled inside fileInfo; release it
    // afterwards. A check resumed post-dispose must not write (reading
    // the notifier itself post-dispose throws — the listener flag is the
    // observable).
    watchService.dispose();
    gated.release();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      revised,
      -1,
      reason: 'the post-dispose tick must not bump the revision',
    );
  });
}
