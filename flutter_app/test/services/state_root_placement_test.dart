// gh-2185 AC1: every runtime-state writer persists under the `.fah/state`
// root — a write must never create a state file at the repo root again —
// and the one-release legacy fallback migrates existing checkouts.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:fa/network/network_mode.dart';
import 'package:fa/services/app_state_paths.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/session_ui_prefs_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MemoryExecutionEnv envWithLegacy(String fileName, String content) {
    final env = MemoryExecutionEnv(cwd: '/repo');
    env.writeFile('/repo/$fileName', content);
    return env;
  }

  group('writes land in the state root (gh-2185 AC1)', () {
    test('ChatPinStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await ChatPinStore.load(env, accountId: 'alice');
      await store.setPinned(ChatEntryId.local('s1'), true);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, ChatPinStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, ChatPinStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('ChatReadCursorStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await ChatReadCursorStore.load(env, accountId: 'alice');
      await store.markRead(ChatEntryId.local('s1'), 3);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, ChatReadCursorStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, ChatReadCursorStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('LauncherLayoutStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await LauncherLayoutStore.load(env);
      store.setGridColumns(4);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, LauncherLayoutStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, LauncherLayoutStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('NetworkModeStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await NetworkModeStore.load(env);
      await store.setState(mode: AppMode.network);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, NetworkModeStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, NetworkModeStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('SessionUiPrefsStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await SessionUiPrefsStore.load(env);
      await store.setExpanded('parent-1', true);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, SessionUiPrefsStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, SessionUiPrefsStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('OnboardingStore', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final store = await OnboardingStore.load(env);
      await store.markSeen();

      expect(
        (await env.readTextFile(
          appStateFilePath(env, OnboardingStore.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, OnboardingStore.fileName),
        )).valueOrNull,
        isNull,
      );
    });

    test('ThemeController', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      final controller = await ThemeController.load(env);
      await controller.setMode(FahThemeMode.dark);

      expect(
        (await env.readTextFile(
          appStateFilePath(env, ThemeController.fileName),
        )).valueOrNull,
        isNotNull,
      );
      expect(
        (await env.readTextFile(
          legacyAppStateFilePath(env, ThemeController.fileName),
        )).valueOrNull,
        isNull,
      );
    });
  });

  group('legacy root files migrate through the read fallback', () {
    test('ChatPinStore reads pins written by a pre-gh-2185 checkout', () async {
      final env = envWithLegacy(
        ChatPinStore.fileName,
        jsonEncode({
          'version': 1,
          'accounts': {
            'alice': ['local:s1'],
          },
        }),
      );
      final store = await ChatPinStore.load(env, accountId: 'alice');
      expect(store.isPinned(ChatEntryId.local('s1')), isTrue);
    });

    test('ChatReadCursorStore reads cursors written by a pre-gh-2185 '
        'checkout', () async {
      final env = envWithLegacy(
        ChatReadCursorStore.fileName,
        jsonEncode({
          'version': 1,
          'accounts': {
            'alice': {'local:s1': 7},
          },
        }),
      );
      final store = await ChatReadCursorStore.load(env, accountId: 'alice');
      expect(store.cursorFor(ChatEntryId.local('s1')), 7);
    });

    test('LauncherLayoutStore reads a legacy layout', () async {
      final env = envWithLegacy(
        LauncherLayoutStore.fileName,
        jsonEncode({
          'version': 2,
          'order': <String>['a', 'b'],
          'folders': <Map<String, dynamic>>[],
          'grid': {'columns': 5},
          'tileSizes': <String, String>{},
        }),
      );
      final store = await LauncherLayoutStore.load(env);
      expect(store.gridColumns, 5);
    });

    test('NetworkModeStore reads a legacy mode', () async {
      final env = envWithLegacy(
        NetworkModeStore.fileName,
        jsonEncode({
          'version': 1,
          'mode': 'network',
          'lastNetworkId': 'n1',
          'lastChannelId': 'c1',
        }),
      );
      final store = await NetworkModeStore.load(env);
      expect(store.mode, AppMode.network);
      expect(store.lastNetworkId, 'n1');
    });

    test('SessionUiPrefsStore reads legacy prefs', () async {
      final env = envWithLegacy(
        SessionUiPrefsStore.fileName,
        jsonEncode({
          'version': 1,
          'expandedParents': ['p1'],
          'collapsedParents': <String>[],
          'sidebarWidth': 260.0,
        }),
      );
      final store = await SessionUiPrefsStore.load(env);
      expect(store.expandedParents, {'p1'});
    });

    test('OnboardingStore reads a legacy seen flag', () async {
      final env = envWithLegacy(
        OnboardingStore.fileName,
        jsonEncode({'version': 1, 'seen': true}),
      );
      final store = await OnboardingStore.load(env);
      expect(store.seen, isTrue);
    });

    test('ThemeController reads a legacy theme mode', () async {
      final env = envWithLegacy(
        ThemeController.fileName,
        jsonEncode({'version': 1, 'mode': 'dark'}),
      );
      final controller = await ThemeController.load(env);
      expect(controller.mode, FahThemeMode.dark);
    });
  });
}
