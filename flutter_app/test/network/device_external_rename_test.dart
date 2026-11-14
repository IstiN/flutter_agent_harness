// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' show LocalExecutionEnv;
import 'package:flutter_test/flutter_test.dart';

import 'device_connector_service_test.dart' as fixture;
import 'fakes.dart';

Future<void> _until(bool Function() probe) async {
  for (var i = 0; i < 500; i++) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('external rename did not propagate within five seconds');
}

void main() {
  test(
    'external store rename refreshes Local and publishes roster metadata',
    () async {
      final temp = await Directory.systemTemp.createTemp('fa-rename-watch-');
      addTearDown(() => temp.delete(recursive: true));
      final env = LocalExecutionEnv(cwd: temp.path);
      final repo = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '${temp.path}/sessions',
      );
      const id = 'external-rename-session';
      final persisted = await repo.create(
        const JsonlSessionCreateOptions(id: id, cwd: '/work/rename'),
      );
      await persisted.appendMessage(UserMessage.text('real transcript'));
      final namesFile = File('${temp.path}/${SessionNamesStore.fileName}');
      await namesFile.writeAsString(
        jsonEncode({
          'version': 1,
          'names': {id: 'Before CLI'},
        }),
      );
      final names = await SessionNamesStore.load(env);
      addTearDown(names.dispose);
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '${temp.path}/sessions',
        repo: repo,
        includeSharedSessionRoots: false,
      );
      final chatList = ChatListController(
        localAdapter: LocalChatListAdapter(
          manager: manager,
          namesStore: names,
          titleBuilder: (id, _, _) => id,
        ),
      );
      addTearDown(chatList.dispose);
      await chatList.load();
      expect(chatList.localEntryFor(id)?.title, 'Before CLI');

      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-external-rename"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final source = createDeviceChatSessionSource(manager, chatList: chatList);
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

      // Simulate the CLI/other process: write the shared store file directly,
      // without calling rename/syncFromSnapshot on the app's in-memory store.
      await namesFile.writeAsString(
        jsonEncode({
          'version': 1,
          'names': {id: 'Hero'},
        }),
        flush: true,
      );

      await _until(
        () =>
            chatList.localEntryFor(id)?.title == 'Hero' &&
            fixture.rosterPatches(http).length >= 2,
      );
      expect(names.titleFor(id), 'Hero');
      expect(chatList.localEntryFor(id)?.title, 'Hero');
      final sessions = fixture.rosterPatches(http).last['sessions']! as List;
      final row = sessions.cast<Map>().singleWhere((row) => row['id'] == id);
      expect(row['title'], 'Hero');
    },
  );
}
