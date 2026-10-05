// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-1276 regression: the app must wire a user root into its
/// [MemoryController] so user-scope memory (add → list → search) works on
/// every platform backend. Before the fix, `AgentService._withEnv` built
/// the controller without `userRoot`: `memory_add` with `scope: user`
/// silently dropped the note (the tool still reported "saved"), and
/// `memory_list`/`memory_search` could never see it — the iOS 1.0.512
/// session that fell back to `memory_delete` by exact text.
library;

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart'
    show PromptLoader;
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

Future<AgentService> _createService(
  MemoryExecutionEnv env, {
  String? configHomeDir,
}) async {
  final service = await AgentService.create(
    config: AgentConfig(
      providerKind: 'openai-completions',
      modelId: 'test-model',
      baseUrl: 'https://example.test',
      apiKey: '[REDACTED:Sensitive Value]',
    ),
    env: env,
    streamFunction: _singleTextResponse('ok'),
    configHomeDir: configHomeDir,
  );
  addTearDown(service.dispose);
  return service;
}

AgentTool _tool(AgentService service, String name) =>
    service.toolsForTest.firstWhere((t) => t.name == name)
        as AgentTool;

Future<String> _run(AgentService service, String name,
        Map<String, dynamic> args) async =>
    (_tool(service, name).execute(args, null, null))
        .then((r) => r.content.whereType<TextContent>().map((b) => b.text).join());

void main() {
  group('gh-1276: app memory user scope', () {
    setUp(() {
      // flutter_test cannot resolve package: URIs (the vendor prompt
      // loader reads its XML templates via Isolate.resolvePackageUri).
      // PromptLoader.setLoader is the package's documented host hook —
      // a minimal template keeps the enrichment/search LLM stages alive.
      PromptLoader.setLoader(
          (name) async => '<prompt>stub for $name: ${'query'}</prompt>');
    });
    tearDown(() => PromptLoader.setLoader(null));
    test(
      'AC1: memory_add (user) → memory_list shows it → memory_search '
      'ranks it for its own keywords',
      () async {
        final env = MemoryExecutionEnv(cwd: '/');
        final service = await _createService(env);

        const note =
            'User prefers running flutter tests with --concurrency 1 on CI';
        final added = await _run(service, 'memory_add',
            {'text': note, 'scope': 'user'});
        expect(added, contains('saved memory (user)'));

        final listed = await _run(service, 'memory_list', const {});
        expect(listed, contains(note),
            reason: 'the user note must appear in memory_list immediately');

        final found = await _run(
            service, 'memory_search', {'query': 'flutter test concurrency'});
        expect(found, contains(note),
            reason: 'search must rank the user note for its own keywords');
      },
    );

    test(
      'desktop parity: configHomeDir anchors the user store at '
      '<home>/.fah/memory',
      () async {
        final env = MemoryExecutionEnv(cwd: '/');
        final service = await _createService(env, configHomeDir: '/home/u');

        await _run(service, 'memory_add',
            {'text': 'user-scope parity note', 'scope': 'user'});

        // Same store location the CLI uses for user scope: the note file
        // lands under <home>/.fah/memory/note/ (hash-suffixed id).
        final dir =
            (await env.listDir('/home/u/.fah/memory/note')).valueOrNull;
        expect(dir, isNotNull);
        expect(dir!.where((f) => f.name.startsWith('n_0001_')), hasLength(1));
      },
    );

    test(
      'user root resolution: config override wins, then desktop home, '
      'then a sandbox-local fallback',
      () async {
        expect(
          appMemoryUserRoot(
              configHomeDir: '/cfg', desktopHome: '/desk', envCwd: '/cwd'),
          '/cfg',
        );
        expect(
          appMemoryUserRoot(
              configHomeDir: null, desktopHome: '/desk', envCwd: '/cwd'),
          '/desk',
        );
        expect(
          appMemoryUserRoot(
              configHomeDir: null, desktopHome: null, envCwd: '/cwd'),
          '/cwd/home',
        );
      },
    );
  });
}