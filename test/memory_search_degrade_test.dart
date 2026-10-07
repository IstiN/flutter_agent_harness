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
  Future<String> chat(String prompt, {String? model, void Function()? onCancel}) =>
      throw Exception(
        'Invalid core: OLDER session state read on a NEW session',
      );

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) =>
      throw Exception(
        'Invalid core: OLDER session state read on a NEW session',
      );
}

void main() {
  test('memory_search survives a broken LLM core via keyword fallback',
      () async {
    final controller = MemoryController(
      env: MemoryExecutionEnv(),
      llmProvider: _BrokenCoreProvider(),
    );
    await controller.add(text: 'durable keyword fact alpha', tags: ['t']);

    final results = await controller.search('alpha');

    expect(results, isNotEmpty,
        reason: 'the keyword fallback must still find stored entries');
  });

  test('memory_list survives a broken project store', () async {
    final controller = MemoryController(
      env: MemoryExecutionEnv(),
      llmProvider: _BrokenCoreProvider(),
    );
    await controller.add(text: 'listable fact');

    final results = await controller.list();

    expect(results.map((e) => e.text), contains('listable fact'));
  });
}
