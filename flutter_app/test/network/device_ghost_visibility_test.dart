// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_connector_service_test.dart' as fixture;
import 'fakes.dart';

AgentService _service(ExecutionEnv env, {bool withMessage = false}) {
  final service = AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
  if (withMessage) {
    service.messages.add(FahChatMessage(role: 'user', content: 'real chat'));
  }
  return service;
}

Future<void> _until(bool Function() probe) async {
  for (var i = 0; i < 300; i++) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('device roster condition did not settle');
}

void main() {
  test(
    'Local-hidden live ghosts never publish and deleted ids retract',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        includeSharedSessionRoots: false,
      );
      manager
        ..addSession('ghost-empty', _service(env))
        ..addSession('real-chat', _service(env, withMessage: true));
      final chatList = ChatListController(
        localAdapter: LocalChatListAdapter(
          manager: manager,
          titleBuilder: (id, _, _) => id,
        ),
      );
      addTearDown(chatList.dispose);
      await chatList.load();
      expect(chatList.localEntries.map((row) => row.id.value), ['real-chat']);

      final source = createDeviceChatSessionSource(manager, chatList: chatList);
      expect((await source.load()).map((row) => row.id), ['real-chat']);
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-ghost-filter"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final (service, _, _, _, _) = await fixture.buildService(
        httpClient: http,
        tokenStore: fixture.enrolledTokens(),
        chatSessionSource: source,
        rosterDebounce: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      await _until(() => fixture.rosterPatches(http).isNotEmpty);

      final published = fixture
          .rosterPatches(http)
          .expand((patch) => (patch['sessions']! as List).cast<Map>())
          .toList();
      expect(published.map((row) => row['id']), ['real-chat']);
      expect(published.map((row) => row['id']), isNot(contains('ghost-empty')));

      // The canonical Local projection no longer contains the row (the same
      // notification path used after delete); absence alone is not retraction.
      await chatList.replaceLocalEntries(const []);
      await _until(() => fixture.rosterPatches(http).length >= 2);
      final retraction = fixture.rosterPatches(http).last;
      final retracted = (retraction['sessions']! as List).single as Map;
      expect(retracted['id'], 'real-chat');
      expect(retracted['state'], 'offline');
      expect(retracted['networks'], isEmpty);
    },
  );
}
