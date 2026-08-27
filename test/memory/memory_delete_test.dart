@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('memory_delete removes an entry by id from the project scope', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final controller = MemoryController(env: env);
    final added = await controller.add(text: 'temp fact');
    expect(await controller.delete(added.id), 'project');
    final ids = (await controller.list()).map((e) => e.id);
    expect(ids, isNot(contains(added.id)));
  });

  test('memory_delete returns null for an unknown id', () async {
    final controller = MemoryController(env: MemoryExecutionEnv(cwd: '/w'));
    expect(await controller.delete('nope'), isNull);
  });

  test('the memory_delete tool reports deletion and unknown ids', () async {
    final controller = MemoryController(env: MemoryExecutionEnv(cwd: '/work'));
    final tools = memoryTools(controller);
    final tool = tools.singleWhere((t) => t.name == 'memory_delete');
    final added = await controller.add(text: 'doomed fact');

    String content(dynamic result) =>
        result.content.whereType<TextContent>().map((b) => b.text).join();

    final ok = await tool.execute({'id': added.id}, null, null);
    expect(content(ok), contains('deleted memory (project)'));

    final miss = await tool.execute({'id': 'gone'}, null, null);
    expect(content(miss), contains('error: no memory entry'));

    final noId = await tool.execute({}, null, null);
    expect(content(noId), contains('error: id is required'));
  });
}
