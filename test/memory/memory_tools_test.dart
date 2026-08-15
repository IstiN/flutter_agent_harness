// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
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
