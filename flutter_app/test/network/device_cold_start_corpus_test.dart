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

void main() {
  test(
    'PR #2190 review: an UNLOADED controller never filters the projection '
    '(no cold-start mass-retraction); after the first load it filters',
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
      // Cold start: the controller has NOT loaded yet — the visible corpus
      // is unknown, so the projection stays unfiltered and cannot retract
      // every previously published session on sibling devices.
      expect(chatList.localLoadedOnce, isFalse);
      final source = createDeviceChatSessionSource(manager, chatList: chatList);
      final cold = await source.load();
      expect(
        cold.map((session) => session.id),
        containsAll(<String>['ghost-empty', 'real-chat']),
      );
      // After the first successful listing the canonical filter applies:
      // the Local-hidden ghost disappears from the projection.
      await chatList.load();
      expect(chatList.localLoadedOnce, isTrue);
      final warm = await source.load();
      expect(warm.map((session) => session.id), ['real-chat']);
    },
  );
}
