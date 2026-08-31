// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

void main() {
  group('memory tool governance', () {
    test('memory_add description IS the memory repo policy', () {
      final env = MemoryExecutionEnv();
      final tools = memoryTools(MemoryController(env: env));
      final add = tools.singleWhere((t) => t.name == 'memory_add');
      // The governance text comes from flutter_agent_memory
      // (docs/memory/memory_add_policy.md) — one source of truth.
      expect(add.description, MemoryPolicy.memoryAddPolicy);
      expect(add.description, contains('supersede'));
      expect(add.description, contains('durable'));
      expect(add.description, contains('public'));
    });
  });

  group('memoryTools', () {
    test('memory_add fires onChanged after a successful save', () async {
      final controller = MemoryController(env: MemoryExecutionEnv());
      var changed = 0;
      final tools = memoryTools(controller, onChanged: () => changed++);
      final add = tools.singleWhere((t) => t.name == 'memory_add');

      final result = await add.execute({'text': 'a durable fact'}, null, null);
      expect(_text(result), contains('saved memory'));
      expect(changed, 1);

      // A rejected (empty) add must NOT fire the callback.
      final rejected = await add.execute({'text': '   '}, null, null);
      expect(_text(rejected), contains('error'));
      expect(changed, 1);
    });

    test('memoryTools without onChanged still works', () async {
      final controller = MemoryController(env: MemoryExecutionEnv());
      final tools = memoryTools(controller);
      final add = tools.singleWhere((t) => t.name == 'memory_add');
      final result = await add.execute({'text': 'fact'}, null, null);
      expect(_text(result), contains('saved memory'));
    });
  });
}

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}
