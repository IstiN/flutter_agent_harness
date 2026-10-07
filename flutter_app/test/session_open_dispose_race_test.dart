// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #1319: `openSession`'s background history-count continuation
/// (`loadSession` → `unawaited(_refreshHistoryAbove)`) can resume AFTER the
/// test (or the app) has disposed the [AgentService] — a `notifyListeners`
/// on a dead ChangeNotifier, the "failed after test completion" CI crash.
/// The gated file system (the issue #1159 generation-race fixture) freezes
/// the count mid-flight, so the dispose-vs-continuation ordering here is
/// deterministic, not a timing flake.
library;

import 'dart:io' as io;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_service_windowed_test.dart' show GatedFileSystem;

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

/// A stream that stays open until the cancel token fires — the
/// agent_service_test `_hungResponse` pattern — so a run is genuinely in
/// flight when the test aborts it via [AgentService.reconfigure].
Agent _createHungAgent() {
  AssistantMessageEventStream hung(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: partial.copyWith(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream; // stays open until aborted
  }

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
    streamFunction: hung,
    toolRegistry: ToolRegistry(const []),
  );
}

final _config = AgentConfig(
  providerKind: 'test',
  modelId: 'test-model',
  baseUrl: 'https://example.com',
  apiKey: '',
);

/// Builds a session file body in one string (the windowed-suite pattern).
String _sessionBody(String id, int count) {
  const iso = '2026-01-01T00:00:00.000Z';
  final buffer = StringBuffer(
    '{"type":"session","version":3,"id":"$id","timestamp":"$iso",'
    '"cwd":"/work"}\n',
  );
  for (var i = 0; i < count; i++) {
    buffer.write(
      '{"type":"message","id":"e$i","parentId":'
      '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
      '"message":{"role":"user","content":[{"type":"text","text":'
      '"message $i with a bit of body to be realistic"}]}}\n',
    );
  }
  return buffer.toString();
}

AgentService _service(String cwd, FileSystem fs) {
  return AgentService(
    agent: _createAgent(),
    env: LocalExecutionEnv(cwd: cwd),
    sessionsRoot: cwd,
    repo: JsonlSessionRepo(fs: fs, sessionsRoot: cwd),
    watchExternalSessions: false,
    includeSharedSessionRoots: false,
  );
}

/// Deletes a temp dir tolerantly (the windowed-suite pattern).
Future<void> _deleteTmpDir(io.Directory tmp) async {
  Object? lastError;
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await tmp.delete(recursive: true);
      return;
    } on io.FileSystemException catch (e) {
      lastError = e;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  // ignore: only_throw_errors
  throw lastError!;
}

void main() {
  test('UT-dispose-race: disposing the service while the background history '
      'count is in flight does not notify the disposed notifier', () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_1319_race');
    addTearDown(() => _deleteTmpDir(tmp));
    await io.File(
      '${tmp.path}/big.jsonl',
    ).writeAsString(_sessionBody('big', 300));
    final gated = GatedFileSystem(
      LocalFileSystem(cwd: tmp.path),
      gatePath: 'big.jsonl',
    );
    final service = _service(tmp.path, gated);
    // No addTearDown(service.dispose): the body disposes it mid-test —
    // the crash ordering under test — and dispose is not idempotent.
    await service.initialize();

    final manager = FlutterSessionManager(
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(fs: gated, sessionsRoot: tmp.path),
      maxSessionLoadBytes: 1024,
      includeSharedSessionRoots: false,
    );
    final metadata = (await manager.listPersistedSessions()).single;

    // The windowed open reads big.jsonl freely (gate not armed yet). By
    // the time openSession resolves, the only remaining reader is the
    // unawaited history count — suspended inside its stat, about to hit
    // the first gated ranged read.
    final managed = await manager.openSession(
      metadata,
      config: _config,
      serviceFactory: () async => service,
    );
    expect(managed.service.messages, hasLength(200));

    // Freeze the count mid-flight, then tear the service down under it —
    // exactly the ordering of the CI crash ("failed after test
    // completion").
    gated.armGate();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.dispose();
    gated.releaseGate();

    // Let the continuation resume against the disposed service. On the
    // unpatched code `_notify()` throws "A AgentService was used after
    // being disposed"; the escaping async error fails this test.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('UT-dispose-race-paging: disposing the service while a page-in is '
      'in flight does not notify the disposed notifier', () async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_1319_page');
    addTearDown(() => _deleteTmpDir(tmp));
    await io.File(
      '${tmp.path}/big.jsonl',
    ).writeAsString(_sessionBody('big', 300));
    final gated = GatedFileSystem(
      LocalFileSystem(cwd: tmp.path),
      gatePath: 'big.jsonl',
    );
    final service = _service(tmp.path, gated);
    // No addTearDown(service.dispose): the body disposes it mid-test —
    // the crash ordering under test — and dispose is not idempotent.
    await service.initialize();

    final manager = FlutterSessionManager(
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(fs: gated, sessionsRoot: tmp.path),
      maxSessionLoadBytes: 1024,
      includeSharedSessionRoots: false,
    );
    final metadata = (await manager.listPersistedSessions()).single;
    final managed = await manager.openSession(
      metadata,
      config: _config,
      serviceFactory: () async => service,
    );
    expect(managed.service.messages, hasLength(200));

    // Freeze the next ranged read, then page older history in:
    // loadOlderHistory suspends inside windowed.loadOlder() with 100
    // records still above the tail window.
    gated.armGate();
    final pageIn = service.loadOlderHistory();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.dispose();
    gated.releaseGate();

    // The page-in continuation resumes against the disposed service and
    // still notifies from its tail (the gen guard passes — dispose never
    // bumps the generation). On the unpatched code the direct
    // notifyListeners() throws "used after being disposed" inside the
    // method, so `await pageIn` fails this test deterministically.
    await pageIn;
    // The continuation ran to its tail `_notify()`, not bailed at a guard:
    // the released gate lets windowed.loadOlder() pull the remaining 100
    // records (far under the chunk cap; the resident cap 600 > 300 keeps
    // the tail side from sliding), so the transcript ends at 300 rows. If
    // dispose() ever starts bumping _loadGeneration, the continuation
    // would bail at the gen guard without notifying — still crash-free,
    // but this assertion then forces the contract comment to be updated
    // instead of the test going vacuously green.
    expect(service.messages, hasLength(300));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test(
    'UT-dispose-race-reconfigure: disposing the service during the '
    'abort-drain does not notify the disposed notifier from reconfigure',
    () async {
      final tmp = await io.Directory.systemTemp.createTemp('fa_1319_reconf');
      addTearDown(() => _deleteTmpDir(tmp));
      final service = AgentService(
        agent: _createHungAgent(),
        env: LocalExecutionEnv(cwd: tmp.path),
        sessionsRoot: tmp.path,
        watchExternalSessions: false,
        includeSharedSessionRoots: false,
      );
      await service.initialize();

      // A run in flight: the stream stays open until an abort cancels it.
      final run = service.sendText('hi');
      for (var i = 0; i < 50 && !service.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.isStreaming, isTrue);

      // reconfigure aborts the run and suspends inside waitForIdle(); the
      // dispose lands inside that drain. The post-await notifyListeners()
      // at the tail of reconfigure() then fires on the dead notifier — on
      // the unpatched code `await switchOver` throws "A AgentService was
      // used after being disposed", failing this test deterministically.
      // The switch target is a real catalog kind (the same config shape as
      // agent_service_test's reconfigure test): reconfigure rebuilds the
      // stream function from the provider catalog, which 'test' is not.
      final switchOver = service.reconfigure(
        AgentConfig(
          providerKind: 'anthropic',
          modelId: 'claude-test',
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'test-key',
        ),
      );
      service.dispose();
      await switchOver;
      await run;
    },
  );
}
