// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io' as io;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_service_windowed_test.dart' show GatedFileSystem;

Agent _agent() {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'test',
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(const []),
  );
}

final _config = AgentConfig(
  providerKind: 'test',
  modelId: 'test-model',
  baseUrl: 'https://example.com',
  apiKey: '',
);

AgentService _service(String cwd, FileSystem fs) {
  return AgentService(
    agent: _agent(),
    env: LocalExecutionEnv(cwd: cwd),
    sessionsRoot: cwd,
    repo: JsonlSessionRepo(fs: fs, sessionsRoot: cwd),
    watchExternalSessions: false,
    includeSharedSessionRoots: false,
  );
}

Future<void> _deleteTmpDir(io.Directory tmp) async {
  Object? lastError;
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await tmp.delete(recursive: true);
      return;
    } on io.FileSystemException catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  // ignore: only_throw_errors
  throw lastError!;
}

SessionMetadata _metadata(String root, String id) => SessionMetadata(
  id: id,
  createdAt: DateTime.utc(2026),
  cwd: root,
  path: '$root/$id.jsonl',
);

void main() {
  test(
    'a stale open completion cannot override the latest session selection',
    () async {
      final tmp = await io.Directory.systemTemp.createTemp('fa_switch_race');
      addTearDown(() => _deleteTmpDir(tmp));
      for (final id in ['a', 'b']) {
        await io.File('${tmp.path}/$id.jsonl').writeAsString(
          '{"type":"session","version":3,"id":"$id",'
          '"timestamp":"2026-01-01T00:00:00.000Z","cwd":"${tmp.path}"}\n',
        );
      }
      final manager = FlutterSessionManager(
        env: LocalExecutionEnv(cwd: tmp.path),
        sessionsRoot: tmp.path,
        includeSharedSessionRoots: false,
      );
      final current = _service(tmp.path, LocalFileSystem(cwd: tmp.path))
        ..messages.add(FahChatMessage(role: 'user', content: 'current'));
      final gatedA = GatedFileSystem(
        LocalFileSystem(cwd: tmp.path),
        gatePath: 'a.jsonl',
      )..armGate();
      final gatedB = GatedFileSystem(
        LocalFileSystem(cwd: tmp.path),
        gatePath: 'b.jsonl',
      )..armGate();
      final a = _service(tmp.path, gatedA);
      final b = _service(tmp.path, gatedB);
      addTearDown(() {
        current.dispose();
        a.dispose();
        b.dispose();
        manager.dispose();
      });
      manager.addSession('current', current);

      final openA = manager.openSession(
        _metadata(tmp.path, 'a'),
        config: _config,
        serviceFactory: () => a,
      );
      final openB = manager.openSession(
        _metadata(tmp.path, 'b'),
        config: _config,
        serviceFactory: () => b,
      );

      // The user's latest intent is to return to the already-loaded session.
      // It is a no-op for the old switchTo because the slow opens have not
      // activated anything yet; their completions later win in finish order.
      manager.switchTo('current');
      gatedB.releaseGate();
      await openB;
      gatedA.releaseGate();
      await openA;

      expect(manager.activeId, 'current');
      expect(manager.active?.service.messages.single.content, 'current');
    },
  );
}
