// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/chat_text_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads the persisted size; missing file keeps the default', () async {
    final env = MemoryExecutionEnv();
    final store = ChatTextStore(env);
    await store.load();
    expect(store.fontSize, ChatTextStore.defaultFontSize);

    await env.writeFile(
      '/chat_text.json',
      '{"version":1,"fontSize":18}',
    );
    final loaded = ChatTextStore(env);
    await loaded.load();
    expect(loaded.fontSize, 18);
  });

  test('corrupt and foreign-version files load as the default', () async {
    final env = MemoryExecutionEnv();
    await env.writeFile('/chat_text.json', 'not json');
    final corrupt = ChatTextStore(env);
    await corrupt.load();
    expect(corrupt.fontSize, ChatTextStore.defaultFontSize);

    await env.writeFile('/chat_text.json', '{"version":99,"fontSize":18}');
    final foreign = ChatTextStore(env);
    await foreign.load();
    expect(foreign.fontSize, ChatTextStore.defaultFontSize);
  });

  test('setFontSize clamps, notifies and persists', () async {
    final env = MemoryExecutionEnv();
    final store = ChatTextStore(env);
    var notifications = 0;
    store.addListener(() => notifications++);

    store.setFontSize(99);
    expect(store.fontSize, ChatTextStore.maxFontSize);
    expect(notifications, 1);

    // Persisted — a fresh store over the same env reads it back.
    final reloaded = ChatTextStore(env);
    await reloaded.load();
    expect(reloaded.fontSize, ChatTextStore.maxFontSize);

    // Below the floor clamps too; an unchanged value does not notify.
    store.setFontSize(1);
    expect(store.fontSize, ChatTextStore.minFontSize);
    expect(notifications, 2);
    store.setFontSize(ChatTextStore.minFontSize);
    expect(notifications, 2);
  });
}
