// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1393: `memory_search` crashed on iOS with
// "Invalid core: OLDER session state read on a NEW session" — a non-
// StateError escaping KBSearchEngine.searchByText. Memory tools must
// degrade gracefully: LLM-backed search failures fall back to keyword
// search; scope-level failures skip that scope. A memory tool NEVER
// throws.

@TestOn('vm')
library;

import 'dart:async';

import 'package:fa_llm/fa_llm.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

/// An LLM provider whose calls blow up with the crash-of-record: the
/// stale-core failure seen on iOS when a new session reads older session
/// state. Any non-StateError exception reproduces the defect.
class _BrokenCoreProvider extends LlmProvider {
  @override
  final String defaultModel = 'broken-model';

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) => throw Exception(
    'Invalid core: OLDER session state read on a NEW session',
  );

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) => throw Exception(
    'Invalid core: OLDER session state read on a NEW session',
  );
}

void main() {
  test(
    'memory_search survives a broken LLM core via keyword fallback',
    () async {
      final controller = MemoryController(
        env: MemoryExecutionEnv(),
        llmProvider: _BrokenCoreProvider(),
      );
      await controller.add(text: 'durable keyword fact alpha', tags: ['t']);

      final results = await controller.search('alpha');

      expect(
        results,
        isNotEmpty,
        reason: 'the keyword fallback must still find stored entries',
      );
    },
  );

  test('memory_list survives a broken project store', () async {
    final controller = MemoryController(
      env: MemoryExecutionEnv(),
      llmProvider: _BrokenCoreProvider(),
    );
    await controller.add(text: 'listable fact');

    final results = await controller.list();

    expect(results.map((e) => e.text), contains('listable fact'));
  });

  test(
    'a config swap resets the plain-store fallback caches — no lost memory',
    () async {
      // gh-1393 rework: the plain stores cached by `_addNoteAnyhow`'s
      // fallback must die with the config swap, exactly like the
      // LLM-backed store/storage pairs — otherwise the next fallback
      // write reuses a `KBMemoryStore` built over the OLD storage root
      // and the memory silently lands in the abandoned location.
      final env = MemoryExecutionEnv();
      var projectPath = '/.fah/memory-a';
      final controller = MemoryController(
        env: env,
        projectRoot: '/',
        llmProvider: _BrokenCoreProvider(),
        configSource: () async => MemoryConfig(projectPath: projectPath),
      );

      // The failing LLM enrichment routes this add through the plain
      // store, caching it over root A.
      await controller.add(text: 'cached fallback note');

      // Swap the config: the controller now points at root B.
      projectPath = '/.fah/memory-b';
      await controller.add(text: 'note after swap');

      final noteIds =
          (await env.listDir('/.fah/memory-b/note')).valueOrNull ?? const [];
      final texts = <String>{
        for (final id in noteIds)
          (await env.readTextFile('/.fah/memory-b/note/${id.name}'))
              .valueOrNull!,
      };
      expect(
        texts.join('\n'),
        contains('note after swap'),
        reason:
            'the post-swap fallback write must land at the NEW root — '
            'a stale plain-store cache writes into the abandoned one',
      );
    },
  );

  test(
    'a config swap racing the fallback write never crashes the never-throw path',
    () async {
      // gh-1393 rework: `_addNoteAnyhow` force-unwrapped the cached
      // storage fields; a swap landing between the store fetch and the
      // fallback (`_applyConfig` nulls them) turned "memory never
      // throws" into a null-check crash. The rework rebuilds the storage
      // from the resolved path instead — the note still saves.
      final env = MemoryExecutionEnv();
      var projectPath = '/.fah/memory-race-a';
      var releaseFirstAdd = Completer<void>();
      final controller = MemoryController(
        env: env,
        projectRoot: '/',
        llmProvider: _HangingThenBrokenProvider(releaseFirstAdd),
        configSource: () async => MemoryConfig(projectPath: projectPath),
      );

      final first = controller.add(text: 'mid-flight note');
      // Let the first add reach its (hanging) LLM enrichment, then swap
      // the config from within that await window.
      await _pump();
      projectPath = '/.fah/memory-race-b';
      final second = controller.add(text: 'swap note');
      await _pump();
      releaseFirstAdd.complete();
      await Future.wait([first, second]);

      final bNoteIds =
          (await env.listDir('/.fah/memory-race-b/note')).valueOrNull ?? const [];
      final texts = <String>{
        for (final id in bNoteIds)
          (await env.readTextFile('/.fah/memory-race-b/note/${id.name}'))
              .valueOrNull!,
      };
      expect(texts.join('\n'), contains('mid-flight note'));
      expect(texts.join('\n'), contains('swap note'));
    },
  );

  test('user-scope add survives a broken LLM core via the plain fallback',
      () async {
    // The user-scope half of the `_addNoteAnyhow` fallback: the storage is
    // rebuilt from the resolved user path when needed (no force-unwrap),
    // and the note still saves with keyword-only metadata.
    final env = MemoryExecutionEnv();
    final controller = MemoryController(
      env: env,
      userRoot: '/user-home',
      llmProvider: _BrokenCoreProvider(),
    );
    await controller.add(text: 'user scope fact', scope: 'user');

    final noteIds =
        (await env.listDir('/user-home/.fah/memory/note')).valueOrNull ?? const [];
    final texts = <String>{
      for (final id in noteIds)
        (await env.readTextFile('/user-home/.fah/memory/note/${id.name}'))
            .valueOrNull!,
    };
    expect(texts.join('\n'), contains('user scope fact'));
  });

  test('search/add degrades are observable through onDegrade', () async {
    // gh-1393 rework: the `on Object {}` swallows are the ticket's intent,
    // but silent — field regressions need a breadcrumb. The injectable
    // hook keeps the controller logger-free and test-friendly.
    final degradeLog = <String>[];
    final controller = MemoryController(
      env: MemoryExecutionEnv(),
      llmProvider: _BrokenCoreProvider(),
      onDegrade: degradeLog.add,
    );
    await controller.add(text: 'observable fact');
    expect(degradeLog, isNotEmpty, reason: 'the add-fallback degrade fires');
    final before = degradeLog.length;

    await controller.search('observable');
    expect(
      degradeLog.length,
      greaterThan(before),
      reason: 'the LLM-search degrade fires per scope',
    );
  });
}

/// Yields to the event loop so a pending [Completer]-blocked add() has
/// actually suspended before the test pulls the next lever.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

/// An LLM provider that hangs the FIRST call until released, then fails
/// the same way as [_BrokenCoreProvider] — enough to park the first add()
/// inside its enrichment await while the test swaps the config.
class _HangingThenBrokenProvider extends LlmProvider {
  _HangingThenBrokenProvider(this._release);

  final Completer<void> _release;

  @override
  final String defaultModel = 'broken-model';

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) async {
    await _release.future;
    throw Exception(
      'Invalid core: OLDER session state read on a NEW session',
    );
  }

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async {
    await _release.future;
    throw Exception(
      'Invalid core: OLDER session state read on a NEW session',
    );
  }
}
