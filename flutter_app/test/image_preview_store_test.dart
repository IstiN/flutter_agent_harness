// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/image_preview_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing file keeps the default (downscale on, high quality off)',
      () async {
    final env = MemoryExecutionEnv();
    final store = ImagePreviewStore(env);
    await store.load();
    expect(store.highQuality, isFalse);
  });

  test('loads the persisted choice', () async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      '/image_preview.json',
      '{"version":1,"highQuality":true}',
    );
    final store = ImagePreviewStore(env);
    await store.load();
    expect(store.highQuality, isTrue);
  });

  test('corrupt and foreign-version files load as the default', () async {
    final env = MemoryExecutionEnv();
    await env.writeFile('/image_preview.json', 'not json');
    final corrupt = ImagePreviewStore(env);
    await corrupt.load();
    expect(corrupt.highQuality, isFalse);

    await env.writeFile(
      '/image_preview.json',
      '{"version":99,"highQuality":true}',
    );
    final foreign = ImagePreviewStore(env);
    await foreign.load();
    expect(foreign.highQuality, isFalse);
  });

  test('setHighQuality notifies and persists; a no-op does not notify',
      () async {
    final env = MemoryExecutionEnv();
    final store = ImagePreviewStore(env);
    var notifications = 0;
    store.addListener(() => notifications++);

    store.setHighQuality(true);
    expect(store.highQuality, isTrue);
    expect(notifications, 1);

    // Persisted — a fresh store over the same env reads it back.
    final reloaded = ImagePreviewStore(env);
    await reloaded.load();
    expect(reloaded.highQuality, isTrue);

    // An unchanged value does not notify.
    store.setHighQuality(true);
    expect(notifications, 1);

    store.setHighQuality(false);
    expect(store.highQuality, isFalse);
    expect(notifications, 2);
  });
}
